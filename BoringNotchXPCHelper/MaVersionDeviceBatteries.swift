//
//  MaVersionDeviceBatteries.swift
//  BoringNotchXPCHelper — ma-version
//
//  Battery of the iPhone (by cable, or over Wi-Fi when Finder's "Show this
//  iPhone when on Wi-Fi" is on) and of the Apple Watch paired with it. It's
//  read through the private MobileDevice framework, the same way Finder talks
//  to the phone. The app is sandboxed and can't reach usbmuxd; this helper
//  isn't sandboxed. Nothing here pairs a device or asks it to trust the Mac.
//

import Foundation

extension BoringNotchXPCHelper {
    @objc func mobileDeviceBatteries(with reply: @escaping (Data) -> Void) {
        MobileDeviceBatteries.shared.read(reply)
    }
}

final class MobileDeviceBatteries: @unchecked Sendable {
    static let shared = MobileDeviceBatteries()

    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias Subscribe = @convention(c) (
        Callback, UInt32, UInt32, UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>, CFDictionary?
    ) -> Int32
    private typealias DeviceCall = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias CopyValue = @convention(c) (UnsafeMutableRawPointer, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias CopyIdentifier = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>?
    private typealias Retain = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias Release = @convention(c) (UnsafeMutableRawPointer) -> Void

    private struct API {
        let subscribe: Subscribe
        let connect: DeviceCall
        let disconnect: DeviceCall
        let isPaired: DeviceCall
        let validatePairing: DeviceCall
        let startSession: DeviceCall
        let stopSession: DeviceCall
        let interfaceType: DeviceCall
        let copyValue: CopyValue
        let copyIdentifier: CopyIdentifier
        let retain: Retain
        let release: Release
    }

    /// One connected device as MobileDevice announced it.
    private struct Entry {
        let device: UnsafeMutableRawPointer
        let identifier: String
        /// 1 = USB, 2 = Wi-Fi, 3 = through the paired iPhone (the Watch).
        let interface: Int32
    }

    private static let callback: Callback = { info, _ in
        MobileDeviceBatteries.shared.handle(info)
    }

    private let queue = DispatchQueue(label: "ma-version.device-batteries")
    private let lock = NSLock()
    private var api: API?
    private var entries: [String: Entry] = [:]
    private var notification: UnsafeMutableRawPointer?
    private var started = false

    private init() {}

    /// Replies with a JSON array, one object per device that gave a level.
    func read(_ reply: @escaping (Data) -> Void) {
        queue.async { [self] in
            if !started {
                started = true
                if start() {
                    // Devices already plugged in are announced right after
                    // subscribing; give them a moment before the first read.
                    Thread.sleep(forTimeInterval: 2)
                }
            }
            let empty = Data("[]".utf8)
            guard let api = currentAPI() else {
                reply(empty)
                return
            }

            // Hold our own reference while reading, in case the device
            // disconnects meanwhile.
            lock.lock()
            let snapshot = entries.values.sorted { $0.interface < $1.interface }
            for entry in snapshot { _ = api.retain(entry.device) }
            lock.unlock()

            var seen = Set<String>()
            var results: [[String: Any]] = []
            for entry in snapshot {
                defer { api.release(entry.device) }
                // The same iPhone can show up by cable and over Wi-Fi: keep
                // the first, which is the cable.
                guard !seen.contains(entry.identifier),
                      let result = readBattery(entry, api: api) else { continue }
                seen.insert(entry.identifier)
                results.append(result)
            }
            reply((try? JSONSerialization.data(withJSONObject: results)) ?? empty)
        }
    }

    private func currentAPI() -> API? {
        lock.lock()
        defer { lock.unlock() }
        return api
    }

    private func readBattery(_ entry: Entry, api: API) -> [String: Any]? {
        let device = entry.device
        guard api.connect(device) == 0 else { return nil }
        defer { _ = api.disconnect(device) }
        // A session needs the pairing the user already made with this Mac.
        // The Watch, reached through the iPhone, answers without one.
        var session = false
        if api.isPaired(device) == 1, api.validatePairing(device) == 0, api.startSession(device) == 0 {
            session = true
        }
        defer { if session { _ = api.stopSession(device) } }

        func value(_ domain: String?, _ key: String) -> Any? {
            api.copyValue(device, domain.map { $0 as CFString }, key as CFString)?.takeRetainedValue()
        }
        let battery = "com.apple.mobile.battery"
        guard let level = (value(battery, "BatteryCurrentCapacity") as? NSNumber)?.intValue,
              (0...100).contains(level) else { return nil }
        return [
            "id": entry.identifier,
            "name": value(nil, "DeviceName") as? String ?? "",
            "kind": value(nil, "DeviceClass") as? String ?? "",
            "level": level,
            "charging": (value(battery, "BatteryIsCharging") as? NSNumber)?.boolValue ?? false,
            "interface": Int(entry.interface),
        ]
    }

    /// On the helper's queue.
    private func start() -> Bool {
        guard let api = Self.loadAPI() else {
            NSLog("[boringNotch] MobileDevice unavailable")
            return false
        }
        lock.lock()
        self.api = api
        lock.unlock()
        // Its own thread with a run loop, whichever way the framework
        // delivers notifications.
        let thread = Thread { [self] in
            guard let api = currentAPI() else { return }
            var note: UnsafeMutableRawPointer?
            let options = ["NotificationOptionSearchForPairedDevices": true] as CFDictionary
            let status = api.subscribe(Self.callback, 0, 0, nil, &note, options)
            lock.lock()
            notification = note
            lock.unlock()
            NSLog("[boringNotch] MobileDevice subscribe: \(status)")
            CFRunLoopRun()
        }
        thread.name = "ma-version.mobiledevice"
        thread.start()
        return true
    }

    /// MobileDevice's notification callback. Info is
    /// `{ am_device *device; unsigned int message; }`.
    private func handle(_ info: UnsafeMutableRawPointer?) {
        guard let info, let api = currentAPI(),
              let device = info.load(as: UnsafeMutableRawPointer?.self) else { return }
        let message = info.load(fromByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        let identifier = api.copyIdentifier(device)?.takeRetainedValue() as String? ?? ""
        let interface = api.interfaceType(device)
        let key = "\(identifier)#\(interface)"

        lock.lock()
        defer { lock.unlock() }
        switch message {
        case 1: // connected
            guard entries[key] == nil, let retained = api.retain(device) else { return }
            entries[key] = Entry(device: retained, identifier: identifier, interface: interface)
        case 2: // disconnected
            if let old = entries.removeValue(forKey: key) { api.release(old.device) }
        default:
            break
        }
    }

    private static func loadAPI() -> API? {
        let path = "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let subscribe = symbol("AMDeviceNotificationSubscribeWithOptions", Subscribe.self),
              let connect = symbol("AMDeviceConnect", DeviceCall.self),
              let disconnect = symbol("AMDeviceDisconnect", DeviceCall.self),
              let isPaired = symbol("AMDeviceIsPaired", DeviceCall.self),
              let validatePairing = symbol("AMDeviceValidatePairing", DeviceCall.self),
              let startSession = symbol("AMDeviceStartSession", DeviceCall.self),
              let stopSession = symbol("AMDeviceStopSession", DeviceCall.self),
              let interfaceType = symbol("AMDeviceGetInterfaceType", DeviceCall.self),
              let copyValue = symbol("AMDeviceCopyValue", CopyValue.self),
              let copyIdentifier = symbol("AMDeviceCopyDeviceIdentifier", CopyIdentifier.self),
              let retain = symbol("AMDeviceRetain", Retain.self),
              let release = symbol("AMDeviceRelease", Release.self)
        else { return nil }
        return API(
            subscribe: subscribe, connect: connect, disconnect: disconnect,
            isPaired: isPaired, validatePairing: validatePairing,
            startSession: startSession, stopSession: stopSession,
            interfaceType: interfaceType, copyValue: copyValue,
            copyIdentifier: copyIdentifier, retain: retain, release: release
        )
    }
}
