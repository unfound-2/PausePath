import MapKit

extension WalkingRouteOption {
    func restAssessment(_ preferences: RoutePreferences, allowUnknown: Bool = true) -> RestGapAssessment {
        var meters = 0.0
        var benches: [BenchBoundary] = []
        for (index, leg) in legs.enumerated() {
            meters += leg.distance
            guard index < stops.count, stops[index].kind == .bench else { continue }
            let poi = stops[index].shared
            let arrival = preferences.departure.addingTimeInterval(meters / max(0.3, preferences.speedMetersPerSecond) + Double(index) * 300)
            let publicAccess: Bool? = poi?.restrictedAccess == true ? false : poi?.accessDescription == "public" ? true : nil
            benches.append(BenchBoundary(meters: meters, open: poi?.openAtArrival(arrival), publicAccess: publicAccess))
        }
        return .assess(distance: distance, limit: preferences.maximumRestGapMeters, benches: benches, allowUnknown: allowUnknown)
    }
}

/// Bounded search: add real pedestrian legs through mapped benches, then remeasure.
/// Unknown hours/access are never described as verified or guaranteed.
@MainActor enum RestAwareRouteBuilder {
    static func improve(_ initial: WalkingRouteOption, candidates: [DiscoveredPlace], preferences: RoutePreferences, allowUnknown: Bool) async -> WalkingRouteOption {
        var option = initial
        var rejected = Set<UUID>()
        let deadline = Date().addingTimeInterval(40)
        var checks = 0
        for _ in 0..<8 {
            guard !Task.isCancelled, Date() < deadline, checks < 12 else { break }
            let assessment = option.restAssessment(preferences, allowUnknown: allowUnknown)
            if assessment.status == .meets || assessment.status == .unverified { break }
            // Find the first interval that exceeds the preference, including the final leg.
            var lastBench = 0.0
            var total = 0.0
            var gap: (start: Double, end: Double)?
            for (index, leg) in option.legs.enumerated() {
                total += leg.distance
                let stop = index < option.stops.count ? option.stops[index] : nil
                let arrival = preferences.departure.addingTimeInterval(total / max(0.3, preferences.speedMetersPerSecond) + Double(index) * 300)
                let eligible = stop?.kind == .bench && stop?.shared?.restrictedAccess != true && stop?.shared?.openAtArrival(arrival) != false && (allowUnknown || (stop?.shared?.openAtArrival(arrival) == true && stop?.shared?.accessDescription == "public"))
                if eligible || index == option.legs.count - 1 {
                    if total - lastBench > preferences.maximumRestGapMeters + 0.5 { gap = (lastBench, total); break }
                    lastBench = total
                }
            }
            guard let gap else { break }
            let target = gap.start + preferences.maximumRestGapMeters * 0.78
            var choices: [(place: DiscoveredPlace, leg: Int, score: Double)] = []
            for place in candidates where place.kind == .bench && !rejected.contains(place.id) {
                guard place.shared?.restrictedAccess != true, place.shared?.unavailable != true, place.shared?.reportedUnavailable != true else { continue }
                let coordinate = Coordinate(place.item.placemark.coordinate.latitude, place.item.placemark.coordinate.longitude)
                var offset = 0.0
                for (index, leg) in option.legs.enumerated() {
                    let points = leg.polyline.walkingCoordinates
                    let length = WalkingGeometry.length(points)
                    if let projection = WalkingGeometry.project(coordinate, onto: points, near: 0, forwardAllowance: length), length > 0, projection.metersAway <= 150 {
                        let marker = offset + projection.metersAlong / length * leg.distance
                        let arrival = preferences.departure.addingTimeInterval(marker / max(0.3, preferences.speedMetersPerSecond) + Double(index) * 300)
                        let hours = place.shared?.openAtArrival(arrival)
                        if marker > gap.start + 15 && marker < min(gap.end - 15, gap.start + preferences.maximumRestGapMeters * 0.97), hours != false,
                           allowUnknown || (hours == true && place.shared?.accessDescription == "public") {
                            choices.append((place, index, abs(marker - target) + projection.metersAway * 2))
                        }
                    }
                    offset += leg.distance
                }
            }
            guard let choice = choices.min(by: { $0.score < $1.score }) else { break }
            rejected.insert(choice.place.id); checks += 1
            let oldLeg = option.legs[choice.leg]
            guard let start = oldLeg.polyline.walkingCoordinates.first, let end = oldLeg.polyline.walkingCoordinates.last else { break }
            let point = Coordinate(choice.place.item.placemark.coordinate.latitude, choice.place.item.placemark.coordinate.longitude)
            do {
                let arrival = preferences.departure.addingTimeInterval(option.legs.prefix(choice.leg).reduce(0) { $0 + $1.distance } / max(0.3, preferences.speedMetersPerSecond))
                let first = try await WalkingDirections.route(from: start, to: point, departure: arrival)
                try Task.checkCancellation()
                let second = try await WalkingDirections.route(from: point, to: end, departure: arrival.addingTimeInterval(first.distance / max(0.3, preferences.speedMetersPerSecond) + 300))
                try Task.checkCancellation()
                guard let firstStart = first.polyline.walkingCoordinates.first, let secondEnd = second.polyline.walkingCoordinates.last,
                      let firstEnd = first.polyline.walkingCoordinates.last, let secondStart = second.polyline.walkingCoordinates.first,
                      WalkingGeometry.distance(firstStart, start) <= 30, WalkingGeometry.distance(secondEnd, end) <= 30,
                      WalkingGeometry.distance(firstEnd, point) <= 30, WalkingGeometry.distance(secondStart, point) <= 30,
                      first.distance + second.distance <= oldLeg.distance + 400 else { continue }
                var legs = option.legs; legs.replaceSubrange(choice.leg...choice.leg, with: [first, second])
                var stops = option.stops; stops.insert(choice.place, at: choice.leg)
                let revised = WalkingRouteOption(id: UUID(), title: "With mapped rest stops", destinationName: option.destinationName, stops: stops, legs: legs)
                // Keep a detour only when it shortens the longest measured interval.
                // The chosen bench stays in `rejected` either way: once on the route it
                // must not be offered again as a new stop.
                let newGap = revised.restAssessment(preferences, allowUnknown: allowUnknown).longestGap
                if RestGapAssessment.detourImproves(previousLongestGap: assessment.longestGap, revisedLongestGap: newGap) {
                    option = revised
                }
            } catch { if Task.isCancelled { break } }
        }
        return option
    }
}
