import XCTest
@testable import PausePathCore

final class PersonalWalkingInsightsTests: XCTestCase {
    func testSampleTrendMatchesIllustrativeMath() throws {
        let result = WalkingTrendSummary.calculate(weeklyAverageMinutes: [12, 13, 14, 15, 16, 17, 18, 19])
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.lambdaMethod, .generalizedCrossValidation)
        XCTAssertEqual(try XCTUnwrap(result.slopeMinutesPerDayPerWeek), 1, accuracy: 0.001)
        XCTAssertEqual(result.baselineAverage, 13.5)
        XCTAssertEqual(result.recentAverage, 17.5)
        XCTAssertEqual(try XCTUnwrap(result.percentChange), 29.6296, accuracy: 0.001)
        XCTAssertEqual(result.totalObservedMinutes, 868)
        XCTAssertEqual(result.additionalMinutesOverBaseline, 112)
        XCTAssertGreaterThan(result.curve.count, 8)
        XCTAssertEqual(result.derivativePoints.count, 8)
        XCTAssertTrue(result.derivativePoints.allSatisfy { abs($0.minutesPerDay - 1) < 0.001 })
    }

    func testSyntheticHistoryRemainsSeparateButCanBeFitted() {
        let reference = Date(timeIntervalSince1970: 1_772_150_400)
        let sample = WalkingHistoryBuilder.sample(reference: reference, calendar: calendar)
        XCTAssertTrue(sample.allSatisfy { $0.source == .sample })
        let trend = WalkingTrendSummary.calculate(history: sample, reference: reference, calendar: calendar)
        XCTAssertEqual(trend.status, .ready)
        XCTAssertEqual(trend.observedPoints.count, 8)
        let personal = WalkingHistoryEntry(id: "local", source: .pausePath,
            start: reference.addingTimeInterval(-3600), end: reference,
            distanceMeters: 1000, completed: true)
        XCTAssertEqual(WalkingTrendSummary.calculate(history: sample + [personal], reference: reference, calendar: calendar).status, .invalid)
    }

    func testOverlappingHealthWorkoutDoesNotDoubleCountLocalWalk() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let walk = TrackedWalk(date: start.addingTimeInterval(1800), routeName: "Loop", distanceMeters: 1800,
                               activeSeconds: 1800, completed: true, startedAt: start)
        let feedback = WalkFeedback(routeName: "Loop", manageability: .aboutRight, facilitiesAvailable: nil,
                                    note: "", activityID: walk.id.uuidString)
        let workouts = [HealthWalkingRecord(id: "matching", start: start.addingTimeInterval(20), seconds: 1780, distanceMeters: 1750),
                        HealthWalkingRecord(id: "later", start: start.addingTimeInterval(4000), seconds: 1200, distanceMeters: 1200)]
        let history = WalkingHistoryBuilder.combine(tracked: [walk], health: workouts, feedback: [feedback])
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first { $0.source == .pausePath }?.feedback?.manageability, .aboutRight)
    }

    func testRankingEnforcesKnownSlopeAndRestGapButLabelsUnknown() {
        var preferences = RoutePreferences()
        preferences.facilities = [.bench]
        preferences.distanceMeters = 1200
        let steep = RouteFeatureSnapshot(id: "steep", distanceMeters: 1200, estimatedSeconds: 1200,
            maximumGradePercent: 8, longestRestGapMeters: 200, restStatus: .meets, facilityKinds: [.bench])
        let noSeats = RouteFeatureSnapshot(id: "gap", distanceMeters: 1200, estimatedSeconds: 1200,
            maximumGradePercent: 2, longestRestGapMeters: 1000, restStatus: .exceeds, facilityKinds: [.bench])
        let unknown = RouteFeatureSnapshot(id: "unknown", distanceMeters: 1200, estimatedSeconds: 1200,
            longestRestGapMeters: 200, restStatus: .unverified, facilityKinds: [.bench])
        let result = PersonalRouteRanker.rank([steep, noSeats, unknown], preferences: preferences, history: [])
        XCTAssertEqual(result.map(\.routeID), ["unknown"])
        XCTAssertTrue(result[0].provisional)
        XCTAssertTrue(result[0].unknownDetails.contains("slope"))
        XCTAssertTrue(result[0].unknownDetails.contains("rest-stop reliability"))
    }

    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    private func weeks(_ values: [Double?], offsets: [Int]? = nil, weights: [Double]? = nil) -> [WeeklyWalkingObservation] {
        let anchor = Date(timeIntervalSince1970: 1_767_571_200)
        return values.enumerated().map { index, value in
            let start = calendar.date(byAdding: .weekOfYear, value: offsets?[index] ?? index, to: anchor)!
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
            return WeeklyWalkingObservation(weekStart: start, weekEnd: end, minutesPerDay: value,
                validForFit: value != nil, weight: weights?[index] ?? (value == nil ? 0 : 1),
                coverage: value == nil ? .noRecordedSession : .observed, recordCount: value == nil ? 0 : 1)
        }
    }

    func testMissingAndIrregularWeeksPreserveCalendarSpacing() {
        let irregular = WalkingTrendSummary.calculate(observations: weeks([10, 12, 15, 16, 19, 20], offsets: [0, 1, 4, 6, 9, 10]), calendar: calendar)
        XCTAssertEqual(irregular.status, .ready)
        XCTAssertEqual(irregular.observedPoints.map(\.weekCoordinate), [0, 1, 4, 6, 9, 10])
        let missing = WalkingTrendSummary.calculate(observations: weeks([12, nil, 14, 15, 16, 17, 18, 19]), calendar: calendar)
        XCTAssertEqual(missing.status, .ready)
        XCTAssertEqual(missing.observedPoints.count, 7)
        XCTAssertNil(missing.baselineAverage)
        XCTAssertNil(missing.percentChange)
        XCTAssertNil(missing.additionalMinutesOverBaseline)
        XCTAssertEqual(missing.totalObservedMinutes, 111 * 7)
    }

    func testTooFewWeeksFallbackAndInvalidInputs() {
        let insufficient = WalkingTrendSummary.calculate(observations: weeks([2, nil, 4, nil, 6]), calendar: calendar)
        XCTAssertEqual(insufficient.status, .insufficient)
        XCTAssertNil(insufficient.lambda)
        let fallback = WalkingTrendSummary.calculate(observations: weeks([2, 4, 3, 6]), calendar: calendar)
        XCTAssertEqual(fallback.status, .ready)
        XCTAssertEqual(fallback.lambdaMethod, .fixedSmallSample)
        XCTAssertEqual(fallback.lambda, 1)
        XCTAssertNotNil(fallback.limitation)
        XCTAssertEqual(WalkingTrendSummary.calculate(observations: weeks([1, 2, 3, 4], weights: [1, -1, 1, 1]), calendar: calendar).status, .invalid)
        XCTAssertEqual(WalkingTrendSummary.calculate(observations: weeks([1, .nan, 3, 4]), calendar: calendar).status, .invalid)
        XCTAssertEqual(WalkingTrendSummary.calculate(observations: weeks([1, .infinity, 3, 4]), calendar: calendar).status, .invalid)
        XCTAssertEqual(WalkingTrendSummary.calculate(observations: weeks([1, 2, 3, 4], offsets: [0, 1, 1, 2]), calendar: calendar).status, .invalid)
    }

    func testZeroBaselineAndSlopeDirectionAndDeterminism() throws {
        let zero = WalkingTrendSummary.calculate(observations: weeks([0, 0, 0, 0, 1, 1, 1, 1]), calendar: calendar)
        XCTAssertEqual(zero.baselineAverage, 0)
        XCTAssertNil(zero.percentChange)
        XCTAssertEqual(zero.totalObservedMinutes, 28)
        let flat = WalkingTrendSummary.calculate(weeklyAverageMinutes: Array(repeating: 7, count: 8))
        XCTAssertEqual(try XCTUnwrap(flat.slopeMinutesPerDayPerWeek), 0, accuracy: 0.0001)
        let rising = WalkingTrendSummary.calculate(weeklyAverageMinutes: [1, 2, 3, 4, 5, 6, 7, 8])
        let falling = WalkingTrendSummary.calculate(weeklyAverageMinutes: [8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertGreaterThan(try XCTUnwrap(rising.slopeMinutesPerDayPerWeek), 0)
        XCTAssertLessThan(try XCTUnwrap(falling.slopeMinutesPerDayPerWeek), 0)
        let noisy = [4.0, 8, 5, 11, 9, 12, 10, 15]
        let first = WalkingTrendSummary.calculate(weeklyAverageMinutes: noisy)
        let second = WalkingTrendSummary.calculate(weeklyAverageMinutes: noisy)
        XCTAssertEqual(first.lambda, second.lambda)
        XCTAssertEqual(first.fittedPoints.map(\.minutesPerDay), second.fittedPoints.map(\.minutesPerDay))
    }

    private func route(_ id: String, distance: Double = 1200, grade: Double? = 2,
                       rest: RestGapAssessment.Status = .meets, gap: Double? = 200,
                       kinds: Set<FacilityKind> = [.bench], crossingCount: Int? = 1,
                       restPoints: Int? = 2, availability: Bool? = true, surface: String? = "paved") -> RouteFeatureSnapshot {
        RouteFeatureSnapshot(id: id, distanceMeters: distance, estimatedSeconds: distance,
            maximumGradePercent: grade, surface: surface, crossingCount: crossingCount,
            confirmedRestPoints: restPoints, requiredFacilitiesAvailable: availability,
            longestRestGapMeters: gap, restStatus: rest, facilityKinds: kinds)
    }

    func testCostComponentsAndWeightValidation() {
        var preferences = RoutePreferences()
        preferences.distanceMeters = 1200
        let result = PersonalRouteRanker.evaluate([route("known")], preferences: preferences, history: [])
        let candidate = result.suggestions[0]
        XCTAssertFalse(candidate.provisional)
        XCTAssertEqual(candidate.components.distance, 0, accuracy: 0.000001)
        XCTAssertEqual(candidate.components.grade, 0.15 * pow(2.0 / 3, 2), accuracy: 0.000001)
        XCTAssertEqual(candidate.components.crossings, 0.025, accuracy: 0.000001)
        XCTAssertEqual(candidate.components.restPoints, 0.05, accuracy: 0.000001)
        XCTAssertEqual(candidate.components.uncertainty, 0, accuracy: 0.000001)
        XCTAssertEqual(candidate.score, candidate.components.total)
        let bad = RouteCostWeights(distance: 0.4, grade: 0.2, crossings: 0.1, restPoints: 0.1, uncertainty: 0.1)
        XCTAssertFalse(bad.isValid)
        XCTAssertTrue(PersonalRouteRanker.evaluate([route("known")], preferences: preferences, history: [], weights: bad).invalidWeights)
        XCTAssertFalse(RouteCostWeights(distance: .nan, grade: 0, crossings: 0, restPoints: 0, uncertainty: 0).isValid)
    }

    func testHardConstraintsUnknownsAndNoFeasibleRoute() {
        var preferences = RoutePreferences()
        preferences.distanceMeters = 1200
        let excluded = [route("long", distance: 1600), route("steep", grade: 8),
                        route("no-bench", kinds: []), route("closed", availability: false),
                        route("gap", rest: .exceeds, gap: 800)]
        let noMatch = PersonalRouteRanker.evaluate(excluded, preferences: preferences, history: [])
        XCTAssertTrue(noMatch.suggestions.isEmpty)
        XCTAssertEqual(noMatch.excluded.count, 5)
        let unknown = route("unknown", grade: nil, rest: .unverified, crossingCount: nil,
                            restPoints: nil, availability: nil, surface: nil)
        let ranked = PersonalRouteRanker.evaluate([unknown, route("known", distance: 1300)], preferences: preferences, history: [])
        XCTAssertEqual(ranked.suggestions.map(\.routeID), ["known", "unknown"])
        XCTAssertTrue(ranked.suggestions[1].provisional)
        XCTAssertEqual(ranked.suggestions[1].dataCompleteness, 0)
        XCTAssertEqual(ranked.suggestions[1].unknownDetails.count, 5)
    }

    func testDifficultFeedbackExcludedAndTiesAreStable() {
        var preferences = RoutePreferences()
        preferences.distanceMeters = 1200
        preferences.facilities = []
        let start = Date(timeIntervalSince1970: 1_000_000)
        let accepted = (0..<3).map { index in
            WalkingHistoryEntry(id: "ok-\(index)", source: .pausePath, start: start.addingTimeInterval(Double(index) * 3600),
                end: start.addingTimeInterval(Double(index + 1) * 3600), distanceMeters: 1500, completed: true)
        }
        let difficult = WalkingHistoryEntry(id: "hard", source: .pausePath, start: start.addingTimeInterval(20_000),
            end: start.addingTimeInterval(21_000), distanceMeters: 900, completed: true,
            feedback: WalkFeedback(routeName: "Hard", manageability: .difficult, facilitiesAvailable: nil, note: "", activityID: nil))
        let result = PersonalRouteRanker.evaluate([route("b"), route("a")], preferences: preferences,
                                                  history: accepted + [difficult])
        XCTAssertEqual(result.targetDistanceMeters, 1500)
        XCTAssertEqual(result.suggestions.map(\.routeID), ["a", "b"])
    }
}
