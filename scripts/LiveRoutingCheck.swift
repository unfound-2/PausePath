// Optional network integration check. Uses a public landmark, never personal GPS.
// Compile with RoutePlanning.swift, NavigationProgress.swift and WalkingRouteBuilder.swift.
import Foundation

@main struct LiveRoutingCheck {
    @MainActor static func main() async {
        let builder = WalkingRouteBuilder()
        builder.setOrigin(Coordinate(41.8826, -87.6226), name: "Millennium Park test start")
        var preferences = RoutePreferences()
        preferences.distanceMeters = 1200
        builder.generate(preferences: preferences)
        for _ in 0..<120 {
            if !builder.isLoading { break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard !builder.isLoading else { builder.cancel(); print("FAIL: route generation timed out"); exit(1) }
        print(builder.status)
        guard !builder.candidates.isEmpty else { print("FAIL: no live candidates (network/provider dependent)"); exit(1) }
        for walk in builder.candidates {
            guard walk.distanceMatches, walk.legs.count == 2,
                  walk.legs.allSatisfy({ !$0.steps.filter { !$0.instructions.isEmpty }.isEmpty }),
                  walk.paths.allSatisfy({ $0.count >= 2 }) else { print("FAIL: invalid route"); exit(1) }
            // Replay the actual route geometry with 10m subdivisions and good synthetic fixes.
            var progress = WalkProgress(paths: walk.paths)
            for path in walk.paths {
                for (a, b) in zip(path, path.dropFirst()) {
                    let subdivisions = max(1, Int(ceil(WalkingGeometry.distance(a, b) / 10)))
                    for n in 0...subdivisions {
                        let fraction = Double(n) / Double(subdivisions)
                        let point = Coordinate(a.latitude + (b.latitude - a.latitude) * fraction, a.longitude + (b.longitude - a.longitude) * fraction)
                        progress.update(position: point, accuracy: 5, age: 0)
                    }
                }
            }
            guard progress.arrived else { print("FAIL: replay did not arrive for \(walk.name), leg \(progress.legIndex), progress \(progress.metersAlongLeg)"); exit(1) }
            print("PASS: \(walk.name), \(Int(walk.distance)) m, \(walk.legs.reduce(0) { $0 + $1.steps.count }) steps; replay arrived")
        }
    }
}
