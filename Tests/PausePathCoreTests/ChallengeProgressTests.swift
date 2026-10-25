import XCTest
@testable import PausePathCore

final class ChallengeProgressTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1000)
    let end = Date(timeIntervalSince1970: 2000)
    func walk(_ date: Double, completed: Bool = true, route: String? = nil) -> TrackedWalk {
        TrackedWalk(date: Date(timeIntervalSince1970: date), routeName: "Same display name",
                    distanceMeters: 500, activeSeconds: 300, completed: completed, routeIdentity: route)
    }
    func testOnlyCompletedWalksInChallengeWindowCount() {
        let walks = [walk(900), walk(1000), walk(1500), walk(1600, completed: false), walk(2100)]
        XCTAssertEqual(ChallengeProgressCalculator.total(metric: "walks", walks: walks, from: start, until: end), 2)
        XCTAssertEqual(ChallengeProgressCalculator.total(metric: "distance_km", walks: walks, from: start, until: end), 1)
        XCTAssertEqual(ChallengeProgressCalculator.total(metric: "minutes", walks: walks, from: start, until: end), 10)
    }
    func testPreferredDistanceProgressUsesTheLongestSingleWalk() {
        let walks = [walk(1100), walk(1200)]
        XCTAssertEqual(ChallengeProgressCalculator.total(metric: "single_distance_km", walks: walks, from: start, until: end), 0.5)

        var longerWalk = walk(1300)
        longerWalk.distanceMeters = 1_200
        XCTAssertEqual(ChallengeProgressCalculator.total(metric: "single_distance_km", walks: walks + [longerWalk], from: start, until: end), 1.2)
    }
    func testNewRoutesExcludePreviousRoutesDuplicatesAndMissingIdentities() {
        let walks = [walk(900, route: "old"), walk(1000, route: "old"),
                     walk(1100, route: "new"), walk(1200, route: "new"), walk(1300),
                     walk(1400, completed: false, route: "unfinished")]
        XCTAssertEqual(ChallengeProgressCalculator.total(metric: "new_routes", walks: walks, from: start, until: end), 1)
    }
    func testAnUnfinishedEarlierAttemptDoesNotExcludeANewRoute() {
        let walks = [walk(900, completed: false, route: "route"), walk(1200, route: "route")]
        XCTAssertEqual(ChallengeProgressCalculator.total(metric: "new_routes", walks: walks, from: start, until: end), 1)
    }
    func testUnknownMetricAndInvalidMeasurementsDoNotUploadBadTotals() {
        var activity = walk(1200)
        activity.distanceMeters = .infinity
        activity.activeSeconds = .nan
        XCTAssertEqual(ChallengeProgressCalculator.total(metric: "distance_km", walks: [activity], from: start, until: end), 0)
        XCTAssertEqual(ChallengeProgressCalculator.total(metric: "minutes", walks: [activity], from: start, until: end), 0)
        XCTAssertEqual(ChallengeProgressCalculator.total(metric: "unknown", walks: [activity], from: start, until: end), 0)
    }
    func testRewardsPersistAcrossDeckRefreshesAndRelaunches() throws {
        var ledger = ChallengeRewardLedger()
        XCTAssertTrue(ledger.claim("Complete a walk", week: "2026-42"))
        XCTAssertFalse(ledger.claim("Complete a walk", week: "2026-42"))
        let data = try JSONEncoder().encode(ledger)
        ledger = try JSONDecoder().decode(ChallengeRewardLedger.self, from: data)
        XCTAssertFalse(ledger.claim("Complete a walk", week: "2026-42"))
        XCTAssertTrue(ledger.claim("Another goal", week: "2026-42"))
        XCTAssertTrue(ledger.claim("Complete a walk", week: "2026-43"))
    }
}
