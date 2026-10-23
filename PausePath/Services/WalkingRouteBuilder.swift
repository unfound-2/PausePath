import MapKit
import Observation
import CryptoKit

extension MKPolyline {
    var walkingCoordinates: [Coordinate] {
        var values = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&values, range: NSRange(location: 0, length: pointCount))
        return values.map { Coordinate($0.latitude, $0.longitude) }
    }
}
extension Coordinate {
    var mapCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

struct GeneratedWalk: Identifiable {
    let id = UUID()
    let name: String
    let legs: [MKRoute]
    let preferences: RoutePreferences
    var stops: [DiscoveredPlace] = []
    var allowUnknownRestStops = true
    var restAssessment: RestGapAssessment { WalkingRouteOption(id: id, title: name, destinationName: name, stops: stops, legs: legs).restAssessment(preferences, allowUnknown: allowUnknownRestStops) }
    var distance: Double { legs.reduce(0) { $0 + $1.distance } }
    var duration: Double { distance / max(0.3, preferences.speedMetersPerSecond) }
    var paths: [[Coordinate]] { legs.map { $0.polyline.walkingCoordinates } }
    var start: Coordinate { paths[0][0] }
    /// Stable opaque identifier for this route's sampled geometry. The identifier stays on
    /// device; only aggregate challenge totals are sent to the community service.
    var routeIdentity: String {
        let signature = paths.map(sampledPathSignature).joined(separator: "|")
        return SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func sampledPathSignature(_ path: [Coordinate]) -> String {
        guard let first = path.first else { return "" }
        let length = WalkingGeometry.length(path)
        guard length > 0 else { return "\(Int((first.latitude * 10_000).rounded())),\(Int((first.longitude * 10_000).rounded()))" }
        var distances = Array(stride(from: 0.0, through: length, by: 100.0))
        if distances.last != length { distances.append(length) }
        return distances.compactMap { coordinate(at: $0, along: path) }.map {
            "\(Int(($0.latitude * 10_000).rounded())),\(Int(($0.longitude * 10_000).rounded()))"
        }.joined(separator: ";")
    }
    private func coordinate(at target: Double, along path: [Coordinate]) -> Coordinate? {
        guard let first = path.first else { return nil }
        if target <= 0 { return first }
        var traversed = 0.0
        for (start, end) in zip(path, path.dropFirst()) {
            let segmentLength = WalkingGeometry.distance(start, end)
            if traversed + segmentLength >= target, segmentLength > 0 {
                let fraction = min(1, max(0, (target - traversed) / segmentLength))
                return Coordinate(start.latitude + (end.latitude - start.latitude) * fraction,
                                  start.longitude + (end.longitude - start.longitude) * fraction)
            }
            traversed += segmentLength
        }
        return path.last
    }
    var distanceMatches: Bool { abs(distance - preferences.distanceMeters) <= preferences.distanceMeters * 0.25 }
    var requirements: String {
        "Requested: \(preferences.terrain.rawValue.lowercased()), seats at most \(Int(preferences.maximumRestGapMeters)) m apart" +
        (preferences.facilities.isEmpty ? "." : ", \(preferences.facilities.map(\.rawValue).sorted().joined(separator: ", ")).")
    }
}

struct SavedRouteRecord: Codable, Identifiable {
    let id: UUID
    let title: String
    let destinationName: String
    let stopNames: [String]
    let stopKinds: [FacilityKind]
    let origin: Coordinate
    let destination: Coordinate
    let legCoordinates: [[Coordinate]]
    let distanceMeters: Double
    let estimatedSeconds: Double
    let difficulty: String
    let savedAt: Date

    var isFavorite: Bool? = nil
    var collection: String? = nil
    var stops: [SavedRouteStop]? = nil

    fileprivate var identity: String {
        let start = String(format: "%.4f,%.4f", origin.latitude, origin.longitude)
        let end = String(format: "%.4f,%.4f", destination.latitude, destination.longitude)
        return ([destinationName.lowercased(), start, end] + stopNames.map { $0.lowercased() }).joined(separator: "|")
    }
}

enum SavedRouteStore {
    private static let storageKey = "pausepath.savedRoutes.v1"

    static func load() -> [SavedRouteRecord] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([SavedRouteRecord].self, from: data)) ?? []
    }

    static func update(_ record: SavedRouteRecord) {
        var values = load(); values.removeAll { $0.id == record.id }; values.insert(record, at: 0)
        persist(values)
    }
    static func delete(_ id: UUID) { persist(load().filter { $0.id != id }) }
    private static func persist(_ values: [SavedRouteRecord]) {
        if let data = try? JSONEncoder().encode(values) { UserDefaults.standard.set(data, forKey: storageKey) }
    }
    static func saveWalk(_ walk: GeneratedWalk) -> SavedRouteRecord? {
        guard let start = walk.paths.first?.first, let end = walk.paths.last?.last else { return nil }
        let option = WalkingRouteOption(id: walk.id, title: walk.name, destinationName: walk.name, stops: walk.stops, legs: walk.legs)
        save([option], origin: start.mapCoordinate, destination: end.mapCoordinate)
        return load().first { $0.legCoordinates == walk.paths }
    }

    static func save(_ options: [WalkingRouteOption], origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D) {
        var records = load()
        let start = Coordinate(origin.latitude, origin.longitude)
        let end = Coordinate(destination.latitude, destination.longitude)
        let difficultyPreferences = RouteDifficultyPreferences(
            storageValue: UserDefaults.standard.string(forKey: RouteDifficultyPreferences.storageKey) ?? RouteDifficultyPreferences.defaultStorageValue
        )
        for option in options {
            let rating = RouteDifficultyCalculator.assess(
                RouteDifficultyInput(distanceMeters: option.distance, durationSeconds: option.duration),
                preferences: difficultyPreferences
            ).label
            var record = SavedRouteRecord(
                id: option.id,
                title: option.title,
                destinationName: option.destinationName,
                stopNames: option.stops.map { $0.provider == "Mapbox" ? "Café (refresh required)" : ($0.item.name ?? $0.kind.rawValue) },
                stopKinds: option.stops.map(\.kind),
                origin: start,
                destination: end,
                legCoordinates: option.legs.map { $0.polyline.walkingCoordinates },
                distanceMeters: option.distance,
                estimatedSeconds: option.duration,
                difficulty: rating,
                savedAt: Date()
            )
            record.stops = option.stops.enumerated().map { index, place in
                let waypoint = option.legs.indices.contains(index) ? option.legs[index].polyline.walkingCoordinates.last : nil
                return SavedRouteStop(place, routeWaypoint: waypoint)
            }
            if let previous = records.first(where: { $0.identity == record.identity }) {
                record = SavedRouteRecord(id: previous.id, title: record.title, destinationName: record.destinationName,
                    stopNames: record.stopNames, stopKinds: record.stopKinds, origin: record.origin, destination: record.destination,
                    legCoordinates: record.legCoordinates, distanceMeters: record.distanceMeters, estimatedSeconds: record.estimatedSeconds,
                    difficulty: record.difficulty, savedAt: record.savedAt, isFavorite: previous.isFavorite, collection: previous.collection, stops: record.stops)
            }
            records.removeAll { $0.identity == record.identity }
            records.insert(record, at: 0)
        }
        let favorites = records.filter { $0.isFavorite == true }
        records = favorites + records.filter { $0.isFavorite != true }.prefix(max(0, 100 - favorites.count))
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

@MainActor enum WalkingDirections {
    static func route(from start: Coordinate, to end: Coordinate, departure: Date) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start.mapCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end.mapCoordinate))
        request.transportType = .walking
        request.departureDate = departure
        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        try Task.checkCancellation()
        guard let route = response.routes.first, route.distance > 30, route.polyline.pointCount > 1 else {
            throw NSError(domain: "PausePath", code: 1, userInfo: [NSLocalizedDescriptionKey: "No walking route found."])
        }
        return route
    }
}

@MainActor @Observable final class WalkingRouteBuilder {
    var origin: Coordinate?
    var originName = "Choose your starting point"
    var candidates: [GeneratedWalk] = []
    var isLoading = false
    var status = "Choose a start to create a real walking route."
    private var operation: Task<Void, Never>?
    private var token = UUID()
    func cancel() { token = UUID(); operation?.cancel(); isLoading = false }
    func invalidate() { cancel(); candidates = [] }
    func setOrigin(_ coordinate: Coordinate, name: String) {
        invalidate(); origin = coordinate; originName = name; status = "Ready to create walking routes."
    }
    func searchOrigin(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        invalidate(); isLoading = true; let current = token
        operation = Task {
            defer { if current == token { isLoading = false } }
            do {
                let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
                let result = try await MKLocalSearch(request: request).start()
                guard current == token else { return }
                guard let first = result.mapItems.first else { status = "No start found. Try a street address or landmark."; return }
                let c = first.placemark.coordinate
                origin = Coordinate(c.latitude, c.longitude)
                originName = first.name ?? query
                status = "Starting point found. Check the map before starting."
            } catch { if current == token { status = "Could not find this start. Check your connection and try again." } }
        }
    }
    func generate(preferences: RoutePreferences) {
        guard let origin else { return }
        invalidate(); isLoading = true; let current = token
        operation = Task {
            defer { if current == token { isLoading = false } }
            var failures = 0
            // Bound server requests: four candidate bearings, each with independently routed legs.
            for (index, bearing) in [0.0, 90, 180, 270].enumerated() {
                guard current == token, !Task.isCancelled else { return }
                status = "Finding walk \(index + 1) of 4…"
                let end = destination(from: origin, meters: preferences.distanceMeters * 0.40, bearing: bearing)
                do {
                    let outbound = try await WalkingDirections.route(from: origin, to: end, departure: preferences.departure)
                    guard let start = outbound.polyline.walkingCoordinates.first, let turn = outbound.polyline.walkingCoordinates.last,
                          WalkingGeometry.distance(start, origin) < 80 else { continue }
                    let returning = try await WalkingDirections.route(from: turn, to: start, departure: preferences.departure.addingTimeInterval(outbound.distance / max(0.3, preferences.speedMetersPerSecond)))
                    guard current == token, let returnStart = returning.polyline.walkingCoordinates.first,
                          let returnEnd = returning.polyline.walkingCoordinates.last,
                          WalkingGeometry.distance(turn, returnStart) < 30, WalkingGeometry.distance(start, returnEnd) < 30 else { continue }
                    let walk = GeneratedWalk(name: "Walk via \(outbound.name)", legs: [outbound, returning], preferences: preferences)
                    // Results outside the requested range are never silently substituted.
                    if walk.distanceMatches { candidates.append(walk) }
                } catch {
                    guard current == token else { return }; failures += 1
                    if let mapError = error as? MKError, mapError.code == .loadingThrottled { break }
                }
            }
            guard current == token else { return }
            candidates.sort { abs($0.distance - preferences.distanceMeters) < abs($1.distance - preferences.distanceMeters) }
            status = candidates.isEmpty ? "No route within ±25% of your distance was found. Try a different start or distance.\(failures > 0 ? " Some directions requests were unavailable; try again later." : "")" : "\(candidates.count) real out-and-back walks within ±25% of your distance. Terrain, rest gaps and facility hours are unverified."
        }
    }
    private func destination(from origin: Coordinate, meters: Double, bearing: Double) -> Coordinate {
        let radians = Double.pi / 180
        let lat = origin.latitude * radians; let lon = origin.longitude * radians
        let angle = meters / 6_371_000; let heading = bearing * radians
        let nextLat = asin(sin(lat) * cos(angle) + cos(lat) * sin(angle) * cos(heading))
        let nextLon = lon + atan2(sin(heading) * sin(angle) * cos(lat), cos(angle) - sin(lat) * sin(nextLat))
        return Coordinate(nextLat / radians, (nextLon / radians + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
}
