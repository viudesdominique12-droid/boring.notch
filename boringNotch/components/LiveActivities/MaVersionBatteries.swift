//
//  MaVersionBatteries.swift
//  boringNotch — ma-version
//
//  Batteries page data: the Mac (IOKit power sources), the iPhone and the
//  Apple Watch paired with it (MobileDevice, read by the XPC helper) and
//  connected AirPods (IOBluetooth). The last value of each device is kept,
//  so a device that's out of reach still shows, greyed, with its age.
//

import Foundation
import IOBluetooth
import IOKit.ps

struct DeviceBattery: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case mac, iphone, ipad, watch, headphones, other

        var isMobile: Bool { self == .iphone || self == .ipad || self == .watch || self == .other }

        /// Order on the page after the Mac.
        var rank: Int {
            switch self {
            case .mac: return 0
            case .iphone: return 1
            case .watch: return 2
            case .ipad: return 3
            case .other: return 4
            case .headphones: return 5
            }
        }
    }

    let id: String
    var kind: Kind
    var title: String
    var symbol: String
    var level: Int
    var charging: Bool
    /// What to show under the title while the device is in reach.
    var detail: String
    var updated: Date
    var live: Bool
}

@MainActor
final class DeviceBatteryMonitor: ObservableObject {
    static let shared = DeviceBatteryMonitor()

    @Published private(set) var devices: [DeviceBattery] = []

    private static let cacheKey = "maVersionDeviceBatteries"
    private static let forgetAfter: TimeInterval = 30 * 24 * 3600

    private var known: [String: DeviceBattery] = [:]
    private var timer: Timer?
    private var readingMobile = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let saved = try? JSONDecoder().decode([DeviceBattery].self, from: data) {
            for var device in saved where Date().timeIntervalSince(device.updated) < Self.forgetAfter {
                device.live = false
                known[device.id] = device
            }
        }
        devices = Self.layout(Array(known.values))
    }

    /// While the Batteries page is showing.
    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in DeviceBatteryMonitor.shared.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        // The Mac and Bluetooth answer at once.
        var local: [DeviceBattery] = []
        if let mac = Self.macBattery() { local.append(mac) }
        local += Self.bluetoothBatteries()
        merge(local, replacing: { !$0.isMobile })

        // The phone goes through the helper and can take a second or two.
        guard !readingMobile else { return }
        readingMobile = true
        Task { @MainActor in
            let data = await XPCHelperClient.shared.mobileDeviceBatteries()
            readingMobile = false
            // Helper unreachable: keep what's shown rather than grey it all.
            guard let data else { return }
            merge(Self.mobileBatteries(from: data), replacing: { $0.isMobile })
        }
    }

    /// Fresh readings for one group of kinds; known devices of that group
    /// that didn't answer turn grey.
    private func merge(_ fresh: [DeviceBattery], replacing group: (DeviceBattery.Kind) -> Bool) {
        for (id, device) in known where group(device.kind) {
            known[id]?.live = false
        }
        for device in fresh { known[device.id] = device }
        let next = Self.layout(Array(known.values))
        if next != devices { devices = next }
        if let data = try? JSONEncoder().encode(Array(known.values)) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    /// Up to four tiles: the Mac, then the phone and watch, then the most
    /// recent headphones.
    private static func layout(_ all: [DeviceBattery]) -> [DeviceBattery] {
        func recent(_ a: DeviceBattery, _ b: DeviceBattery) -> Bool {
            if a.live != b.live { return a.live }
            return a.updated > b.updated
        }
        let mac = all.filter { $0.kind == .mac }
        let mobile = all.filter { $0.kind.isMobile }.sorted {
            $0.kind.rank != $1.kind.rank ? $0.kind.rank < $1.kind.rank : recent($0, $1)
        }
        let headphones = all.filter { $0.kind == .headphones }.sorted(by: recent).prefix(1)
        let room = max(4 - mac.count - headphones.count, 0)
        return mac + mobile.prefix(room) + headphones
    }

    // MARK: - Sources

    private static func macBattery() -> DeviceBattery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            let level = min(Int((Double(current) / Double(maximum) * 100).rounded()), 100)
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let toFull = description[kIOPSTimeToFullChargeKey] as? Int ?? -1
            let toEmpty = description[kIOPSTimeToEmptyKey] as? Int ?? -1
            let detail: String
            if charging {
                detail = toFull > 0 ? "100 % dans \(duration(toFull))" : "en charge"
            } else if onPower {
                detail = level >= 99 ? "chargé" : "branché"
            } else {
                detail = toEmpty > 0 ? "reste \(duration(toEmpty))" : "sur batterie"
            }
            return DeviceBattery(
                id: "mac", kind: .mac, title: "Mac", symbol: "laptopcomputer",
                level: level, charging: charging, detail: detail, updated: Date(), live: true
            )
        }
        return nil
    }

    private static func mobileBatteries(from data: Data) -> [DeviceBattery] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let level = item["level"] as? Int else { return nil }
            let charging = item["charging"] as? Bool ?? false
            let interface = item["interface"] as? Int ?? 0
            let kind: DeviceBattery.Kind
            switch item["kind"] as? String ?? "" {
            case "iPhone": kind = .iphone
            case "Watch": kind = .watch
            case "iPad": kind = .ipad
            default: kind = .other
            }
            let title: String
            let symbol: String
            switch kind {
            case .iphone: (title, symbol) = ("iPhone", "iphone")
            case .watch: (title, symbol) = ("Montre", "applewatch")
            case .ipad: (title, symbol) = ("iPad", "ipad")
            default: (title, symbol) = (item["name"] as? String ?? "Appareil", "iphone")
            }
            let detail: String
            if charging {
                detail = "en charge"
            } else {
                switch interface {
                case 1: detail = "par câble"
                case 2: detail = "en Wi-Fi"
                default: detail = "via l'iPhone"
                }
            }
            return DeviceBattery(
                id: id, kind: kind, title: title, symbol: symbol,
                level: level, charging: charging, detail: detail, updated: Date(), live: true
            )
        }
    }

    /// Connected AirPods-style devices. IOBluetooth exposes their battery
    /// through undocumented properties, so every read is guarded.
    private static func bluetoothBatteries() -> [DeviceBattery] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return paired.compactMap { device in
            guard device.isConnected() else { return nil }
            func read(_ key: String) -> Int? {
                guard device.responds(to: NSSelectorFromString(key)),
                      let value = device.value(forKey: key) as? NSNumber,
                      value.intValue > 0
                else { return nil }
                return min(value.intValue, 100)
            }
            let buds = [read("batteryPercentLeft"), read("batteryPercentRight")].compactMap { $0 }
            guard let level = buds.min() ?? read("batteryPercentSingle") ?? read("batteryPercentCombined")
            else { return nil }
            let name = device.name ?? "Écouteurs"
            let detail = read("batteryPercentCase").map { "boîtier \($0) %" } ?? "connectés"
            return DeviceBattery(
                id: "bt-" + (device.addressString ?? name), kind: .headphones,
                title: shortName(name), symbol: HeadphonesWatcher.symbol(for: name),
                level: level, charging: false, detail: detail, updated: Date(), live: true
            )
        }
    }

    private static func shortName(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "AirPods Max" }
        if n.contains("airpods pro") { return "AirPods Pro" }
        if n.contains("airpods") { return "AirPods" }
        if n.contains("beats") { return "Beats" }
        return name
    }

    private static func duration(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : String(format: "%d h %02d", h, m)
    }
}
