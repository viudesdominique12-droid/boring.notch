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
        // The hover flag alone could go stale (its reset is a delayed task),
        // so the pointer must also be inside a visible notch window.
        let mouse = NSEvent.mouseLocation
        let inWindow = NSApp.windows.contains {
            $0 is BoringNotchSkyLightWindow && $0.isVisible && $0.frame.contains(mouse)
        }
        MaVersionLog.write("tap hovered=\(!hovered.isEmpty) inWindow=\(inWindow) busy=\(busy)")
        guard Defaults[.threeFingerScreenshot], !hovered.isEmpty, inWindow, !busy else { return }
        busy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            busy = false
        }
        Task { @MainActor in await capture() }
    }

    private func capture() async {
        let windows = NSApp.windows.filter { $0 is BoringNotchSkyLightWindow && $0.isVisible }
        let alphas = windows.map(\.alphaValue)
        let restore = {
            for (window, alpha) in zip(windows, alphas) {
                window.alphaValue = alpha
            }
        }
        windows.forEach { $0.alphaValue = 0 }
        // Brought back on a fixed delay, even if the helper never answers.
        let restoreTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1000))
            guard !Task.isCancelled else { return }
            restore()
        }

        let folder = NewFilesWatcher.screenshotFolder()
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        // Let the window server drop the notch before the shot.
        try? await Task.sleep(for: .milliseconds(90))
        let posted = await XPCHelperClient.shared.postScreenshotShortcut()
        MaVersionLog.write("shortcut posted=\(posted)")
        guard posted else {
            restoreTask.cancel()
            restore()
            askForAccessibility()
            return
        }

        // With the floating thumbnail on, macOS writes the file only when
        // the thumbnail goes away (about 5 s).
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            let now = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            if let name = now.subtracting(before).first(where: { !$0.hasPrefix(".") }) {
                MaVersionLog.write("screenshot file: \(name)")
                return
            }
        }
        MaVersionLog.write("no new file in \(folder.path) after 10 s")
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
