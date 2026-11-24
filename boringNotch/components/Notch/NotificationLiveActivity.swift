//
//  NotificationLiveActivity.swift
//  boringNotch
//

import SwiftUI

private struct NotificationSourceIcon: View {
    let bundleID: String?
    let size: CGFloat

    var body: some View {
        if let bundleID {
            appIcon(for: bundleID)
                .resizable().scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            Image(systemName: "bell")
                .font(.system(size: size * 0.55))
                .frame(width: size, height: size)
        }
    }
}

struct NotificationLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    let notification: SystemNotification

    @State private var ringScale: CGFloat = 1
    @State private var ringOpacity = 0.0

    private var itemSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    var body: some View {
        HStack {
            NotificationSourceIcon(bundleID: notification.bundleID, size: itemSize)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            ZStack {
                Circle()
                    .stroke(Color.effectiveAccent, lineWidth: 1.5)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
                Circle()
                    .fill(Color.effectiveAccent)
                    .frame(width: 7, height: 7)
            }
            .frame(width: itemSize, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .onAppear { pulse() }
        .onChange(of: notification.id) { _, _ in pulse() }
    }

    private func pulse() {
        ringScale = 1
        ringOpacity = 0.8
        withAnimation(.easeOut(duration: 0.6)) {
            ringScale = 1.8
            ringOpacity = 0
        }
    }
}

/// ma-version: sender and start of the message under the closed notch, so a
/// notification can be read without hovering.
struct NotificationPreviewRow: View {
    let notification: SystemNotification
    /// Width of the closed activity row above, to line up with it.
    let width: CGFloat

    static func heading(_ notification: SystemNotification) -> String? {
        if let title = notification.title, !title.isEmpty, title != notification.appName { return title }
        return notification.appName
    }

    static func message(_ notification: SystemNotification) -> String? {
        let parts = [notification.subtitle, notification.body]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    static func hasText(_ notification: SystemNotification) -> Bool {
        heading(notification) != nil || message(notification) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let heading = Self.heading(notification) {
                Text(heading)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            if let message = Self.message(notification) {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: max(width, 160), alignment: .leading)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .onAppear {
            // Lengths only: the text itself never goes to disk.
            MaVersionLog.write(
                "notification preview: heading=\(Self.heading(notification)?.count ?? 0) message=\(Self.message(notification)?.count ?? 0) width=\(Int(width))"
            )
        }
    }
}

struct NotificationExpandedView: View {
    @ObservedObject private var manager = SystemNotificationManager.shared
    let notification: SystemNotification

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: openSourceApp) {
                HStack(alignment: .center, spacing: 12) {
                    NotificationSourceIcon(bundleID: notification.bundleID, size: 46)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(notification.appName ?? "Notification")
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)

                            Text(notification.receivedAt, style: .relative)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }

                        if let title = notification.title, title != notification.appName {
                            Text(title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }

                        if let subtitle = notification.subtitle {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let body = notification.body {
                            Text(body)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary.opacity(0.9))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(notification.appName ?? "App") notification")
            .accessibilityHint("Opens \(notification.appName ?? "the app")")

            HStack(spacing: 4) {
                if !manager.queuedNotifications.isEmpty {
                    Button {
                        manager.showNextQueued()
                    } label: {
                        Text("+\(manager.queuedNotifications.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show next queued notification")
                }

                Button {
                    manager.dismissActive(token: notification.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification")
            }
            .padding(.trailing, 4)
        }
        .onAppear { if !manager.openedAutomatically { manager.holdActive() } }
        .onDisappear { manager.resumeDismiss() }
    }

    private func openSourceApp() {
        Task {
            guard await manager.open(notification) else { return }
            manager.dismissActive(token: notification.id)
        }
    }
}
