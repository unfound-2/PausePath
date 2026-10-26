import Foundation

/// Local metric projection for short walking routes. Each leg is tracked separately so
/// an overlapping return leg cannot be mistaken for the end of the outbound leg.
public enum WalkingGeometry {
    public struct Projection: Sendable {
        public let metersAlong: Double
        public let metersAway: Double
    }
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = Double.pi / 180
        let lat = (b.latitude - a.latitude) * r
        let lon = (b.longitude - a.longitude) * r
        let h = pow(sin(lat / 2), 2) + cos(a.latitude * r) * cos(b.latitude * r) * pow(sin(lon / 2), 2)
        return 6_371_000 * 2 * atan2(sqrt(min(1, h)), sqrt(max(0, 1 - h)))
    }
    public static func length(_ path: [Coordinate]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }
    public static func project(_ position: Coordinate, onto path: [Coordinate], near progress: Double, forwardAllowance: Double = 150) -> Projection? {
        guard path.count >= 2 else { return nil }
        let r = Double.pi / 180
        let scale = 6_371_000 * r
        let longitudeScale = scale * cos(position.latitude * r)
        func xy(_ point: Coordinate) -> (Double, Double) {
            var longitude = point.longitude - position.longitude
            if longitude > 180 { longitude -= 360 }
            if longitude < -180 { longitude += 360 }
            return (longitude * longitudeScale, (point.latitude - position.latitude) * scale)
        }
        var accumulated = 0.0
        var best: Projection?
        for (a, b) in zip(path, path.dropFirst()) {
            let length = distance(a, b)
            defer { accumulated += length }
            guard length > 0 else { continue }
            let (ax, ay) = xy(a); let (bx, by) = xy(b)
            let dx = bx - ax; let dy = by - ay
            let fraction = max(0, min(1, -(ax * dx + ay * dy) / max(0.0001, dx * dx + dy * dy)))
            let along = accumulated + length * fraction
            guard along >= max(0, progress - 40), along <= progress + forwardAllowance else { continue }
            let away = hypot(ax + dx * fraction, ay + dy * fraction)
            if let currentBest = best, away < currentBest.metersAway {
                best = Projection(metersAlong: along, metersAway: away)
            } else if best == nil {
                best = Projection(metersAlong: along, metersAway: away)
            }
        }
        return best
    }
}

public struct WalkProgress: Sendable {
    public private(set) var legIndex = 0
    public private(set) var metersAlongLeg = 0.0
    public private(set) var arrived = false
    public private(set) var offRoute = false
    public private(set) var hasStarted = false
    public let paths: [[Coordinate]]
    private var consecutiveOffRouteFixes = 0
    public init(paths: [[Coordinate]]) { self.paths = paths }
    public var totalMeters: Double { paths.reduce(0) { $0 + WalkingGeometry.length($1) } }
    public var completedMeters: Double {
        if arrived { return totalMeters }
        return paths.prefix(legIndex).reduce(0) { $0 + WalkingGeometry.length($1) } + metersAlongLeg
    }
    /// Returns false for unusable GPS. A poor fix must not advance a step or declare arrival.
    @discardableResult public mutating func update(position: Coordinate, accuracy: Double, age: TimeInterval) -> Bool {
        guard !arrived, paths.indices.contains(legIndex), position.latitude.isFinite, position.longitude.isFinite,
              (-90...90).contains(position.latitude), (-180...180).contains(position.longitude),
              accuracy.isFinite, accuracy >= 0, accuracy <= 50, age.isFinite, age >= -2, age <= 15,
              let start = paths[legIndex].first, let end = paths[legIndex].last else { return false }
        if !hasStarted {
            guard WalkingGeometry.distance(position, start) <= 50 else {
                markOffRouteCandidate(true)
                return true
            }
            hasStarted = true
        }
        guard let projected = WalkingGeometry.project(position, onto: paths[legIndex], near: metersAlongLeg) else {
            markOffRouteCandidate(true); return true
        }
        markOffRouteCandidate(projected.metersAway > 50)
        // Debounce the warning, not progress validation: even the first fix
        // outside the route corridor must not earn distance or declare arrival.
        guard projected.metersAway <= 50 else { return true }
        metersAlongLeg = max(metersAlongLeg, projected.metersAlong)
        let length = WalkingGeometry.length(paths[legIndex])
        if length > 0, metersAlongLeg >= max(length * 0.9, length - 25), WalkingGeometry.distance(position, end) <= 25 {
            if legIndex == paths.count - 1 { arrived = true }
            else { legIndex += 1; metersAlongLeg = 0 }
        }
        return true
    }

    private mutating func markOffRouteCandidate(_ isCandidate: Bool) {
        consecutiveOffRouteFixes = isCandidate ? consecutiveOffRouteFixes + 1 : 0
        offRoute = consecutiveOffRouteFixes >= 2
    }
}
