import CoreLocation
import Foundation
import OSLog
import Observation
import SwiftUI
import WeatherKit

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

private struct WeatherObservation {
    let condition: WeatherCondition
    let feelsLikeCelsius: Double
    let isPrecipitation: Bool
}

@MainActor @Observable final class WeatherGuidanceStore {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PausePath", category: "WeatherKit")

    var summary: RouteWeatherSummary?
    var attribution: WeatherAttribution?
    var isLoading = false
    var message: String?
    var updateMessage: String?

    private var lastLiveObservation: WeatherObservation?

    func load(for walk: GeneratedWalk) async {
        guard !isLoading else { return }
        isLoading = true
        summary = nil
        attribution = nil
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
            var forecasts: [Forecast<HourWeather>] = []
            var sampleErrors: [Error] = []
            for (index, coordinate) in samples.enumerated() {
                do {
                    let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    let forecast = try await WeatherService.shared.weather(for: location, including: .hourly)
                    forecasts.append(forecast)
                } catch {
                    sampleErrors.append(error)
                    Self.log(error, context: "Route forecast sample \(index + 1) failed")
                }
            }

            guard !forecasts.isEmpty else {
                message = Self.userMessage(for: sampleErrors.first)
                return
            }

            let relevant = forecasts.flatMap { forecast in
                forecast.forecast.filter {
                    $0.date < windowEnd && $0.date.addingTimeInterval(60 * 60) > windowStart
                }
            }
            guard !relevant.isEmpty else {
                message = "No forecast is available for this planned walk time. Try a nearer departure time."
                return
            }

            let conditions = Dictionary(grouping: relevant, by: { $0.condition.description })
                .sorted { $0.value.count > $1.value.count }
                .prefix(2)
                .map(\.key)
                .joined(separator: ", ")
            let forecastDates = forecasts.map { $0.metadata.date }
            let expirations = forecasts.map { $0.metadata.expirationDate }
            let distinctHours = Set(relevant.map { Calendar.current.dateInterval(of: .hour, for: $0.date)?.start ?? $0.date })

            let result = RouteWeatherSummary(
                conditions: conditions,
                minimumFeelsLikeCelsius: relevant.map { $0.apparentTemperature.converted(to: .celsius).value }.min() ?? 0,
                maximumFeelsLikeCelsius: relevant.map { $0.apparentTemperature.converted(to: .celsius).value }.max() ?? 0,
                includesHotConditions: relevant.contains { $0.condition == .hot },
                maximumPrecipitationChance: relevant.map(\.precipitationChance).max() ?? 0,
                windowStart: windowStart,
                windowEnd: windowEnd,
                retrievedAt: forecastDates.min() ?? Date(),
                expiresAt: expirations.min() ?? .distantPast,
                routeSampleCount: forecasts.count,
                coveredHourCount: distinctHours.count,
                expectedHourCount: max(1, Int(ceil(walk.duration / 3600)))
            )
            let requiredAttribution = try await WeatherService.shared.attribution
            summary = result
            attribution = requiredAttribution
            if let sampleError = sampleErrors.first {
                message = Self.userMessage(for: sampleError, partial: true)
            }
        } catch {
            Self.log(error, context: "Route forecast loading failed")
            message = Self.userMessage(for: error)
        }
    }

    func clear() {
        summary = nil
        attribution = nil
        message = nil
        updateMessage = nil
        lastLiveObservation = nil
    }

    func checkForMeaningfulChange(at coordinate: CLLocationCoordinate2D) async {
        do {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let current = try await WeatherService.shared.weather(for: location, including: .current)
            let condition = current.condition
            let observation = WeatherObservation(
                condition: condition,
                feelsLikeCelsius: current.apparentTemperature.converted(to: .celsius).value,
                isPrecipitation: Self.isPrecipitation(condition)
            )
            guard current.metadata.expirationDate > Date() else { return }
            defer { lastLiveObservation = observation }
            guard let previous = lastLiveObservation else { return }

            let temperatureChanged = abs(observation.feelsLikeCelsius - previous.feelsLikeCelsius) >= 5
            let precipitationStarted = observation.isPrecipitation && !previous.isPrecipitation
            guard temperatureChanged || precipitationStarted else { return }

            if precipitationStarted {
                updateMessage = "Weather update: precipitation is now reported near you. Conditions may vary along the rest of the route."
            } else {
                let formattedTemperature = Measurement(value: observation.feelsLikeCelsius, unit: UnitTemperature.celsius)
                    .formatted(.measurement(width: .abbreviated))
                updateMessage = "Weather update: the feels-like temperature near you is now \(formattedTemperature). Conditions may vary along the route."
            }
        } catch {
            // A failed update does not interrupt navigation or replace the forecast.
        }
    }

    private static func isPrecipitation(_ condition: WeatherCondition) -> Bool {
        switch condition {
        case .drizzle, .heavyRain, .rain, .sunShowers,
             .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms, .thunderstorms,
             .flurries, .sleet, .snow, .sunFlurries, .wintryMix, .blizzard,
             .blowingSnow, .freezingDrizzle, .freezingRain, .heavySnow, .hail:
            true
        default:
            false
        }
    }

    private static func userMessage(for error: Error?, partial: Bool = false) -> String {
        let prefix = partial ? "Some route locations could not be checked. " : ""
        guard let error else {
            return "Weather is unavailable for this route right now. Try again later."
        }

        if let weatherError = error as? WeatherError {
            if case .permissionDenied = weatherError {
                return prefix + "Weather access is not authorized. Check that WeatherKit is enabled for this app in Xcode and for its App ID in your Apple Developer account."
            }
        }
        if Self.isNetworkError(error) {
            return prefix + "Weather could not be reached. Check your internet connection and try again."
        }
        if let weatherError = error as? WeatherError {
            if case .unknown = weatherError {
                return prefix + "A forecast is not available for this route right now. Try again later or choose another time."
            }
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
    @Environment(\.colorScheme) private var colorScheme

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
                if let attribution = store.attribution {
                    WeatherAttributionRow(attribution: attribution, colorScheme: colorScheme)
                }
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

private struct WeatherAttributionRow: View {
    let attribution: WeatherAttribution
    let colorScheme: ColorScheme

    var body: some View {
        HStack {
            AsyncImage(url: colorScheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL) { image in
                image.resizable().scaledToFit().frame(maxWidth: 130, maxHeight: 24)
            } placeholder: {
                Text(attribution.serviceName).font(.caption2)
            }
            Spacer()
            Link("Data sources", destination: attribution.legalPageURL).font(.caption2)
        }
    }
}
