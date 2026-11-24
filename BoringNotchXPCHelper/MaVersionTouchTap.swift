//
//  MaVersionTouchTap.swift
//  BoringNotchXPCHelper — ma-version
//
//  Three-finger tap → screenshot. The app is sandboxed and never key, so it
//  can't count fingers itself; this helper isn't sandboxed and reads raw
//  trackpad contacts from the private MultitouchSupport framework (the
//  approach MiddleClick-style utilities use). The app decides whether the
//  pointer is on the notch, hides it, then asks here for ⌘⇧3.
//

import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import IOKit

extension BoringNotchXPCHelper {
    @objc func startTouchWatching(with reply: @escaping (Bool) -> Void) {
        // Same pattern as notification watching: capture the proxy inside
        // the incoming call, cast to the full app-delegate protocol.
        let proxy = NSXPCConnection.current()?.remoteObjectProxyWithErrorHandler { error in
            NSLog("[boringNotch] tap callback failed: \(error.localizedDescription)")
        }
        let delegate = proxy as? BoringNotchXPCAppDelegate
        DispatchQueue.main.async {
            reply(ThreeFingerTapWatcher.shared.start { delegate?.threeFingerTapDetected() })
        }
    }

    @objc func stopTouchWatching() {
        DispatchQueue.main.async { ThreeFingerTapWatcher.shared.stop() }
    }

    @objc func touchWatchingDiagnostics(with reply: @escaping (String) -> Void) {
        reply(ThreeFingerTapWatcher.shared.diagnostics() + " ax=\(AXIsProcessTrusted())")
    }

    @objc func postScreenshotShortcut(with reply: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted() else {
            reply(false)
            return
        }
        reply(ScreenshotShortcut.post())
    }

    @objc func playHaptic(_ actuationID: Int32) {
        TrackpadHaptics.shared.play(actuationID)
    }
}

/// Drives the Force Touch trackpad's actuator directly (MultitouchSupport's
/// MTActuator, as HapticKey does), which works from a background process.
final class TrackpadHaptics: @unchecked Sendable {
    static let shared = TrackpadHaptics()

    private typealias CreateFromID = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias Open = @convention(c) (CFTypeRef) -> Int32
    private typealias Actuate = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32

    private let queue = DispatchQueue(label: "ma-version.haptics")
    private var actuator: CFTypeRef?
    private var actuate: Actuate?
    /// Only when the framework itself can't be loaded.
    private var failed = false

    private init() {}

    func play(_ actuationID: Int32) {
        queue.async { [self] in
            guard let actuator = actuator ?? open(), let actuate else { return }
            if actuate(actuator, actuationID, 0, 1.0, 2.0) != 0 {
                // The trackpad may have gone away (sleep, Bluetooth pad):
                // reopen next time.
                self.actuator = nil
            }
        }
    }

    private func open() -> CFTypeRef? {
        guard !failed else { return nil }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW),
              let createSymbol = dlsym(handle, "MTActuatorCreateFromDeviceID"),
              let openSymbol = dlsym(handle, "MTActuatorOpen"),
              let actuateSymbol = dlsym(handle, "MTActuatorActuate") else {
            failed = true
            return nil
        }
        let create = unsafeBitCast(createSymbol, to: CreateFromID.self)
        let openActuator = unsafeBitCast(openSymbol, to: Open.self)
        actuate = unsafeBitCast(actuateSymbol, to: Actuate.self)

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let id = IORegistryEntryCreateCFProperty(service, "Multitouch ID" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber,
                  let candidate = create(id.uint64Value)?.takeRetainedValue(),
                  openActuator(candidate) == 0 else { continue }
            actuator = candidate
            return candidate
        }
        NSLog("[boringNotch] no trackpad actuator found")
        return nil
    }
}

/// Posts ⌘⇧3 the way a keyboard would, so macOS takes its own screenshot
/// (sound, thumbnail, saved where the Screenshot app says).
enum ScreenshotShortcut {
    static func post() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let command: CGKeyCode = 0x37
        let shift: CGKeyCode = 0x38
        let three: CGKeyCode = 0x14
        let both: CGEventFlags = [.maskCommand, .maskShift]
        let sequence: [(CGKeyCode, Bool, CGEventFlags)] = [
            (command, true, .maskCommand),
            (shift, true, both),
            (three, true, both),
            (three, false, both),
            (shift, false, .maskCommand),
            (command, false, []),
        ]
        for (key, down, flags) in sequence {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return false }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(6_000)
        }
        return true
    }
}

final class ThreeFingerTapWatcher: @unchecked Sendable {
    static let shared = ThreeFingerTapWatcher()

    private typealias FrameCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Void
    private typealias CreateList = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, FrameCallback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void

    private struct API {
        let createList: CreateList
        let register: Register
        let unregister: Register
        let start: Start
        let stop: Stop
    }

    /// One contact in a frame (MTTouch): 96 bytes, identifier at 16,
    /// normalized position (0...1) at 32 and 36.
    private static let touchStride = 96

    // Tap: fingers down and all lifted within this long, moving less than
    // this fraction of the pad.
    private static let maxDuration = 0.45
    private static let maxMove: Float = 0.05

    private static let frameCallback: FrameCallback = { _, touches, count, timestamp, _ in
        ThreeFingerTapWatcher.shared.frame(touches, Int(count), timestamp)
    }

    private let lock = NSLock()
    private var api: API?
    private var devices: CFMutableArray?
    private var onTap: (() -> Void)?
    private var running = false
    private var lastError = ""

    // Gesture in progress.
    private var active = false
    private var startTime = 0.0
    private var maxCount = 0
    private var startPositions: [Int32: (Float, Float)] = [:]
    private var moved: Float = 0
    private var lastTap = 0.0

    // Diagnostics.
    private var deviceCount = 0
    private var frames = 0
    private var maxFingersSeen = 0
    private var taps = 0
    private var lastGesture = "none"

    private init() {}

    /// Idempotent; call it again to refresh the callback.
    func start(onTap: @escaping () -> Void) -> Bool {
        lock.lock()
        self.onTap = onTap
        let alreadyRunning = running
        lock.unlock()
        if alreadyRunning { return true }

        guard let api = Self.loadAPI() else {
            setError("MultitouchSupport unavailable")
            return false
        }
        guard let list = api.createList()?.takeRetainedValue() else {
            setError("no multitouch device list")
            return false
        }
        let count = CFArrayGetCount(list)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            api.register(device, Self.frameCallback)
            api.start(device, 0)
        }
        lock.lock()
        self.api = api
        devices = list
        deviceCount = count
        running = count > 0
        if count == 0 { lastError = "no trackpad found" }
        let started = running
        lock.unlock()
        NSLog("[boringNotch] three-finger tap watcher: \(count) device(s)")
        return started
    }

    func stop() {
        lock.lock()
        let api = self.api
        let list = devices
        devices = nil
        running = false
        active = false
        lock.unlock()
        guard let api, let list else { return }
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            api.unregister(device, Self.frameCallback)
            api.stop(device)
        }
    }

    func diagnostics() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "devices=\(deviceCount) running=\(running) frames=\(frames) maxFingers=\(maxFingersSeen) taps=\(taps) last=[\(lastGesture)] err=\(lastError.isEmpty ? "-" : lastError)"
    }

    private func setError(_ message: String) {
        lock.lock()
        lastError = message
        lock.unlock()
        NSLog("[boringNotch] three-finger tap watcher: \(message)")
    }

    /// Runs on MultitouchSupport's own thread for every trackpad frame.
    private func frame(_ touches: UnsafeMutableRawPointer?, _ count: Int, _ time: Double) {
        lock.lock()
        frames &+= 1
        maxFingersSeen = max(maxFingersSeen, count)

        if count > 0 {
            if !active {
                active = true
                startTime = time
                maxCount = 0
                startPositions.removeAll(keepingCapacity: true)
                moved = 0
            }
            maxCount = max(maxCount, count)
            if let touches {
                for index in 0..<count {
                    let touch = touches.advanced(by: index * Self.touchStride)
                    let id = touch.load(fromByteOffset: 16, as: Int32.self)
                    let x = touch.load(fromByteOffset: 32, as: Float.self)
                    let y = touch.load(fromByteOffset: 36, as: Float.self)
                    guard x.isFinite, y.isFinite else { continue }
                    if let origin = startPositions[id] {
                        moved = max(moved, hypotf(x - origin.0, y - origin.1))
                    } else {
                        startPositions[id] = (x, y)
                    }
                }
            }
            lock.unlock()
            return
        }

        guard active else {
            lock.unlock()
            return
        }
        active = false
        let duration = time - startTime
        lastGesture = String(format: "fingers=%d %.2fs move=%.3f", maxCount, duration, moved)
        let isTap = maxCount == 3
            && duration <= Self.maxDuration
            && moved <= Self.maxMove
            && time - lastTap > 0.6
        var callback: (() -> Void)?
        if isTap {
            lastTap = time
            taps += 1
            callback = onTap
        }
        lock.unlock()
        if let callback {
            DispatchQueue.main.async { callback() }
        }
    }

    private static func loadAPI() -> API? {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW),
              let createList = dlsym(handle, "MTDeviceCreateList"),
              let register = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let start = dlsym(handle, "MTDeviceStart"),
              let stop = dlsym(handle, "MTDeviceStop") else { return nil }
        return API(
            createList: unsafeBitCast(createList, to: CreateList.self),
            register: unsafeBitCast(register, to: Register.self),
            unregister: unsafeBitCast(unregister, to: Register.self),
            start: unsafeBitCast(start, to: Start.self),
            stop: unsafeBitCast(stop, to: Stop.self)
        )
    }
}
