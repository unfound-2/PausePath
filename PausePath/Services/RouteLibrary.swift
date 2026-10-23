import Foundation
import MapKit

struct SavedRouteStop: Codable, Identifiable {
    let id: UUID
    let name: String
    let kind: FacilityKind
    let coordinate: Coordinate
    let sharedID: UUID?
    init(_ place: DiscoveredPlace, routeWaypoint: Coordinate? = nil) {
        id = place.provider == "Mapbox" ? UUID() : place.id; name = place.provider == "Mapbox" ? "Café (refresh required)" : (place.item.name ?? place.kind.rawValue); kind = place.kind
        // A temporary business result is not a persistent place record. Keep only
        // the independently calculated walking waypoint and re-search on reuse.
        coordinate = routeWaypoint ?? Coordinate(place.item.placemark.coordinate.latitude, place.item.placemark.coordinate.longitude)
        sharedID = place.shared?.id
    }
    init(_ shared: SharedRouteStop) {
        id = shared.id ?? UUID(); name = shared.name; kind = FacilityKind.fromAPI(shared.category) ?? .bench
        coordinate = shared.location.coordinate ?? Coordinate(0,0); sharedID = shared.id
    }
}

struct SharedRoutePoint: Codable {
    let type: String
    let coordinates: [Double]
    init(_ coordinate: Coordinate) { type = "Point"; coordinates = [coordinate.longitude, coordinate.latitude] }
    var coordinate: Coordinate? {
        guard coordinates.count == 2, coordinates.allSatisfy(\.isFinite), (-180...180).contains(coordinates[0]), (-90...90).contains(coordinates[1]) else { return nil }
        return Coordinate(coordinates[1], coordinates[0])
    }
}
struct SharedRouteStop: Codable, Identifiable {
    let id: UUID?
    let name: String
    let category: String
    let location: SharedRoutePoint
}
struct SharedRouteSnapshot: Codable {
    struct Geometry: Codable { let type: String; let coordinates: [[Double]] }
    let title: String
    let geometry: Geometry
    let stops: [SharedRouteStop]
    let waypoints: [SharedRoutePoint]?
    let distance_meters: Double
    let estimated_seconds: Double
    var coordinates: [CLLocationCoordinate2D] {
        geometry.coordinates.compactMap { values in
            guard values.count == 2, values.allSatisfy(\.isFinite), (-180...180).contains(values[0]), (-90...90).contains(values[1]) else { return nil }
            return CLLocationCoordinate2D(latitude: values[1], longitude: values[0])
        }
    }
    init(_ record: SavedRouteRecord) {
        title = String(record.title.prefix(120)); distance_meters = record.distanceMeters; estimated_seconds = record.estimatedSeconds
        let points = record.legCoordinates.flatMap { $0 }
        let strideSize = max(1, Int(ceil(Double(points.count) / 1800)))
        var sampled = points.enumerated().filter { $0.offset % strideSize == 0 }.map(\.element)
        if let last = points.last, sampled.last != last { sampled.append(last) }
        geometry = Geometry(type: "LineString", coordinates: sampled.map { [$0.longitude, $0.latitude] })
        waypoints = record.legCoordinates.dropLast().compactMap(\.last).prefix(24).map(SharedRoutePoint.init)
        stops = (record.stops ?? []).prefix(12).map {
            SharedRouteStop(id: $0.sharedID, name: String($0.name.prefix(200)), category: $0.kind.apiCategory, location: SharedRoutePoint($0.coordinate))
        }
    }
    var replayRecord: SavedRouteRecord? {
        let path = coordinates.map { Coordinate($0.latitude,$0.longitude) }
        guard let first = path.first, let last = path.last, path.count > 1 else { return nil }
        return SavedRouteRecord(id: UUID(), title: title, destinationName: title, stopNames: stops.map(\.name),
            stopKinds: stops.compactMap { FacilityKind.fromAPI($0.category) }, origin: first, destination: last,
            legCoordinates: replayLegs(path: path), distanceMeters: distance_meters, estimatedSeconds: estimated_seconds,
            difficulty: "Unknown", savedAt: Date(), stops: stops.map(SavedRouteStop.init))
    }
    private func replayLegs(path: [Coordinate]) -> [[Coordinate]] {
        guard let first = path.first, let last = path.last else { return [] }
        let anchors = (waypoints ?? []).compactMap(\.coordinate)
        guard !anchors.isEmpty else { return [path] }
        let ends = anchors + [last]
        return Array(zip([first] + anchors, ends)).map { [$0.0,$0.1] }
    }
    var json: [String: Any] { ((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any]) ?? [:] }
}

@MainActor enum RouteLibrary {
    /// Rebuild directions from saved waypoints; never treat an old polyline as live directions.
    static func repeatRoute(_ record: SavedRouteRecord, preferences: RoutePreferences) async throws -> GeneratedWalk {
        if !record.stopNames.isEmpty && record.stops == nil {
            throw ServiceFailure(status: 409, message: "This older route has no saved stop locations. Rebuild it in Explore before repeating.")
        }
        var refreshed: [DiscoveredPlace] = []
        var start = record.origin
        var legs: [MKRoute] = []
        var elapsed = 0.0
        for stop in record.stops ?? [] {
            try Task.checkCancellation()
            let place: DiscoveredPlace
            if let id = stop.sharedID {
                let data = try await PausePathAPI.request("api/v1/pois/\(id)")
                let poi = try JSONDecoder().decode(SharedPOI.self, from: data)
                guard !poi.unavailable, !poi.reportedUnavailable, !poi.restrictedAccess, let current = poi.place else {
                    throw ServiceFailure(status: 409, message: "\(stop.name) is unavailable or has restricted access. Update your stops in Explore.")
                }
                place = current
            } else {
                let region = MKCoordinateRegion(center: stop.coordinate.mapCoordinate, latitudinalMeters: 500, longitudinalMeters: 500)
                var candidates: [DiscoveredPlace]
                if stop.kind == .cafe { candidates = try await PausePathAPI.cafes(region) }
                else { candidates = try await PausePathAPI.search(region).pois.compactMap(\.place).filter { $0.kind == stop.kind } }
                candidates = candidates.filter { candidate in
                    let coordinate = Coordinate(candidate.item.placemark.coordinate.latitude, candidate.item.placemark.coordinate.longitude)
                    return WalkingGeometry.distance(stop.coordinate, coordinate) <= 50 && candidate.shared?.unavailable != true && candidate.shared?.reportedUnavailable != true && candidate.shared?.restrictedAccess != true
                }.sorted { a,b in
                    WalkingGeometry.distance(stop.coordinate,Coordinate(a.item.placemark.coordinate.latitude,a.item.placemark.coordinate.longitude)) < WalkingGeometry.distance(stop.coordinate,Coordinate(b.item.placemark.coordinate.latitude,b.item.placemark.coordinate.longitude))
                }
                guard let current = candidates.first else { throw ServiceFailure(status: 409, message: "A saved stop could not be found again. Update this route in Explore.") }
                place = current
            }
            let endpoint = Coordinate(place.item.placemark.coordinate.latitude, place.item.placemark.coordinate.longitude)
            let leg = try await WalkingDirections.route(from: start, to: endpoint, departure: Date().addingTimeInterval(elapsed))
            elapsed += leg.distance / max(0.3, preferences.speedMetersPerSecond)
            guard place.shared?.openAtArrival(Date().addingTimeInterval(elapsed)) != false else {
                throw ServiceFailure(status: 409, message: "\(stop.name) is closed at estimated arrival. Update your stops in Explore.")
            }
            try validate(leg, from: start, to: endpoint)
            legs.append(leg); refreshed.append(place); start = endpoint; elapsed += 300
        }
        // Keep non-amenity turnarounds too, especially out-and-back routes whose
        // origin and destination are the same. Do not collapse them to a direct leg.
        for anchor in record.legCoordinates.dropLast().compactMap(\.last).dropFirst((record.stops ?? []).count) {
            try Task.checkCancellation()
            let leg = try await WalkingDirections.route(from: start, to: anchor, departure: Date().addingTimeInterval(elapsed))
            try validate(leg, from: start, to: anchor)
            legs.append(leg); start = anchor; elapsed += leg.distance / max(0.3, preferences.speedMetersPerSecond)
        }
        let final = try await WalkingDirections.route(from: start, to: record.destination, departure: Date().addingTimeInterval(elapsed))
        try validate(final, from: start, to: record.destination); legs.append(final)
        var current = preferences; current.departure = .now
        return GeneratedWalk(name: record.title, legs: legs, preferences: current, stops: refreshed)
    }
    private static func validate(_ leg: MKRoute, from: Coordinate, to: Coordinate) throws {
        guard let first = leg.polyline.walkingCoordinates.first, let last = leg.polyline.walkingCoordinates.last,
              WalkingGeometry.distance(first, from) <= 30, WalkingGeometry.distance(last, to) <= 30 else {
            throw ServiceFailure(status: 409, message: "A saved waypoint is disconnected from walking directions. Rebuild this route in Explore.")
        }
    }
}
