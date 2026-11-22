//
//  WeatherManager.swift
//  boringNotch — ma-version
//
//  Fetches current weather + the next few hours from Open-Meteo
//  (https://open-meteo.com — free, no account, no API key). Only the city
//  name the user typed in Settings → Ma version is sent: no location
//  permission, no tracking.
//

import Combine
import Defaults
import Foundation

@MainActor
final class WeatherManager: ObservableObject {
    static let shared = WeatherManager()

    enum Status: Equatable {
        case idle
        case needsCity
        case loading
        case loaded
        case cityNotFound
        case failed
    }

    struct HourForecast: Identifiable, Equatable {
        let date: Date
        let temperature: Double
        let code: Int
        let isDay: Bool
        var id: Date { date }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var cityName: String = ""
    @Published private(set) var cityDetail: String = ""
    @Published private(set) var temperature: Double?
    @Published private(set) var weatherCode: Int = 0
    @Published private(set) var isDay: Bool = true
    @Published private(set) var high: Double?
    @Published private(set) var low: Double?
    @Published private(set) var hourly: [HourForecast] = []
    @Published private(set) var timeZone: TimeZone = .current

    private var lastFetch: Date?
    private var fetchTask: Task<Void, Never>?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Geocoding result cache, so a refresh doesn't look the city up again.
    private var resolvedQuery: String?
    private var resolvedCoordinates: (lat: Double, lon: Double)?

    private init() {
        Defaults.publisher(.weatherCity)
            .map(\.newValue)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Called when the notch opens: refetch only if the data is older than 10 min.
    func refreshIfNeeded() {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 10 * 60, status == .loaded {
            return
        }
        refresh()
    }

    func refresh() {
        let query = Defaults[.weatherCity].trimmingCharacters(in: .whitespacesAndNewlines)
        guard Defaults[.showWeather] else { return }
        guard !query.isEmpty else {
            fetchTask?.cancel()
            status = .needsCity
            return
        }

        fetchTask?.cancel()
        if status != .loaded || resolvedQuery != query {
            status = .loading
        }
        fetchTask = Task { [weak self] in
            await self?.load(query: query)
        }
    }

    // MARK: - Networking

    private func load(query: String) async {
        do {
            let coordinates: (lat: Double, lon: Double)
            if resolvedQuery == query, let cached = resolvedCoordinates {
                coordinates = cached
            } else {
                guard let place = try await geocode(query) else {
                    if !Task.isCancelled { status = .cityNotFound }
                    return
                }
                coordinates = (place.latitude, place.longitude)
                resolvedQuery = query
                resolvedCoordinates = coordinates
                cityName = place.name
                cityDetail = [place.admin1, place.country]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty && $0 != place.name }
                    .joined(separator: ", ")
            }

            let forecast = try await fetchForecast(lat: coordinates.lat, lon: coordinates.lon)
            guard !Task.isCancelled else { return }
            apply(forecast)
            lastFetch = Date()
            status = .loaded
        } catch is CancellationError {
            return
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            NSLog("[WeatherManager] fetch failed: %@", error.localizedDescription)
            // Keep showing the last good data if we have some.
            if temperature == nil { status = .failed }
        }
    }

    private func geocode(_ query: String) async throws -> GeocodingResponse.Place? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "fr"),
            URLQueryItem(name: "format", value: "json")
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(GeocodingResponse.self, from: data).results?.first
    }

    private func fetchForecast(lat: Double, lon: Double) async throws -> ForecastResponse {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(ForecastResponse.self, from: data)
    }

    private func apply(_ forecast: ForecastResponse) {
        let zone = TimeZone(secondsFromGMT: forecast.utcOffsetSeconds) ?? .current
        timeZone = zone

        temperature = forecast.current.temperature
        weatherCode = forecast.current.weatherCode
        isDay = forecast.current.isDay == 1
        high = forecast.daily.max.first ?? nil
        low = forecast.daily.min.first ?? nil

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = zone
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm"

        let now = Date()
        var hours: [HourForecast] = []
        let h = forecast.hourly
        for index in h.time.indices {
            guard let date = parser.date(from: h.time[index]), date > now,
                  index < h.temperature.count, index < h.weatherCode.count,
                  let temp = h.temperature[index], let code = h.weatherCode[index]
            else { continue }
            let day = index < h.isDay.count ? (h.isDay[index] ?? 1) : 1
            hours.append(HourForecast(date: date, temperature: temp, code: code, isDay: day == 1))
            if hours.count == 4 { break }
        }
        hourly = hours
    }
}

// MARK: - Open-Meteo responses

private struct GeocodingResponse: Decodable {
    struct Place: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
        let admin1: String?
    }

    let results: [Place]?
}

private struct ForecastResponse: Decodable {
    struct Current: Decodable {
        let temperature: Double
        let weatherCode: Int
        let isDay: Int

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }
    }

    struct Hourly: Decodable {
        let time: [String]
        let temperature: [Double?]
        let weatherCode: [Int?]
        let isDay: [Int?]

        enum CodingKeys: String, CodingKey {
            case time
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }
    }

    struct Daily: Decodable {
        let max: [Double?]
        let min: [Double?]

        enum CodingKeys: String, CodingKey {
            case max = "temperature_2m_max"
            case min = "temperature_2m_min"
        }
    }

    let utcOffsetSeconds: Int
    let current: Current
    let hourly: Hourly
    let daily: Daily

    enum CodingKeys: String, CodingKey {
        case utcOffsetSeconds = "utc_offset_seconds"
        case current, hourly, daily
    }
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
}
