//
//  WeatherView.swift
//  boringNotch — ma-version
//
//  Weather card shown in the open notch next to the (small) music player.
//  Adapts to the width it gets: narrow = current weather only,
//  wide = current weather + the next 4 hours.
//

import Defaults
import SwiftUI

struct WeatherView: View {
    @ObservedObject private var weather = WeatherManager.shared

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 250
            content(wide: wide)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if weather.status == .needsCity || weather.status == .cityNotFound {
                SettingsWindowController.shared.showWindow()
            } else {
                weather.refresh()
            }
        }
        .onAppear { weather.refreshIfNeeded() }
    }

    @ViewBuilder
    private func content(wide: Bool) -> some View {
        switch weather.status {
        case .needsCity:
            message(icon: "location.magnifyingglass",
                    title: "Ajoute ta ville",
                    subtitle: "Clique ici → Réglages, onglet « Ma version »")
        case .cityNotFound:
            message(icon: "questionmark.circle",
                    title: "Ville introuvable",
                    subtitle: "Vérifie l'orthographe dans Réglages")
        case .failed:
            message(icon: "wifi.exclamationmark",
                    title: "Météo indisponible",
                    subtitle: "Clique pour réessayer")
        case .idle, .loading:
            if weather.temperature == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Météo…").font(.system(size: 12)).foregroundStyle(.gray)
                }
            } else {
                loaded(wide: wide)
            }
        case .loaded:
            loaded(wide: wide)
        }
    }

    private func loaded(wide: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            current
            if wide && !weather.hourly.isEmpty {
                Spacer(minLength: 0)
                hourlyRow
            }
        }
    }

    private var current: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: "location.fill").font(.system(size: 8))
                Text(weather.cityName).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.6))

            HStack(alignment: .center, spacing: 6) {
                Image(systemName: WeatherCondition.symbol(for: weather.weatherCode, isDay: weather.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 26))
                    .frame(width: 32)
                Text(formatted(weather.temperature))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }

            Text(WeatherCondition.label(for: weather.weatherCode))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)

            if let low = weather.low, let high = weather.high {
                Text("↓ \(formatted(low))  ↑ \(formatted(high))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hourlyRow: some View {
        HStack(spacing: 12) {
            ForEach(weather.hourly) { hour in
                VStack(spacing: 5) {
                    Text(hourLabel(hour.date))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Image(systemName: WeatherCondition.symbol(for: hour.code, isDay: hour.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 16))
                        .frame(height: 20)
                    Text(formatted(hour.temperature))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func message(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
            }
        }
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "--°" }
        return "\(Int(value.rounded()))°"
    }

    private func hourLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = weather.timeZone
        formatter.dateFormat = "H'h'"
        return formatter.string(from: date)
    }
}
