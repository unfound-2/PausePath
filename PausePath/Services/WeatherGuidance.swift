import CoreLocation
import Foundation
import OSLog
import Observation
import SwiftUI

struct RouteWeatherSummary {
    let conditions: String
    let minimumFeelsLikeCelsius: Double
    let maximumFeelsLikeCelsius: Double
    let includesHotConditions: Bool
    let maximumPrecipitationChance: Double
    let windowStart: Date
    let windowEnd: Date
    let retrievedAt: Date
    let expiresAt: Date
    let routeSampleCount: Int
    let coveredHourCount: Int
    let expectedHourCount: Int

    var temperatureRange: String {
        "Feels like \(temperature(minimumFeelsLikeCelsius))–\(temperature(maximumFeelsLikeCelsius))"
    }

    var precipitationText: String {
        "Rain chance up to \(Int((maximumPrecipitationChance * 100).rounded()))%"
    }

    var isStale: Bool {
        Date() > expiresAt || Date().timeIntervalSince(retrievedAt) > 8 * 60 * 60
    }

    var coverageText: String? {
        guard coveredHourCount < expectedHourCount else { return nil }
        return "Forecast data covers part of your planned walk only."
    }

    var impactMessage: String {
        if includesHotConditions {
            return "Hot conditions are forecast. The feels-like temperature may reach \(temperature(maximumFeelsLikeCelsius)). Shade along this route is not mapped. Consider another time or bringing water."
        }
        if maximumPrecipitationChance > 0 {
            return "Rain is possible during part of this walk, with a forecast chance up to \(Int((maximumPrecipitationChance * 100).rounded()))%. Forecasts can change; consider weather-appropriate layers or another time."
        }
        return "Conditions can vary along the route and may change before you leave. Shade and water-stop information is incomplete."
    }

    private func temperature(_ celsius: Double) -> String {
        let unit: UnitTemperature = Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
        return Measurement(value: celsius, unit: UnitTemperature.celsius)
            .converted(to: unit)
            .formatted(.measurement(width: .abbreviated))
    }
}

private struct ForecastHour {
    let date: Date
    let temperature: Double
    let precipitationChance: Double
    let code: Int
    var description: String {
        switch code {
        case 0: "Clear"
        case 1, 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67, 80...82: "Rain"
        case 71...77, 85, 86: "Snow"
        case 95...99: "Thunderstorms"
        default: "Conditions unavailable"
        }
    }
    var isPrecipitation: Bool { (51...99).contains(code) }
}

private struct RouteForecast {
    let hours: [ForecastHour]
    let retrievedAt: Date
    var expiresAt: Date { retrievedAt.addingTimeInterval(15 * 60) }
}

private struct OpenMeteoResponse: Decodable {
    struct Hourly: Decodable {
        let time: [Double]
        let apparent_temperature: [Double?]
        let precipitation_probability: [Double?]
        let weather_code: [Int?]
    }
    let hourly: Hourly
}

/// Memory-only cache: no weather coordinates are written to disk.
private actor OpenMeteoProvider {
    static let shared = OpenMeteoProvider()
    private var cache: [String: RouteForecast] = [:]
    private let session = URLSession(configuration: .ephemeral)

    func forecast(latitude: Double, longitude: Double) async throws -> RouteForecast {
        try Task.checkCancellation()
        // Approximately kilometre-scale locations suffice for forecast models.
        let lat = (latitude * 100).rounded() / 100
        let lon = (longitude * 100).rounded() / 100
        let key = "\(lat),\(lon)"
        if let cached = cache[key], cached.expiresAt > Date() { return cached }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "hourly", value: "apparent_temperature,precipitation_probability,weather_code"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "GMT"),
            URLQueryItem(name: "temperature_unit", value: "celsius")
        ]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 12
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let h = try JSONDecoder().decode(OpenMeteoResponse.self, from: data).hourly
        guard h.time.count == h.apparent_temperature.count,
              h.time.count == h.precipitation_probability.count,
              h.time.count == h.weather_code.count else { throw URLError(.cannotParseResponse) }
        let hours = h.time.indices.compactMap { index -> ForecastHour? in
            guard let temperature = h.apparent_temperature[index],
                  let probability = h.precipitation_probability[index],
                  let code = h.weather_code[index], temperature.isFinite,
                  (0...100).contains(probability) else { return nil }
            return ForecastHour(date: Date(timeIntervalSince1970: h.time[index]),
                                temperature: temperature, precipitationChance: probability / 100, code: code)
        }
        guard !hours.isEmpty else { throw URLError(.cannotParseResponse) }
        let result = RouteForecast(hours: hours, retrievedAt: Date())
        cache = cache.filter { $0.value.expiresAt > Date() }
        if cache.count >= 24, let oldest = cache.min(by: { $0.value.retrievedAt < $1.value.retrievedAt }) {
            cache.removeValue(forKey: oldest.key)
        }
        cache[key] = result
        return result
    }
}

private struct WeatherObservation {
    let feelsLikeCelsius: Double
    let isPrecipitation: Bool
}

@MainActor @Observable final class WeatherGuidanceStore {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PausePath", category: "Weather")

    var summary: RouteWeatherSummary?
    var isLoading = false
    var message: String?
    var updateMessage: String?

    private var lastLiveObservation: WeatherObservation?

    func load(for walk: GeneratedWalk) async {
        guard !isLoading else { return }
        isLoading = true
        summary = nil
        message = nil
        updateMessage = nil
        lastLiveObservation = nil
        defer { isLoading = false }

        do {
            let samples = Self.routeSamples(for: walk)
            guard !samples.isEmpty else {
                message = "Weather is unavailable for this route."
                return
            }

            let windowStart = walk.preferences.departure
            let windowEnd = windowStart.addingTimeInterval(max(60, walk.duration))
            var forecasts: [RouteForecast] = []
            var sampleErrors: [Error] = []
            for (index, coordinate) in samples.enumerated() {
                do {
                    try Task.checkCancellation()
                    let forecast = try await OpenMeteoProvider.shared.forecast(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    try Task.checkCancellation()
                    forecasts.append(forecast)
                } catch {
                    if Task.isCancelled { return }
                    sampleErrors.append(error)
                    Self.log(error, context: "Route forecast sample \(index + 1) failed")
                }
            }

            guard !forecasts.isEmpty else {
                message = Self.userMessage(for: sampleErrors.first)
                return
            }

            let relevant = forecasts.flatMap { forecast in
                forecast.hours.filter {
                    $0.date < windowEnd && $0.date.addingTimeInterval(60 * 60) > windowStart
                }
            }
            guard !relevant.isEmpty else {
                message = "No forecast is available for this planned walk time. Try a nearer departure time."
                return
            }

            let conditions = Dictionary(grouping: relevant, by: { $0.description })
                .sorted { $0.value.count > $1.value.count }
                .prefix(2)
                .map(\.key)
                .joined(separator: ", ")
            let forecastDates = forecasts.map { $0.retrievedAt }
            let expirations = forecasts.map { $0.expiresAt }
            let distinctHours = Set(relevant.map { Calendar.current.dateInterval(of: .hour, for: $0.date)?.start ?? $0.date })

            let result = RouteWeatherSummary(
                conditions: conditions,
                minimumFeelsLikeCelsius: relevant.map { $0.temperature }.min() ?? 0,
                maximumFeelsLikeCelsius: relevant.map { $0.temperature }.max() ?? 0,
                includesHotConditions: false,
                maximumPrecipitationChance: relevant.map(\.precipitationChance).max() ?? 0,
                windowStart: windowStart,
                windowEnd: windowEnd,
                retrievedAt: forecastDates.min() ?? Date(),
                expiresAt: expirations.min() ?? .distantPast,
                routeSampleCount: forecasts.count,
                coveredHourCount: distinctHours.count,
                expectedHourCount: max(1, Int(ceil(windowEnd.timeIntervalSince1970 / 3600) - floor(windowStart.timeIntervalSince1970 / 3600)))
            )
            try Task.checkCancellation()
            summary = result
            if let sampleError = sampleErrors.first {
                message = Self.userMessage(for: sampleError, partial: true)
            }
        } catch {
            if Task.isCancelled { return }
            Self.log(error, context: "Route forecast loading failed")
            message = Self.userMessage(for: error)
        }
    }

    func clear() {
        summary = nil
        message = nil
        updateMessage = nil
        lastLiveObservation = nil
    }

    func checkForMeaningfulChange(at coordinate: CLLocationCoordinate2D) async {
        do {
            let forecast = try await OpenMeteoProvider.shared.forecast(latitude: coordinate.latitude, longitude: coordinate.longitude)
            try Task.checkCancellation()
            guard let current = forecast.hours.first(where: { $0.date <= Date() && $0.date.addingTimeInterval(3600) > Date() }) else { return }
            let observation = WeatherObservation(feelsLikeCelsius: current.temperature, isPrecipitation: current.isPrecipitation)
            defer { lastLiveObservation = observation }
            guard let previous = lastLiveObservation else { return }

            let temperatureChanged = abs(observation.feelsLikeCelsius - previous.feelsLikeCelsius) >= 5
            let precipitationStarted = observation.isPrecipitation && !previous.isPrecipitation
            guard temperatureChanged || precipitationStarted else { return }

            if precipitationStarted {
                updateMessage = "Weather update: precipitation is now forecast near you. Conditions may vary along the rest of the route."
            } else {
                let formattedTemperature = Measurement(value: observation.feelsLikeCelsius, unit: UnitTemperature.celsius)
                    .formatted(.measurement(width: .abbreviated))
                updateMessage = "Weather update: the forecast feels-like temperature near you is now \(formattedTemperature). Conditions may vary along the route."
            }
        } catch {
            // A failed update does not interrupt navigation or replace the forecast.
        }
    }

    private static func userMessage(for error: Error?, partial: Bool = false) -> String {
        let prefix = partial ? "Some route locations could not be checked. " : ""
        guard let error else {
            return "Weather is unavailable for this route right now. Try again later."
        }

        if Self.isNetworkError(error) {
            return prefix + "Weather could not be reached. Check your internet connection and try again."
        }
        return prefix + "Weather is temporarily unavailable for this route. Try again later."
    }

    private static func isNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff,
                    .dataNotAllowed].contains(urlError.code)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let networkErrorCodes: Set<Int> = [
                URLError.Code.notConnectedToInternet.rawValue,
                URLError.Code.networkConnectionLost.rawValue,
                URLError.Code.cannotConnectToHost.rawValue,
                URLError.Code.cannotFindHost.rawValue,
                URLError.Code.dnsLookupFailed.rawValue,
                URLError.Code.timedOut.rawValue,
                URLError.Code.internationalRoamingOff.rawValue,
                URLError.Code.dataNotAllowed.rawValue
            ]
            return networkErrorCodes.contains(nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isNetworkError(underlying)
        }
        return false
    }

    private static func log(_ error: Error, context: String) {
        #if DEBUG
        logger.error("\(context, privacy: .public): \(String(reflecting: error), privacy: .private)")
        #endif
    }

    private static func routeSamples(for walk: GeneratedWalk) -> [Coordinate] {
        let coordinates = walk.paths.flatMap { $0 }
        guard coordinates.count > 1 else { return coordinates }
        let total = WalkingGeometry.length(coordinates)
        guard total > 0 else { return [coordinates[0]] }
        var samples: [Coordinate] = []
        for distance in [0, total / 2, total] {
            guard let sample = coordinate(at: distance, along: coordinates),
                  !samples.contains(where: { WalkingGeometry.distance($0, sample) < 250 }) else { continue }
            samples.append(sample)
        }
        return samples
    }

    private static func coordinate(at target: Double, along path: [Coordinate]) -> Coordinate? {
        guard let first = path.first else { return nil }
        if target <= 0 { return first }
        var traversed = 0.0
        for (start, end) in zip(path, path.dropFirst()) {
            let segmentLength = WalkingGeometry.distance(start, end)
            if traversed + segmentLength >= target, segmentLength > 0 {
                let fraction = min(1, max(0, (target - traversed) / segmentLength))
                var longitudeDelta = end.longitude - start.longitude
                if longitudeDelta > 180 { longitudeDelta -= 360 }
                if longitudeDelta < -180 { longitudeDelta += 360 }
                let longitude = start.longitude + longitudeDelta * fraction
                return Coordinate(
                    start.latitude + (end.latitude - start.latitude) * fraction,
                    (longitude + 540).truncatingRemainder(dividingBy: 360) - 180
                )
            }
            traversed += segmentLength
        }
        return path.last
    }
}

struct WeatherGuidanceCard: View {
    let store: WeatherGuidanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Weather for your planned walk", systemImage: "cloud.sun.fill")
                .font(.headline)

            if store.isLoading {
                ProgressView("Checking route weather…")
            } else if let summary = store.summary {
                Text("\(summary.windowStart.formatted(date: .abbreviated, time: .shortened))–\(summary.windowEnd.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline.weight(.medium))
                Text(summary.conditions.isEmpty ? "Conditions unavailable" : summary.conditions)
                    .font(.subheadline)
                Text("\(summary.temperatureRange) • \(summary.precipitationText)")
                    .font(.subheadline)
                Text("How this may affect your walk: \(summary.impactMessage)")
                    .font(.callout)
                Text("Forecasts are estimates and can change. Sampled at \(summary.routeSampleCount) points along the route.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("To compare another departure time or route, close this preview and adjust Plan.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = store.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let coverage = summary.coverageText { Text(coverage).font(.caption).foregroundStyle(.secondary) }
                if summary.isStale {
                    Label("This forecast may be out of date.", systemImage: "clock")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Retrieved \(summary.retrievedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Link("Weather data: Open-Meteo · CC BY 4.0", destination: URL(string: "https://open-meteo.com/")!)
                    .font(.caption2)

            } else {
                Text(store.message ?? "Weather has not been checked.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Shade and water-stop information is incomplete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}
