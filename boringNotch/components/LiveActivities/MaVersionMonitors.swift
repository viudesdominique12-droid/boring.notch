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
import Foundation
import IOBluetooth

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
