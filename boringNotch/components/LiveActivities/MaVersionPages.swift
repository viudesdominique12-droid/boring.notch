//
//  MaVersionPages.swift
//  boringNotch — ma-version
//
//  Wiring for layout B: binds the pure page views (MaVersionPageViews.swift)
//  to the app's managers and settings.
//

import AppKit
import Combine
import Defaults
import EventKit
import SwiftUI

// MARK: - Pages

enum NotchPage: String, CaseIterable, Identifiable {
    case music
    case weather
    case agenda
    case timer
    case files
    case clipboard
    case shortcuts
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return "Musique"
        case .weather: return "Météo"
        case .agenda: return "Agenda"
        case .timer: return "Minuteur"
        case .files: return "Fichiers"
        case .clipboard: return "Copies"
        case .shortcuts: return "Apps"
        case .system: return "Système"
        }
    }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .weather: return "cloud.sun.fill"
        case .agenda: return "calendar"
        case .timer: return "timer"
        case .files: return "tray.and.arrow.down.fill"
        case .clipboard: return "doc.on.clipboard"
        case .shortcuts: return "square.grid.2x2.fill"
        case .system: return "cpu"
        }
    }
}

/// Which page is showing; remembered across openings when the user wants it.
@MainActor
final class NotchPageModel: ObservableObject {
    static let shared = NotchPageModel()

    @Published var index: Int {
        didSet {
            guard index != oldValue else { return }
            Defaults[.lastNotchPage] = NotchPage.allCases[index].rawValue
        }
    }

    var page: NotchPage { NotchPage.allCases[index] }

    private init() {
        let saved = Defaults[.rememberLastPage]
            ? NotchPage(rawValue: Defaults[.lastNotchPage]) ?? .music
            : .music
        index = NotchPage.allCases.firstIndex(of: saved) ?? 0
    }

    /// Called when the notch closes.
    func notchDidClose() {
        if !Defaults[.rememberLastPage] { index = 0 }
    }
}

// MARK: - Pager

struct MaVersionPagesView: View {
    let albumArtNamespace: Namespace.ID
    let horizontalMediaGestureFeedback: CGFloat
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var model = NotchPageModel.shared
    @Default(.pageDepthEffect) private var depthEffect
    @Default(.pageHaptics) private var haptics
    @Default(.invertPageSwipe) private var invertSwipe
    @Default(.lowOpenNotch) private var lowNotch

    var body: some View {
        SwipePager(
            count: NotchPage.allCases.count,
            index: $model.index,
            depthEffect: depthEffect,
            haptics: haptics,
            invertSwipe: invertSwipe
        ) { i in
            switch NotchPage.allCases[i] {
            case .music:
                CompactHomeView(
                    albumArtNamespace: albumArtNamespace,
                    horizontalMediaGestureFeedback: horizontalMediaGestureFeedback,
                    showsBatteryOverlay: false
                )
            case .weather:
                WeatherPage()
            case .agenda:
                AgendaPage()
            case .timer:
                TimerPage()
            case .files:
                ShelfView(dropInteraction: vm.dropInteraction, animation: vm.animation)
                    .environment(\.compactShelf, true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, lowNotch ? 2 : 4)
            case .clipboard:
                ClipboardPage()
            case .shortcuts:
                ShortcutsPage()
            case .system:
                SystemPage()
            }
        }
        .environment(\.lowNotch, lowNotch)
        .onDisappear { model.notchDidClose() }
    }
}

// MARK: - Top bar (open) and status (closed)

struct MaVersionTopBar: View {
    let notchWidth: CGFloat
    @ObservedObject private var model = NotchPageModel.shared
    @ObservedObject private var weather = WeatherManager.shared
    @ObservedObject private var battery = BatteryStatusViewModel.shared
    @Default(.showBatteryIndicator) private var showBattery

    var body: some View {
        PagedTopBarContent(
            title: title,
            symbol: model.page.symbol,
            temperature: weather.shortTemperature,
            weatherCode: weather.weatherCode,
            isDay: weather.isDay,
            batteryLevel: showBattery ? Int(battery.levelBattery.rounded()) : nil,
            isCharging: battery.isCharging,
            notchGap: notchWidth
        )
        .animation(.easeInOut(duration: 0.2), value: model.index)
    }

    /// Short page names only: the space left of the camera is ~70 pt.
    private var title: String { model.page.title }
}

struct MaVersionClosedStatus: View {
    let notchWidth: CGFloat
    let height: CGFloat
    @ObservedObject private var weather = WeatherManager.shared
    @ObservedObject private var battery = BatteryStatusViewModel.shared

    var body: some View {
        ClosedStatusContent(
            temperature: weather.shortTemperature,
            weatherCode: weather.weatherCode,
            isDay: weather.isDay,
            batteryLevel: Int(battery.levelBattery.rounded()),
            isCharging: battery.isCharging,
            notchWidth: notchWidth,
            height: height
        )
        .onAppear { weather.refreshIfNeeded() }
    }
}

// MARK: - Closed-notch glances

struct MaVersionChargingActivity: View {
    let notchWidth: CGFloat
    let height: CGFloat
    @ObservedObject private var battery = BatteryStatusViewModel.shared

    var body: some View {
        ChargingActivityContent(
            level: Int(battery.levelBattery.rounded()),
            isCharging: battery.isCharging || battery.isPluggedIn,
            notchWidth: notchWidth,
            height: height
        )
    }
}

struct MaVersionEventActivity: View {
    let notchWidth: CGFloat
    let height: CGFloat
    @ObservedObject private var monitor = UpcomingEventMonitor.shared

    var body: some View {
        if let event = monitor.upcoming {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                EventActivityContent(
                    title: event.title,
                    color: Color(nsColor: event.color),
                    start: event.start,
                    now: context.date,
                    notchWidth: notchWidth,
                    height: height
                )
            }
        }
    }
}

struct MaVersionGlanceActivity: View {
    let notchWidth: CGFloat
    let height: CGFloat
    @ObservedObject private var center = GlanceCenter.shared

    var body: some View {
        if let kind = center.current {
            GlanceActivityContent(kind: kind, now: Date(), notchWidth: notchWidth, height: height)
        }
    }
}

// MARK: - Timer live activity (closed notch)

struct MaVersionTimerActivity: View {
    let notchWidth: CGFloat
    let height: CGFloat
    @ObservedObject private var timer = FocusTimer.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TimerLiveActivityContent(
                mode: timer.finishedMode ?? timer.mode,
                remaining: timer.remaining(at: context.date),
                total: timer.total,
                isRunning: timer.isRunning,
                finished: timer.finishedMode != nil,
                notchWidth: notchWidth,
                height: height
            )
        }
    }
}

// MARK: - Weather

private struct WeatherPage: View {
    @ObservedObject private var weather = WeatherManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            WeatherPageContent(state: weather.pageState, now: context.date)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            switch weather.status {
            case .needsCity, .cityNotFound:
                SettingsWindowController.shared.showWindow()
            default:
                weather.refresh()
            }
        }
        .onAppear { weather.refreshIfNeeded() }
    }
}

// MARK: - Agenda

private struct AgendaPage: View {
    @ObservedObject private var calendar = CalendarManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            AgendaPageContent(state: state(now: context.date), now: context.date)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if calendar.calendarAuthorizationStatus == .fullAccess { openCalendarApp() } else { askForAccess() }
        }
        .task {
            await calendar.checkCalendarAuthorization()
            await calendar.updateCurrentDate(Date())
        }
    }

    /// Not asked yet → the system prompt. Refused → the Calendars pane of
    /// System Settings, where the switch is.
    private func askForAccess() {
        Task { @MainActor in
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                await calendar.checkCalendarAuthorization()
                await calendar.updateCurrentDate(Date())
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func state(now: Date) -> AgendaPageState {
        guard calendar.calendarAuthorizationStatus == .fullAccess else { return .noAccess }
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        let items = calendar.events
            .filter { event in
                if case .reminder = event.type { return false }
                return event.end > now && event.start < endOfDay
            }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return !lhs.isAllDay }
                return lhs.start < rhs.start
            }
            .prefix(3)
            .map { event in
                AgendaItem(
                    id: event.id,
                    title: event.title,
                    start: event.start,
                    end: event.end,
                    isAllDay: event.isAllDay,
                    color: Color(nsColor: event.calendar.color)
                )
            }
        return .loaded(Array(items))
    }

    private func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

// MARK: - Timer / Pomodoro

@MainActor
final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()

    @Published private(set) var mode: FocusMode = .focus
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var total: TimeInterval = 25 * 60
    /// Set when a countdown ends, cleared a few seconds later: the closed
    /// notch shows "Fini" in the meantime.
    @Published private(set) var finishedMode: FocusMode?

    private var completionTask: Task<Void, Never>?
    private var finishedClearTask: Task<Void, Never>?

    /// Whether the closed notch should show the timer, like a Live Activity.
    var showsLiveActivity: Bool {
        isRunning || pausedRemaining != nil || finishedMode != nil
    }

    var isRunning: Bool { endDate != nil }
    var customMinutes: Int { Defaults[.focusCustomMinutes] }

    func remaining(at now: Date) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return pausedRemaining ?? total
    }

    func select(_ newMode: FocusMode) {
        cancel()
        mode = newMode
        total = duration(for: newMode)
        pausedRemaining = nil
    }

    func toggle() {
        clearFinished()
        if let endDate {
            pausedRemaining = max(0, endDate.timeIntervalSinceNow)
            self.endDate = nil
            completionTask?.cancel()
        } else {
            let end = Date().addingTimeInterval(pausedRemaining ?? total)
            endDate = end
            pausedRemaining = nil
            schedule(end)
        }
    }

    func reset() {
        cancel()
        pausedRemaining = nil
        clearFinished()
    }

    private func clearFinished() {
        finishedClearTask?.cancel()
        finishedMode = nil
    }

    func adjustCustom(by minutes: Int) {
        Defaults[.focusCustomMinutes] = min(max(customMinutes + minutes, 5), 120)
        if mode == .custom, !isRunning {
            total = duration(for: .custom)
            pausedRemaining = nil
        }
        objectWillChange.send()
    }

    private func duration(for mode: FocusMode) -> TimeInterval {
        switch mode {
        case .focus: return 25 * 60
        case .shortBreak: return 5 * 60
        case .custom: return TimeInterval(customMinutes * 60)
        }
    }

    private func cancel() {
        completionTask?.cancel()
        completionTask = nil
        endDate = nil
    }

    private func schedule(_ end: Date) {
        completionTask?.cancel()
        completionTask = Task { @MainActor [weak self] in
            let delay = max(0, end.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.endDate == end else { return }
            self.finish()
        }
    }

    private func finish() {
        NSSound(named: "Glass")?.play()
        let finished = mode
        cancel()
        pausedRemaining = nil
        finishedMode = finished
        finishedClearTask?.cancel()
        finishedClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.finishedMode = nil
        }
        // Pomodoro rhythm: work → break → work. The next one waits for a tap.
        switch finished {
        case .focus: select(.shortBreak)
        case .shortBreak: select(.focus)
        case .custom: total = duration(for: .custom)
        }
    }
}

private struct TimerPage: View {
    @ObservedObject private var timer = FocusTimer.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TimerPageContent(
                mode: timer.mode,
                remaining: timer.remaining(at: context.date),
                total: timer.total,
                isRunning: timer.isRunning,
                customMinutes: timer.customMinutes,
                onToggle: { timer.toggle() },
                onReset: { timer.reset() },
                onSelect: { timer.select($0) },
                onAdjustCustom: { timer.adjustCustom(by: $0) }
            )
        }
    }
}

// MARK: - Clipboard

private struct ClipboardPage: View {
    @ObservedObject private var history = ClipboardHistory.shared
    @Default(.clipboardHistory) private var enabled

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ClipboardPageContent(
                entries: history.entries,
                enabled: enabled,
                now: context.date,
                onCopy: { history.copy($0) },
                onClear: { history.clear() }
            )
        }
    }
}

// MARK: - System

/// Samples CPU, memory and network only while this page is the one shown.
private struct SystemPage: View {
    @ObservedObject private var monitor = SystemStatsMonitor.shared
    @ObservedObject private var model = NotchPageModel.shared

    var body: some View {
        SystemPageContent(stats: monitor.stats)
            .onAppear { sync() }
            .onChange(of: model.index) { sync() }
            .onDisappear { monitor.stop() }
    }

    private func sync() {
        if model.page == .system { monitor.start() } else { monitor.stop() }
    }
}

// MARK: - App shortcuts

enum ShortcutApps {
    static let defaults = ["com.apple.Safari", "com.apple.MobileSMS", "com.apple.Notes", "com.apple.finder"]

    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(for bundleID: String) -> String {
        guard let url = url(for: bundleID) else { return "—" }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    static func icon(for bundleID: String) -> NSImage? {
        guard let url = url(for: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func open(_ bundleID: String) {
        guard let url = url(for: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

private struct ShortcutsPage: View {
    @Default(.shortcutApps) private var bundleIDs

    var body: some View {
        ShortcutsPageContent(
            apps: bundleIDs.prefix(4).enumerated().map { index, id in
                ShortcutAppItem(id: index, name: ShortcutApps.name(for: id), icon: ShortcutApps.icon(for: id))
            },
            onOpen: { index in
                guard index < bundleIDs.count else { return }
                ShortcutApps.open(bundleIDs[index])
            }
        )
    }
}
