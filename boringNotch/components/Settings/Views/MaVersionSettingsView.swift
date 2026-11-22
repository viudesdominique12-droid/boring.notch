//
//  MaVersionSettingsView.swift
//  boringNotch — ma-version
//
//  Settings for the features added in this fork: weather, small music
//  player and the Liquid Glass look.
//

import Defaults
import SwiftUI

struct MaVersionSettingsView: View {
    @Default(.weatherCity) private var weatherCity
    @Default(.liquidGlassNotch) private var liquidGlassNotch
    @Default(.liquidGlassTint) private var liquidGlassTint
    @ObservedObject private var weather = WeatherManager.shared
    @State private var cityDraft: String = ""

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showWeather) {
                    Text("Afficher la météo dans l'encoche")
                }
                HStack {
                    TextField("Ville", text: $cityDraft, prompt: Text("ex. Strasbourg"))
                        .onSubmit(saveCity)
                    Button("Valider", action: saveCity)
                        .disabled(cityDraft.trimmingCharacters(in: .whitespaces) == weatherCity)
                }
                statusRow
            } header: {
                Text("Météo")
            } footer: {
                Text("Données : Open-Meteo, gratuit et sans compte. Seul le nom de la ville est envoyé.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .smallMediaPlayer) {
                    Text("Petit lecteur de musique")
                }
            } header: {
                Text("Musique")
            } footer: {
                Text("Pochette plus petite et seulement 3 boutons (précédent, lecture, suivant).")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Effet Liquid Glass quand l'encoche est ouverte", isOn: $liquidGlassNotch)
                if liquidGlassNotch {
                    HStack {
                        Text("Assombrissement")
                        Slider(value: $liquidGlassTint, in: 0...0.8)
                        Text("\(Int(liquidGlassTint * 100)) %")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                if #unavailable(macOS 26.0) {
                    Text("Nécessite macOS 26 ou plus récent.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Apparence")
            } footer: {
                Text("Plus d'assombrissement = texte plus lisible sur un fond d'écran clair.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { cityDraft = weatherCity }
        .accentColor(.effectiveAccent)
        .navigationTitle("Ma version")
    }

    private func saveCity() {
        weatherCity = cityDraft.trimmingCharacters(in: .whitespacesAndNewlines)
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
                if let temp = weather.temperature {
                    Text("\(Int(temp.rounded()))°").monospacedDigit()
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
