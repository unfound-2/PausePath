import XCTest
@testable import PausePathCore

final class PersonalWalkingInsightsTests: XCTestCase {
    func testSampleTrendMatchesIllustrativeMath() throws {
        let result = try XCTUnwrap(WalkingTrendSummary.calculate(weeklyAverageMinutes: [12, 13, 14, 15, 16, 17, 18, 19]))
        XCTAssertEqual(result.slopeMinutesPerDayPerWeek, 1, accuracy: 0.0001)
        XCTAssertEqual(result.baselineAverage, 13.5)
        XCTAssertEqual(result.recentAverage, 17.5)
        XCTAssertEqual(try XCTUnwrap(result.percentChange), 29.6296, accuracy: 0.001)
        XCTAssertEqual(result.totalMinutes, 868)
        XCTAssertEqual(result.additionalMinutesOverBaseline, 112)
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
}
