//
//  MaVersionScreenshot.swift
//  boringNotch — ma-version
//
//  Three-finger tap on the trackpad while the pointer is on the notch →
//  macOS screenshot (⌘⇧3) without the notch in it. The helper watches the
//  trackpad and posts the shortcut (it needs Accessibility for that); this
//  side knows whether the pointer is on the notch and hides the notch
//  windows for the moment of the capture.
//

import AppKit
import Combine
import Defaults

extension Notification.Name {
    static let maVersionThreeFingerTap = Notification.Name("maVersionThreeFingerTap")
}

@MainActor
final class NotchScreenshotTap {
    static let shared = NotchScreenshotTap()

    private var hovered = Set<ObjectIdentifier>()
    private var started = false
    private var busy = false
    private var askedForAccess = false
    private var keepAlive: Timer?
    private var observers: [any NSObjectProtocol] = []
    private var cancellable: AnyCancellable?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        observers.append(NotificationCenter.default.addObserver(
            forName: .maVersionThreeFingerTap, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in NotchScreenshotTap.shared.tapped() }
        })
        // Trackpads stop reporting after sleep until they're restarted.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await NotchScreenshotTap.shared.restartWatching() }
        })
        cancellable = Defaults.publisher(.threeFingerScreenshot)
            .sink { change in Task { @MainActor in NotchScreenshotTap.shared.apply(change.newValue) } }
    }

    /// The notch's own hover state, per screen.
    func setHovering(_ hovering: Bool, id: ObjectIdentifier) {
        if hovering { hovered.insert(id) } else { hovered.remove(id) }
    }

    private func apply(_ on: Bool) {
        keepAlive?.invalidate()
        keepAlive = nil
        guard on else {
            Task { await XPCHelperClient.shared.stopTouchWatching() }
            return
        }
        Task { await ensureWatching() }
        // launchd may relaunch the helper; starting again is a no-op when
        // it's still running.
        keepAlive = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await NotchScreenshotTap.shared.ensureWatching() }
        }
    }

    private func ensureWatching() async {
        let ok = await XPCHelperClient.shared.startTouchWatching()
        let diagnostics = await XPCHelperClient.shared.touchWatchingDiagnostics()
        MaVersionLog.write("watch ok=\(ok) \(diagnostics)")
    }

    private func restartWatching() async {
        guard Defaults[.threeFingerScreenshot] else { return }
        await XPCHelperClient.shared.stopTouchWatching()
        try? await Task.sleep(for: .seconds(1))
        await ensureWatching()
    }

    private func tapped() {
        MaVersionLog.write("tap onNotch=\(!hovered.isEmpty) busy=\(busy)")
        guard Defaults[.threeFingerScreenshot], !hovered.isEmpty, !busy else { return }
        busy = true
        Task { @MainActor in
            await capture()
            busy = false
        }
    }

    private func capture() async {
        let windows = NSApp.windows.filter { $0 is BoringNotchSkyLightWindow && $0.isVisible }
        let alphas = windows.map(\.alphaValue)
        windows.forEach { $0.alphaValue = 0 }
        // Let the window server drop the notch before the shot.
        try? await Task.sleep(for: .milliseconds(90))
        let posted = await XPCHelperClient.shared.postScreenshotShortcut()
        MaVersionLog.write("shortcut posted=\(posted)")
        if posted {
            try? await Task.sleep(for: .milliseconds(900))
        }
        for (window, alpha) in zip(windows, alphas) {
            window.alphaValue = alpha
        }
        if !posted { askForAccessibility() }
    }

    /// The first time, macOS's own prompt; after that, straight to the pane.
    func askForAccessibility() {
        if !askedForAccess {
            askedForAccess = true
            XPCHelperClient.shared.requestAccessibilityAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A small log in the app's container (Library/Caches), to check what the
/// trackpad watcher sees without the Console app.
enum MaVersionLog {
    private static let maxSize = 200_000

    static func write(_ line: String) {
        guard let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = folder.appendingPathComponent("ma-version-screenshot.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxSize {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
