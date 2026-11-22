//
//  WeatherManager.swift
//  boringNotch — ma-version
//
//  Fetches current weather, the next few hours and a 2-hour rain outlook
//  from Open-Meteo (https://open-meteo.com — free, no account, no API key).
//  Only the city name typed in Settings → Ma version is sent: no location
//  permission, no tracking.
//

import AppKit
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

    @Published private(set) var status: Status = .idle
    @Published private(set) var cityName: String = ""
    @Published private(set) var cityDetail: String = ""
    @Published private(set) var temperature: Double?
    @Published private(set) var weatherCode: Int = 0
    @Published private(set) var isDay: Bool = true
    @Published private(set) var high: Double?
    @Published private(set) var low: Double?
    @Published private(set) var hourly: [WeatherHour] = []
    @Published private(set) var rain: RainOutlook = .unknown
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

        // The temperature is always visible in the closed notch now, so keep
        // it fresh: every 15 min, and right after the Mac wakes up.
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .delay(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    /// Short text for the closed notch / top bar, e.g. "9°". Nil when unknown.
    var shortTemperature: String? {
        guard status == .loaded || temperature != nil, temperature != nil else { return nil }
        return WeatherCondition.temperatureText(temperature)
    }

    var pageState: WeatherPageState {
        switch status {
        case .needsCity: return .needsCity
        case .cityNotFound: return .cityNotFound
        case .failed where temperature == nil: return .failed
        case .idle, .loading, .failed:
            if temperature == nil { return .loading }
            return .loaded(snapshot)
        case .loaded:
            return .loaded(snapshot)
        }
    }

    var snapshot: WeatherSnapshot {
        WeatherSnapshot(
            city: cityName,
            temperature: temperature,
            code: weatherCode,
            isDay: isDay,
            low: low,
            high: high,
            hours: hourly,
            rain: rain,
            timeZone: timeZone
        )
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
            status = .failed
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
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,precipitation"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "forecast_minutely_15", value: "9"),
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
        var hours: [WeatherHour] = []
        let h = forecast.hourly
        for index in h.time.indices {
            guard let date = parser.date(from: h.time[index]), date > now,
                  index < h.temperature.count, index < h.weatherCode.count,
                  let temp = h.temperature[index], let code = h.weatherCode[index]
            else { continue }
            let day = index < h.isDay.count ? (h.isDay[index] ?? 1) : 1
            hours.append(WeatherHour(date: date, temperature: temp, code: code, isDay: day == 1))
            if hours.count == 4 { break }
        }
        hourly = hours

        rain = Self.rainOutlook(forecast: forecast, parser: parser, now: now)
    }

    /// Reads the 15-minute precipitation steps covering the next ~2 hours.
    private static func rainOutlook(forecast: ForecastResponse, parser: DateFormatter, now: Date) -> RainOutlook {
        guard let minutely = forecast.minutely15 else { return .unknown }
        let threshold = 0.05 // mm per 15 min — below that it's just noise
        var steps: [(start: Date, wet: Bool)] = []
        for index in minutely.time.indices {
            guard let date = parser.date(from: minutely.time[index]),
                  date.addingTimeInterval(15 * 60) > now
            else { continue }
            let amount = index < minutely.precipitation.count ? (minutely.precipitation[index] ?? 0) : 0
            steps.append((date, amount >= threshold))
        }
        guard !steps.isEmpty else { return .unknown }

        let rainingNow = (forecast.current.precipitation ?? 0) > 0 || steps[0].wet
        if rainingNow {
            if let dry = steps.first(where: { !$0.wet }) {
                return .rainingUntil(max(dry.start, now))
            }
            return .rainingUntil(nil)
        }
        if let wet = steps.first(where: { $0.wet }) {
            return .startsAt(max(wet.start, now))
        }
        return .dry
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
        let precipitation: Double?

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
            case precipitation
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

    struct Minutely: Decodable {
        let time: [String]
        let precipitation: [Double?]
    }

    let utcOffsetSeconds: Int
    let current: Current
    let hourly: Hourly
    let daily: Daily
    let minutely15: Minutely?

    enum CodingKeys: String, CodingKey {
        case utcOffsetSeconds = "utc_offset_seconds"
        case current, hourly, daily
        case minutely15 = "minutely_15"
    }
}
