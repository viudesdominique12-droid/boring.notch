//
//  MaVersionMonitors.swift
//  boringNotch — ma-version
//
//  Background watchers that feed the closed-notch glances and the
//  clipboard page: upcoming calendar events, rain coming, headphones
//  connected, and copied text.
//

import AppKit
import Combine
import CoreAudio
import Defaults
import EventKit
import Darwin
import Foundation
import IOBluetooth
import IOKit

enum MaVersionMonitors {
    @MainActor private static var started = false

    /// Idempotent: every notch window's ContentView calls it.
    @MainActor static func startAll() {
        guard !started else { return }
        started = true
        _ = UpcomingEventMonitor.shared
        RainAlertWatcher.shared.start()
        HeadphonesWatcher.shared.start()
        ClipboardHistory.shared.start()
        NewFilesWatcher.shared.start()
    }
}

// MARK: - Short-lived glances

@MainActor
final class GlanceCenter: ObservableObject {
    static let shared = GlanceCenter()

    @Published private(set) var current: GlanceKind?
    private var dismissTask: Task<Void, Never>?

    func show(_ kind: GlanceKind, for seconds: Double) {
        current = kind
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

// MARK: - Upcoming event (10 min before → 2 min after start)

@MainActor
final class UpcomingEventMonitor: ObservableObject {
    static let shared = UpcomingEventMonitor()

    struct Upcoming: Equatable {
        let id: String
        let title: String
        let color: NSColor
        let start: Date
    }

    @Published private(set) var upcoming: Upcoming?
    private let store = EKEventStore()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.check() }
            .store(in: &cancellables)
        check()
    }

    func check() {
        guard Defaults[.upcomingEventAlert],
              EKEventStore.authorizationStatus(for: .event) == .fullAccess
        else {
            upcoming = nil
            return
        }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-2 * 60),
            end: now.addingTimeInterval(10 * 60),
            calendars: nil
        )
        let next = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate >= now.addingTimeInterval(-2 * 60) && $0.startDate <= now.addingTimeInterval(10 * 60) }
            .sorted { $0.startDate < $1.startDate }
            .first
        upcoming = next.map {
            Upcoming(
                id: $0.eventIdentifier ?? UUID().uuidString,
                title: $0.title ?? "Événement",
                color: $0.calendar?.color ?? .systemBlue,
                start: $0.startDate
            )
        }
    }
}

// MARK: - Rain alert

@MainActor
final class RainAlertWatcher {
    static let shared = RainAlertWatcher()
    private var cancellable: AnyCancellable?
    private var lastAlertedStart: Date?

    func start() {
        cancellable = WeatherManager.shared.$rain
            .receive(on: RunLoop.main)
            .sink { [weak self] rain in self?.evaluate(rain) }
    }

    private func evaluate(_ rain: RainOutlook) {
        guard Defaults[.rainAlert], case .startsAt(let start) = rain else { return }
        let minutes = start.timeIntervalSinceNow / 60
        guard minutes <= 20 else { return }
        // One alert per rain episode.
        if let last = lastAlertedStart, abs(last.timeIntervalSince(start)) < 45 * 60 { return }
        lastAlertedStart = start
        GlanceCenter.shared.show(.rain(start: start), for: 7)
    }
}

// MARK: - Headphones connected (default output switches to Bluetooth)

@MainActor
final class HeadphonesWatcher {
    static let shared = HeadphonesWatcher()
    private var lastDeviceID: AudioDeviceID = 0
    private var installed = false

    func start() {
        guard !installed else { return }
        installed = true
        lastDeviceID = Self.defaultOutput()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in
            Task { @MainActor in HeadphonesWatcher.shared.outputChanged() }
        }
    }

    private func outputChanged() {
        let device = Self.defaultOutput()
        guard device != 0, device != lastDeviceID else { return }
        lastDeviceID = device
        guard Defaults[.deviceAlert], Self.isBluetooth(device) else { return }
        let name = Self.name(of: device) ?? "Écouteurs"
        // Battery shows up a moment after the audio route switches.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            GlanceCenter.shared.show(
                .device(name: name, symbol: Self.symbol(for: name), battery: Self.battery(forName: name)),
                for: 5
            )
        }
    }

    private static func defaultOutput() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        return "headphones"
    }

    /// AirPods-style battery: IOBluetooth exposes it through undocumented
    /// properties, so every read is guarded and nil just means "unknown".
    private static func battery(forName name: String) -> Int? {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
              let device = devices.first(where: { $0.isConnected() && ($0.name == name || name.contains($0.name ?? "\u{0}")) })
        else { return nil }
        func read(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)),
                  let value = device.value(forKey: key) as? NSNumber,
                  value.intValue > 0
            else { return nil }
            return value.intValue
        }
        let buds = [read("batteryPercentLeft"), read("batteryPercentRight")].compactMap { $0 }
        if let lowest = buds.min() { return lowest }
        return read("batteryPercentSingle") ?? read("batteryPercentCombined")
    }
}

// MARK: - Clipboard history (in memory only, never written to disk)

@MainActor
final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()

    @Published private(set) var entries: [ClipboardEntry] = []
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let limit = 10

    /// Password managers mark secrets with these types: never keep them.
    private static let skippedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword"
    ]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard Defaults[.clipboardHistory] else {
            if !entries.isEmpty { entries = [] }
            return
        }
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.skippedTypes),
              let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }
        entries.removeAll { $0.text == text }
        entries.insert(ClipboardEntry(id: UUID(), text: String(text.prefix(2000)), date: Date()), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    func copy(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        entries.removeAll { $0.id == entry.id }
        entries.insert(ClipboardEntry(id: entry.id, text: entry.text, date: Date()), at: 0)
    }

    func clear() {
        entries = []
    }
}

// MARK: - System page stats (sampled only while the page is on screen)

@MainActor
final class SystemStatsMonitor: ObservableObject {
    static let shared = SystemStatsMonitor()

    @Published private(set) var stats = SystemStats()
    private var timer: Timer?
    private var lastCPU: (busy: UInt64, total: UInt64)?
    private var lastNet: (down: UInt64, up: UInt64, at: Date)?

    private init() {}

    func start() {
        guard timer == nil else { return }
        lastCPU = Self.cpuTicks()
        if let net = Self.networkBytes() { lastNet = (net.down, net.up, Date()) }
        readBattery()
        stats.memoryUsed = Self.memoryUsed()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in SystemStatsMonitor.shared.sample() }
        }
        // CPU and network need two samples; get the first numbers up quickly.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            SystemStatsMonitor.shared.sample()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard timer != nil else { return }
        var next = stats
        if let now = Self.cpuTicks(), let last = lastCPU, now.total > last.total {
            next.cpu = min(max(Double(now.busy - last.busy) / Double(now.total - last.total), 0), 1)
            lastCPU = now
        } else {
            lastCPU = Self.cpuTicks()
        }
        next.memoryUsed = Self.memoryUsed()
        if let net = Self.networkBytes() {
            let date = Date()
            // The counters are 32-bit and wrap; skip a sample when they do.
            if let last = lastNet, net.down >= last.down, net.up >= last.up {
                let seconds = max(date.timeIntervalSince(last.at), 0.1)
                next.down = Double(net.down - last.down) / seconds
                next.up = Double(net.up - last.up) / seconds
            }
            lastNet = (net.down, net.up, date)
        }
        if next != stats { stats = next }
    }

    private func readBattery() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return }
        // Apple silicon keeps these inside "BatteryData"; Intel at the top.
        let nested = dict["BatteryData"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Double {
            ((dict[key] ?? nested[key]) as? NSNumber)?.doubleValue ?? 0
        }
        let design = number("DesignCapacity")
        let nominal = number("NominalChargeCapacity")
        let full = nominal > 0 ? nominal : number("AppleRawMaxCapacity")
        if design > 0, full > 0 {
            stats.batteryHealth = min(Int((full / design * 100).rounded()), 100)
        }
        stats.batteryCycles = (dict["CycleCount"] as? NSNumber)?.intValue
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// Same idea as Activity Monitor's "memory used": app + wired + compressed.
    private static func memoryUsed() -> Double? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
        let pages = max(app, 0) + Double(vm.wire_count) + Double(vm.compressor_page_count)
        return pages * Double(pageSize)
    }

    /// Bytes in/out on Wi-Fi, Ethernet and cellular interfaces.
    private static func networkBytes() -> (down: UInt64, up: UInt64)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var down: UInt64 = 0
        var up: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.ifa_data else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            down += UInt64(counters.ifi_ibytes)
            up += UInt64(counters.ifi_obytes)
        }
        return (down, up)
    }
}

// MARK: - New screenshots and finished downloads → Fichiers

/// The real home folder. Inside the sandbox NSHomeDirectory() is the
/// app's container, not /Users/<name>.
enum RealHome {
    static let url: URL = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
}

/// Watches one folder and reports each new item once it has stopped
/// growing. What is already there at start is ignored.
@MainActor
final class FolderWatcher {
    /// Browsers write to these first, then rename to the real name.
    static let partialSuffixes = [".download", ".crdownload", ".part", ".partial", ".tmp", ".opdownload"]

    let folder: URL
    private let accept: (URL) -> Bool
    private let onFile: (URL) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var pending: Set<String> = []
    private var scanTask: Task<Void, Never>?

    init(folder: URL, accept: @escaping (URL) -> Bool, onFile: @escaping (URL) -> Void) {
        self.folder = folder
        self.accept = accept
        self.onFile = onFile
    }

    func start() {
        guard source == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[MaVersionFiles] can't watch %@ (errno %d)", folder.path, errno)
            return
        }
        known = Set(listing())
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        watcher.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleScan() }
        }
        watcher.setCancelHandler { close(fd) }
        watcher.resume()
        source = watcher
        NSLog("[MaVersionFiles] watching %@", folder.path)
    }

    func stop() {
        source?.cancel()
        source = nil
        scanTask?.cancel()
        pending.removeAll()
    }

    private func listing() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private func scheduleScan() {
        scanTask?.cancel()
        scanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    private func scan() {
        let names = Set(listing())
        let fresh = names.subtracting(known)
        known = names
        for name in fresh where !name.hasPrefix(".") && !pending.contains(name) {
            let lower = name.lowercased()
            if Self.partialSuffixes.contains(where: { lower.hasSuffix($0) }) { continue }
            pending.insert(name)
            let url = folder.appendingPathComponent(name)
            Task { @MainActor [weak self] in await self?.waitUntilComplete(url) }
        }
    }

    private func waitUntilComplete(_ url: URL) async {
        defer { pending.remove(url.lastPathComponent) }
        var lastSize: Int64 = -1
        // Up to ten minutes for a slow download.
        for _ in 0..<600 {
            try? await Task.sleep(for: .seconds(1))
            guard source != nil else { return }
            // Gone: renamed or moved away before it finished.
            guard let size = Self.size(of: url) else { return }
            let stillWriting = Self.partialSuffixes.contains { FileManager.default.fileExists(atPath: url.path + $0) }
            if size > 0, size == lastSize, !stillWriting {
                if accept(url) { onFile(url) }
                return
            }
            lastSize = size
        }
    }

    /// Folders (an unzipped download) count as size 1 so they settle at once.
    private static func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        if (attributes[.type] as? FileAttributeType) == .typeDirectory { return 1 }
        return (attributes[.size] as? NSNumber)?.int64Value
    }
}

@MainActor
final class NewFilesWatcher {
    static let shared = NewFilesWatcher()

    private var screenshots: FolderWatcher?
    private var downloads: FolderWatcher?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        Defaults.publisher(.screenshotsToShelf)
            .sink { change in Task { @MainActor in NewFilesWatcher.shared.setScreenshots(change.newValue) } }
            .store(in: &cancellables)
        Defaults.publisher(.downloadsToShelf)
            .sink { change in Task { @MainActor in NewFilesWatcher.shared.setDownloads(change.newValue) } }
            .store(in: &cancellables)
    }

    private func setScreenshots(_ on: Bool) {
        guard on else { screenshots?.stop(); screenshots = nil; return }
        guard screenshots == nil else { return }
        let watcher = FolderWatcher(folder: Self.screenshotFolder(), accept: Self.isScreenCapture) { url in
            NewFilesWatcher.addToShelf(url)
            GlanceCenter.shared.show(.screenshot, for: 3)
        }
        watcher.start()
        screenshots = watcher
    }

    private func setDownloads(_ on: Bool) {
        guard on else { downloads?.stop(); downloads = nil; return }
        guard downloads == nil else { return }
        let folder = RealHome.url.appendingPathComponent("Downloads", isDirectory: true)
        let watcher = FolderWatcher(folder: folder, accept: { _ in true }) { url in
            NewFilesWatcher.addToShelf(url)
            GlanceCenter.shared.show(.download(name: url.lastPathComponent), for: 5)
        }
        watcher.start()
        downloads = watcher
    }

    /// Where macOS saves screenshots: the "location" set in the Screenshot
    /// app's options, else the Desktop.
    nonisolated static func screenshotFolder() -> URL {
        if let location = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
           !location.isEmpty {
            let path = location.hasPrefix("~") ? RealHome.url.path + location.dropFirst() : location
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return RealHome.url.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// macOS tags its screenshots and screen recordings with this attribute;
    /// the names are a fallback.
    nonisolated static func isScreenCapture(_ url: URL) -> Bool {
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0 { return true }
        let name = url.lastPathComponent
        return ["Screenshot", "Capture d’écran", "Capture d'écran", "Screen Recording", "Enregistrement de l’écran"]
            .contains { name.hasPrefix($0) }
    }

    static func addToShelf(_ url: URL) {
        guard let bookmark = try? Bookmark(url: url) else { return }
        ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark.data))])
    }
}
