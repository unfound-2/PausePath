import MapKit
import Observation

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
    var distance: Double { legs.reduce(0) { $0 + $1.distance } }
    var duration: Double { distance / max(0.3, preferences.speedMetersPerSecond) }
    var paths: [[Coordinate]] { legs.map { $0.polyline.walkingCoordinates } }
    var start: Coordinate { paths[0][0] }
    var distanceMatches: Bool { abs(distance - preferences.distanceMeters) <= preferences.distanceMeters * 0.25 }
    var requirements: String {
        "Requested: \(preferences.terrain.rawValue.lowercased()), seats at most \(Int(preferences.maximumRestGapMeters)) m apart" +
        (preferences.facilities.isEmpty ? "." : ", \(preferences.facilities.map(\.rawValue).sorted().joined(separator: ", ")).")
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
