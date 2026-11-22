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
    case shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return "Musique"
        case .weather: return "Météo"
        case .agenda: return "Agenda"
        case .timer: return "Minuteur"
        case .shortcuts: return "Apps"
        }
    }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .weather: return "location.fill"
        case .agenda: return "calendar"
        case .timer: return "timer"
        case .shortcuts: return "square.grid.2x2.fill"
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
    @ObservedObject private var model = NotchPageModel.shared

    var body: some View {
        SwipePager(count: NotchPage.allCases.count, index: $model.index) { i in
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
            case .shortcuts:
                ShortcutsPage()
            }
        }
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

    private var title: String {
        if model.page == .weather, !weather.cityName.isEmpty { return weather.cityName }
        return model.page.title
    }
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
        .onTapGesture { openCalendarApp() }
        .task {
            await calendar.checkCalendarAuthorization()
            await calendar.updateCurrentDate(Date())
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

    private var completionTask: Task<Void, Never>?

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
