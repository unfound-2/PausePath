import XCTest
@testable import PausePathCore

final class PathMilestoneTests: XCTestCase {
    private func walk(_ day: Int, meters: Double = 1000, completed: Bool = true) -> TrackedWalk {
        TrackedWalk(date: Date(timeIntervalSince1970: Double(day) * 86400),
                    routeName: "River path", distanceMeters: meters, activeSeconds: 900, completed: completed)
    }
    func testOldHistoryStillDecodesWithoutJourneyOrSteps() throws {
        let old = """
        {"id":"8AFAC9A2-B635-4CF7-96E4-C09015B1F76F","date":100,"routeName":"Old path","distanceMeters":900,"activeSeconds":600,"completed":true}
        """
        let decoded = try JSONDecoder().decode(TrackedWalk.self, from: Data(old.utf8))
        XCTAssertNil(decoded.journeySegments)
        XCTAssertNil(decoded.steps)
        XCTAssertNil(decoded.startedAt)
        XCTAssertEqual(decoded.distanceMeters, 900)
    }
    func testJourneySegmentsAndStepsSurviveRelaunch() throws {
        let item = TrackedWalk(routeName: "River", distanceMeters: 2000, activeSeconds: 1800, completed: true,
            steps: 2310, startedAt: Date(timeIntervalSince1970: 100),
            journeySegments: [[Coordinate(41, -87), Coordinate(41.001, -87)], [Coordinate(41.002, -87)]])
        let result = try JSONDecoder().decode(TrackedWalk.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(result.journeySegments, item.journeySegments)
        XCTAssertEqual(result.steps, 2310)
        XCTAssertEqual(result.startedAt, item.startedAt)
    }
    func testExactly18UniqueBadgesWithNoUnearnedBaseline() {
        let badges = PathMilestones(walks: []).badges
        XCTAssertEqual(badges.count, 18)
        XCTAssertEqual(Set(badges.map(\.id)).count, 18)
        XCTAssertFalse(badges.contains(where: \.earned))
    }
    func testPRRequiresBeatingPriorCompletedDistanceNotTieOrFirstWalk() {
        let first = walk(1), tie = walk(2), longer = walk(3, meters: 1500)
        let unfinished = walk(4, meters: 9000, completed: false)
        let milestones = PathMilestones(walks: [unfinished, longer, first, tie])
        XCTAssertEqual(milestones.recordIDs, [longer.id])
        XCTAssertEqual(milestones.longest, 1500)
        XCTAssertEqual(milestones.distance, 3500)
        XCTAssertTrue(milestones.badges.first { $0.id == "pr-1" }!.earned)
        XCTAssertFalse(milestones.badges.first { $0.id == "pr-5" }!.earned)
    }
    func testInvalidAndEmptySessionsDoNotEarnBadges() {
        var invalid = walk(1)
        invalid.distanceMeters = .infinity
        var missingTime = walk(2)
        missingTime.activeSeconds = .nan
        let milestones = PathMilestones(walks: [invalid, missingTime, walk(3, meters: 0), walk(4, completed: false)])
        XCTAssertEqual(milestones.walks.count, 0)
    }
    func testTrendUsesEqualCompletedDaysExcludingTodayAndOlderRecords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 20 * 86400 + 3600)
        let data = [walk(20, meters: 9000), walk(19), walk(13), walk(12, meters: 500), walk(6, meters: 500), walk(5, meters: 7000)]
        let totals = PathTrend.distance(walks: data, days: 7, now: now, calendar: calendar)
        XCTAssertEqual(totals.current, 2000)
        XCTAssertEqual(totals.previous, 1000)
    }
}
