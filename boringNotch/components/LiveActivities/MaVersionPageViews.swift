//
//  MaVersionPageViews.swift
//  boringNotch — ma-version
//
//  Pure SwiftUI views for layout B (mini notch + swipeable pages) and the
//  closed-notch status. Everything here is fed by plain values — no
//  Defaults, no singletons — so the views can be rendered offscreen for
//  layout checks. The wiring lives in MaVersionPages.swift.
//

import AppKit
import SwiftUI

// MARK: - Shared metrics

enum MaVersionMetrics {
    /// Content width of the open mini notch (same as upstream compact mode).
    static let pageWidth: CGFloat = 336
    /// Every page gets the same height so the panel never jumps while swiping.
    static let pageHeight: CGFloat = 136
}

// MARK: - Weather values

struct WeatherHour: Identifiable, Equatable {
    let date: Date
    let temperature: Double
    let code: Int
    let isDay: Bool
    var id: Date { date }
}

enum RainOutlook: Equatable {
    case unknown
    /// No rain expected in the next two hours.
    case dry
    /// Rain expected to start at this time.
    case startsAt(Date)
    /// Raining now; stops at this time if known within two hours.
    case rainingUntil(Date?)
}

struct WeatherSnapshot: Equatable {
    var city: String
    var temperature: Double?
    var code: Int
    var isDay: Bool
    var low: Double?
    var high: Double?
    var hours: [WeatherHour]
    var rain: RainOutlook
    var timeZone: TimeZone
}

enum WeatherPageState: Equatable {
    case needsCity
    case loading
    case cityNotFound
    case failed
    case loaded(WeatherSnapshot)
}

// MARK: - WMO weather codes → SF Symbol + French label

enum WeatherCondition {
    static func symbol(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: return isDay ? "sun.max.fill" : "moon.fill"
        case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63: return "cloud.rain.fill"
        case 65: return "cloud.heavyrain.fill"
        case 71, 73, 75, 85, 86: return "cloud.snow.fill"
        case 77: return "snowflake"
        case 80, 81: return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 82: return "cloud.heavyrain.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func label(for code: Int) -> String {
        switch code {
        case 0: return "Ciel dégagé"
        case 1: return "Plutôt dégagé"
        case 2: return "Partiellement nuageux"
        case 3: return "Couvert"
        case 45, 48: return "Brouillard"
        case 51, 53, 55: return "Bruine"
        case 56, 57: return "Bruine verglaçante"
        case 61: return "Pluie légère"
        case 63: return "Pluie"
        case 65: return "Forte pluie"
        case 66, 67: return "Pluie verglaçante"
        case 71: return "Neige légère"
        case 73: return "Neige"
        case 75: return "Forte neige"
        case 77: return "Grains de neige"
        case 80, 81: return "Averses"
        case 82: return "Fortes averses"
        case 85, 86: return "Averses de neige"
        case 95: return "Orage"
        case 96, 99: return "Orage et grêle"
        default: return "—"
        }
    }

    enum Motion { case shine, drift, fall, flash, none }

    static func motion(for code: Int) -> Motion {
        switch code {
        case 0, 1: return .shine
        case 2, 3, 45, 48: return .drift
        case 51...67, 71...86: return .fall
        case 95, 96, 99: return .flash
        default: return .none
        }
    }

    static func temperatureText(_ value: Double?) -> String {
        guard let value else { return "--°" }
        let rounded = Int(value.rounded())
        return "\(rounded == 0 ? 0 : rounded)°"
    }
}

// MARK: - Animated weather symbol

struct AnimatedWeatherSymbol: View {
    let code: Int
    let isDay: Bool
    var size: CGFloat = 30
    var animated: Bool = true

    var body: some View {
        let image = Image(systemName: WeatherCondition.symbol(for: code, isDay: isDay))
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size))
        if animated {
            switch WeatherCondition.motion(for: code) {
            case .shine:
                if #available(macOS 15.0, *) {
                    image.symbolEffect(.breathe.pulse, options: .repeat(.continuous))
                } else {
                    image.symbolEffect(.pulse, options: .repeating)
                }
            case .drift:
                if #available(macOS 15.0, *) {
                    image.symbolEffect(.wiggle.left, options: .repeat(.periodic(delay: 2.5)))
                } else {
                    image
                }
            case .fall:
                image.symbolEffect(.variableColor.iterative, options: .repeating)
            case .flash:
                image.symbolEffect(.pulse, options: .repeating)
            case .none:
                image
            }
        } else {
            image
        }
    }
}

// MARK: - Weather page

struct WeatherPageContent: View {
    let state: WeatherPageState
    var now: Date = Date()
    var animated: Bool = true

    var body: some View {
        Group {
            switch state {
            case .loaded(let snapshot):
                loaded(snapshot)
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Météo…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsCity:
                PageMessage(icon: "location.magnifyingglass", title: "Ajoute ta ville",
                            subtitle: "Réglages → Ma version")
            case .cityNotFound:
                PageMessage(icon: "questionmark.circle", title: "Ville introuvable",
                            subtitle: "Vérifie l'orthographe dans Réglages")
            case .failed:
                PageMessage(icon: "wifi.exclamationmark", title: "Météo indisponible",
                            subtitle: "Clique pour réessayer")
            }
        }
        .frame(width: MaVersionMetrics.pageWidth, height: MaVersionMetrics.pageHeight, alignment: .top)
    }

    private func loaded(_ s: WeatherSnapshot) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                AnimatedWeatherSymbol(code: s.code, isDay: s.isDay, size: 30, animated: animated)
                    .frame(width: 38, height: 38)
                Text(WeatherCondition.temperatureText(s.temperature))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 2) {
                    Text(WeatherCondition.label(for: s.code))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let low = s.low, let high = s.high {
                        Text("↓ \(WeatherCondition.temperatureText(low))   ↑ \(WeatherCondition.temperatureText(high))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 40)

            HStack(spacing: 0) {
                ForEach(s.hours) { hour in
                    VStack(spacing: 3) {
                        Text(Self.hourLabel(hour.date, in: s.timeZone))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                        Image(systemName: WeatherCondition.symbol(for: hour.code, isDay: hour.isDay))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 14))
                            .frame(height: 18)
                        Text(WeatherCondition.temperatureText(hour.temperature))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 46)

            rainRow(s.rain, timeZone: s.timeZone)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func rainRow(_ rain: RainOutlook, timeZone: TimeZone) -> some View {
        let (icon, text, highlight) = Self.rainText(rain, now: now, timeZone: timeZone)
        if !text.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(text).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(highlight ? Color(red: 0.55, green: 0.78, blue: 1.0) : .white.opacity(0.55))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(highlight ? 0.12 : 0.06)))
        }
    }

    static func rainText(_ rain: RainOutlook, now: Date, timeZone: TimeZone) -> (String, String, Bool) {
        switch rain {
        case .unknown:
            return ("", "", false)
        case .dry:
            return ("sun.max", "Pas de pluie dans les 2 h", false)
        case .startsAt(let date):
            let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
            if minutes <= 5 { return ("umbrella.fill", "Pluie imminente", true) }
            return ("umbrella.fill", "Pluie dans \(minutes) min", true)
        case .rainingUntil(let end):
            if let end {
                return ("umbrella.fill", "Il pleut · fin vers \(clockLabel(end, in: timeZone))", true)
            }
            return ("umbrella.fill", "Il pleut pour au moins 2 h", true)
        }
    }

    static func hourLabel(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = "H'h'"
        return f.string(from: date)
    }

    static func clockLabel(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = "H'h'mm"
        return f.string(from: date)
    }
}

// MARK: - Agenda page

struct AgendaItem: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
}

enum AgendaPageState: Equatable {
    case noAccess
    case loaded([AgendaItem])
}

struct AgendaPageContent: View {
    let state: AgendaPageState
    var now: Date = Date()

    var body: some View {
        Group {
            switch state {
            case .noAccess:
                PageMessage(icon: "calendar.badge.exclamationmark", title: "Accès au calendrier",
                            subtitle: "Autorise Boring Notch dans Réglages Système → Confidentialité")
            case .loaded(let items) where items.isEmpty:
                PageMessage(icon: "calendar.badge.checkmark", title: "Rien de prévu",
                            subtitle: "Plus aucun événement aujourd'hui")
            case .loaded(let items):
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items.prefix(3)) { item in
                        row(item)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
        }
        .frame(width: MaVersionMetrics.pageWidth, height: MaVersionMetrics.pageHeight, alignment: .top)
    }

    private func row(_ item: AgendaItem) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.color)
                .frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(timeRange(item))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 6)
            Text(relative(item))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOngoing(item) ? Color(red: 0.45, green: 0.85, blue: 0.55) : .white.opacity(0.75))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.08)))
        }
        .frame(height: 34)
    }

    private func isOngoing(_ item: AgendaItem) -> Bool {
        item.start <= now && item.end > now
    }

    private func timeRange(_ item: AgendaItem) -> String {
        if item.isAllDay { return "Toute la journée" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: item.start)) – \(f.string(from: item.end))"
    }

    private func relative(_ item: AgendaItem) -> String {
        if item.isAllDay { return "Aujourd'hui" }
        if isOngoing(item) { return "En cours" }
        let minutes = Int(item.start.timeIntervalSince(now) / 60)
        if minutes < 1 { return "Maintenant" }
        if minutes < 60 { return "dans \(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "dans \(hours) h" : "dans \(hours) h \(rest)"
    }
}

// MARK: - Timer / Pomodoro page

enum FocusMode: String, CaseIterable, Identifiable {
    case focus
    case shortBreak
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .focus: return "Travail"
        case .shortBreak: return "Pause"
        case .custom: return "Minuteur"
        }
    }

    var tint: Color {
        switch self {
        case .focus: return Color(red: 1.0, green: 0.45, blue: 0.4)
        case .shortBreak: return Color(red: 0.4, green: 0.85, blue: 0.6)
        case .custom: return Color(red: 0.5, green: 0.7, blue: 1.0)
        }
    }
}

struct TimerPageContent: View {
    let mode: FocusMode
    let remaining: TimeInterval
    let total: TimeInterval
    let isRunning: Bool
    let customMinutes: Int
    var onToggle: () -> Void = {}
    var onReset: () -> Void = {}
    var onSelect: (FocusMode) -> Void = { _ in }
    var onAdjustCustom: (Int) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 18) {
            ring
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(FocusMode.allCases) { m in
                        Button { onSelect(m) } label: {
                            Text(chipLabel(m))
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundStyle(m == mode ? .black : .white.opacity(0.8))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(m == mode ? m.tint : .white.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 10) {
                    circleButton(isRunning ? "pause.fill" : "play.fill", prominent: true, action: onToggle)
                    circleButton("arrow.counterclockwise", prominent: false, action: onReset)
                    if mode == .custom && !isRunning {
                        circleButton("minus", prominent: false) { onAdjustCustom(-5) }
                        circleButton("plus", prominent: false) { onAdjustCustom(5) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: MaVersionMetrics.pageWidth, height: MaVersionMetrics.pageHeight)
    }

    private func chipLabel(_ m: FocusMode) -> String {
        switch m {
        case .focus: return "Travail"
        case .shortBreak: return "Pause"
        case .custom: return "Libre"
        }
    }

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(1 - remaining / total, 0), 1)
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(mode.tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(Self.clock(remaining))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(isRunning || remaining < total ? mode.label : "\(Int(total / 60)) min")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: 96, height: 96)
    }

    private func circleButton(_ icon: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: prominent ? 14 : 12, weight: .bold))
                .foregroundStyle(prominent ? .black : .white)
                .frame(width: prominent ? 38 : 30, height: prominent ? 38 : 30)
                .background(Circle().fill(prominent ? mode.tint : .white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Shortcuts page

struct ShortcutAppItem: Identifiable {
    let id: Int
    let name: String
    let icon: NSImage?
}

struct ShortcutsPageContent: View {
    let apps: [ShortcutAppItem]
    var onOpen: (Int) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 14) {
            ForEach(apps) { app in
                Button { onOpen(app.id) } label: {
                    VStack(spacing: 6) {
                        Group {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().interpolation(.high)
                            } else {
                                Image(systemName: "questionmark.app.dashed")
                                    .resizable().scaledToFit()
                                    .foregroundStyle(.white.opacity(0.4))
                                    .padding(10)
                            }
                        }
                        .frame(width: 48, height: 48)
                        Text(app.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    .frame(width: 66, height: 82)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(ShortcutPressStyle())
            }
        }
        .frame(width: MaVersionMetrics.pageWidth, height: MaVersionMetrics.pageHeight)
    }
}

private struct ShortcutPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Shared bits

struct PageMessage: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// iPhone-style page indicator: the current page is a short pill.
struct PageDots: View {
    let count: Int
    let index: Int
    var onSelect: (Int) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(i == index ? 0.9 : 0.3))
                    .frame(width: i == index ? 14 : 6, height: 6)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture { onSelect(i) }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: index)
        .frame(height: 10)
    }
}

/// Top strip of the open mini notch: page title on the left of the camera,
/// temperature + battery on the right.
struct PagedTopBarContent: View {
    let title: String
    let symbol: String
    let temperature: String?
    let weatherCode: Int
    let isDay: Bool
    let batteryLevel: Int?
    let isCharging: Bool
    let notchGap: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.opacity)

            Color.clear.frame(width: notchGap)

            HStack(spacing: 7) {
                if let temperature {
                    HStack(spacing: 3) {
                        Image(systemName: WeatherCondition.symbol(for: weatherCode, isDay: isDay))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 11))
                        Text(temperature).font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .fixedSize()
                }
                if let batteryLevel {
                    BatteryGlyph(level: batteryLevel, isCharging: isCharging, showsPercent: false)
                        .fixedSize()
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 8)
    }
}

struct BatteryGlyph: View {
    let level: Int
    let isCharging: Bool
    var showsPercent: Bool = true

    var body: some View {
        HStack(spacing: 3) {
            if showsPercent {
                Text("\(level)%").font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize()
            }
            Image(systemName: symbolName)
                .font(.system(size: 13))
                .foregroundStyle(level <= 20 && !isCharging ? Color.red : (isCharging ? Color.green : Color.white))
        }
    }

    private var symbolName: String {
        if isCharging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Closed notch: temperature on the left of the camera, battery on the right.
struct ClosedStatusContent: View {
    let temperature: String?
    let weatherCode: Int
    let isDay: Bool
    let batteryLevel: Int
    let isCharging: Bool
    let notchWidth: CGFloat
    let height: CGFloat

    static let sideWidth: CGFloat = 50

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                if let temperature {
                    Image(systemName: WeatherCondition.symbol(for: weatherCode, isDay: isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 11))
                    Text(temperature)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: Self.sideWidth, alignment: .leading)

            Rectangle().fill(.black).frame(width: notchWidth)

            BatteryGlyph(level: batteryLevel, isCharging: isCharging, showsPercent: true)
                .foregroundStyle(.white)
                .frame(width: Self.sideWidth, alignment: .trailing)
        }
        .frame(height: height, alignment: .center)
    }
}

// MARK: - Horizontal two-finger swipe

/// Reports horizontal trackpad scrolls on this view's window as a running
/// finger offset, then the final offset and last velocity when the fingers
/// lift. Once a swipe is recognised as horizontal its events are consumed,
/// so no other notch gesture (open/close, media skip) reacts to it, and its
/// momentum is swallowed so one swipe = one page.
/// Approach inspired by Sapphire's NotchSwipeRow (latch + consume); code is
/// our own.
struct HorizontalSwipeMonitor: NSViewRepresentable {
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ offset: CGFloat, _ velocity: CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    @MainActor final class Coordinator: NSObject {
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void
        private var monitor: Any?
        private var active = false
        private var offset: CGFloat = 0
        private var velocity: CGFloat = 0
        private var sumX: CGFloat = 0
        private var sumY: CGFloat = 0
        private var swallowingMomentum = false
        private var endTask: Task<Void, Never>?

        init(onChanged: @escaping (CGFloat) -> Void, onEnded: @escaping (CGFloat, CGFloat) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func install(on view: NSView) {
            remove()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self, weak view] event in
                guard let self, let view, event.window === view.window else { return event }
                return self.handle(event)
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            endTask?.cancel()
            reset()
        }

        private func reset() {
            active = false
            offset = 0
            velocity = 0
            sumX = 0
            sumY = 0
        }

        private func finish() {
            endTask?.cancel()
            if active {
                NSLog("[MaVersionSwipe] end offset=%.1f velocity=%.1f", offset, velocity)
                onEnded(offset, velocity)
            }
            reset()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            // Momentum after the fingers lift: swallow it if the swipe was ours.
            if event.momentumPhase != [] {
                guard swallowingMomentum else { return event }
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    swallowingMomentum = false
                }
                return nil
            }

            if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
                reset()
                swallowingMomentum = false
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                let wasOurs = active
                finish()
                if wasOurs { swallowingMomentum = true }
                return wasOurs ? nil : event
            }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            if !active {
                // Don't decide on the first jittery event: wait for a few
                // points of travel, and a vertical start doesn't lock us out.
                sumX += abs(dx)
                sumY += abs(dy)
                guard sumX >= 4, sumX > sumY * 1.2 else { return event }
                active = true
            }

            // Content follows the fingers. Sign checked on the user's Mac.
            let fingerDX = dx * (event.isDirectionInvertedFromDevice ? -1 : 1)
                * (event.hasPreciseScrollingDeltas ? 1 : 10)
            offset += fingerDX
            velocity = fingerDX
            onChanged(offset)

            // Mice send no phases: end after a short pause.
            if event.phase == [] {
                endTask?.cancel()
                endTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled else { return }
                    self?.finish()
                }
            }
            return nil
        }
    }
}

/// Pages laid side by side; drag follows the fingers with rubber-banding at
/// the ends, release springs to the nearest page (one page per swipe).
struct SwipePager<Page: View>: View {
    let count: Int
    @Binding var index: Int
    @ViewBuilder let page: (Int) -> Page

    @State private var drag: CGFloat = 0
    private let width = MaVersionMetrics.pageWidth

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    page(i)
                        .frame(width: width, height: MaVersionMetrics.pageHeight)
                        .allowsHitTesting(i == index)
                }
            }
            .offset(x: -CGFloat(index) * width + drag)
            .frame(width: width, height: MaVersionMetrics.pageHeight, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .background(
                HorizontalSwipeMonitor(
                    onChanged: { offset in
                        drag = rubberBand(offset)
                    },
                    onEnded: { offset, velocity in
                        // Far enough, or a short quick flick, turns one page.
                        let goNext = offset < -40 || (offset < -12 && velocity < -3)
                        let goBack = offset > 40 || (offset > 12 && velocity > 3)
                        var target = index
                        if goNext { target = min(index + 1, count - 1) }
                        if goBack { target = max(index - 1, 0) }
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                            index = target
                            drag = 0
                        }
                    }
                )
            )

            PageDots(count: count, index: index) { i in
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { index = i }
            }
        }
    }

    private func rubberBand(_ offset: CGFloat) -> CGFloat {
        let atStart = index == 0 && offset > 0
        let atEnd = index == count - 1 && offset < 0
        guard atStart || atEnd else { return max(-width, min(width, offset)) }
        // Resist past the first / last page, like iOS.
        let limit: CGFloat = 60
        return limit * (1 - exp(-abs(offset) / limit)) * (offset < 0 ? -1 : 1)
    }
}
