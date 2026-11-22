//
//  MaVersionSettingsView.swift
//  boringNotch — ma-version
//
//  Settings for the features added in this fork.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct MaVersionSettingsView: View {
    @Default(.weatherCity) private var weatherCity
    @Default(.shortcutApps) private var shortcutApps
    @Default(.focusCustomMinutes) private var focusCustomMinutes
    @Default(.liquidGlassNotch) private var liquidGlassNotch
    @Default(.liquidGlassTint) private var liquidGlassTint
    @ObservedObject private var weather = WeatherManager.shared
    @State private var cityDraft: String = ""

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .pagedLayout) {
                    Text("Mini encoche avec pages à faire glisser")
                }
                Defaults.Toggle(key: .rememberLastPage) {
                    Text("Rouvrir sur la dernière page")
                }
                Defaults.Toggle(key: .closedNotchStatus) {
                    Text("Encoche fermée : degrés à gauche, batterie à droite")
                }
            } header: {
                Text("Agencement")
            } footer: {
                Text("Glisse à deux doigts sur l'encoche ouverte : Musique → Météo → Agenda → Minuteur → Fichiers → Copies → Apps. Tu peux aussi cliquer sur les petits points.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .bouncyOpen) { Text("Ouverture avec rebond") }
                Defaults.Toggle(key: .iphoneChargingAnimation) { Text("Animation de charge façon iPhone") }
                Defaults.Toggle(key: .albumGlow) { Text("Lueur de la pochette dans le verre") }
                Defaults.Toggle(key: .pageDepthEffect) { Text("Effet de profondeur entre les pages") }
                Defaults.Toggle(key: .pageHaptics) { Text("Petit clic au trackpad à chaque page") }
            } header: {
                Text("Animations")
            }

            Section {
                Defaults.Toggle(key: .upcomingEventAlert) { Text("Rendez-vous dans moins de 10 min") }
                Defaults.Toggle(key: .rainAlert) { Text("Pluie qui arrive (dans 20 min ou moins)") }
                Defaults.Toggle(key: .deviceAlert) { Text("Écouteurs Bluetooth connectés, avec batterie") }
            } header: {
                Text("Alertes dans l'encoche fermée")
            }

            Section {
                Defaults.Toggle(key: .clipboardHistory) { Text("Garder l'historique des textes copiés") }
            } header: {
                Text("Page Copies")
            } footer: {
                Text("Les 10 derniers textes copiés, gardés en mémoire seulement : rien n'est enregistré sur le disque, et les mots de passe copiés depuis un gestionnaire sont ignorés.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("Ville", text: $cityDraft, prompt: Text("Strasbourg"))
                        .onSubmit(saveCity)
                    Button("Valider", action: saveCity)
                }
                statusRow
            } header: {
                Text("Météo")
            } footer: {
                Text("Données : Open-Meteo, gratuit et sans compte. Seul le nom de la ville est envoyé.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(0..<4, id: \.self) { slot in
                    HStack(spacing: 10) {
                        if let id = bundleID(at: slot), let icon = ShortcutApps.icon(for: id) {
                            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 22, height: 22)
                        }
                        Text(bundleID(at: slot).map(ShortcutApps.name(for:)) ?? "Vide")
                        Spacer()
                        Button("Changer…") { pickApp(for: slot) }
                    }
                }
            } header: {
                Text("Page Apps")
            }

            Section {
                Stepper(value: $focusCustomMinutes, in: 5...120, step: 5) {
                    Text("Minuteur libre : \(focusCustomMinutes) min")
                }
            } header: {
                Text("Minuteur")
            } footer: {
                Text("Travail = 25 min, Pause = 5 min. Un son « Glass » sonne à la fin.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Verre Liquid Glass d'Apple (encoche ouverte)", isOn: $liquidGlassNotch)
                if liquidGlassNotch {
                    HStack {
                        Text("Assombrissement")
                        Slider(value: $liquidGlassTint, in: 0...0.8)
                        Text("\(Int(liquidGlassTint * 100)) %")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("Apparence")
            }
        }
        .onAppear { cityDraft = weatherCity }
        .accentColor(.effectiveAccent)
        .navigationTitle("Ma version")
    }

    private func bundleID(at slot: Int) -> String? {
        slot < shortcutApps.count ? shortcutApps[slot] : nil
    }

    private func saveCity() {
        weatherCity = cityDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        weather.refresh()
    }

    private func pickApp(for slot: Int) {
        let panel = NSOpenPanel()
        panel.title = "Choisis une app"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier
        else { return }
        var apps = shortcutApps
        while apps.count < 4 { apps.append("") }
        apps[slot] = id
        shortcutApps = apps
    }

    @ViewBuilder
    private var statusRow: some View {
        switch weather.status {
        case .loaded:
            HStack(spacing: 6) {
                Image(systemName: WeatherCondition.symbol(for: weather.weatherCode, isDay: weather.isDay))
                    .symbolRenderingMode(.multicolor)
                Text(weather.cityDetail.isEmpty ? weather.cityName : "\(weather.cityName), \(weather.cityDetail)")
                Spacer()
                if let temp = weather.shortTemperature {
                    Text(temp).monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Recherche…").foregroundStyle(.secondary)
            }
        case .cityNotFound:
            Label("Ville introuvable, vérifie l'orthographe.", systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
        case .failed:
            Label("Impossible de joindre le service météo.", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        case .needsCity, .idle:
            Text("Tape le nom de ta ville puis « Valider ».")
                .foregroundStyle(.secondary)
        }
    }
}
