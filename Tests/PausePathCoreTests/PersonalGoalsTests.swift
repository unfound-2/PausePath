import XCTest
@testable import PausePathCore

final class PersonalGoalsTests: XCTestCase {
    func testCalendarBoundsAndPartialJourneys() {
        let start = Date(timeIntervalSince1970: 1704067200)
        let end = start.addingTimeInterval(7 * 86400)
        let walks = [
            TrackedWalk(date: start, routeName: "Partial", distanceMeters: 1000, activeSeconds: 600, completed: false),
            TrackedWalk(date: start.addingTimeInterval(60), routeName: "Same day", distanceMeters: 500, activeSeconds: 300, completed: true),
            TrackedWalk(date: end, routeName: "Next week", distanceMeters: 9000, activeSeconds: 6000, completed: true)
        ]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(PersonalGoalProgress.total(metric: "distance", walks: walks, start: start, end: end), 1.5)
        XCTAssertEqual(PersonalGoalProgress.total(metric: "minutes", walks: walks, start: start, end: end), 15)
        XCTAssertEqual(PersonalGoalProgress.total(metric: "days", walks: walks, start: start, end: end, calendar: calendar), 1)
    }
    func testLegacyWalksDecodeWithoutOwnerOrKind() throws {
        let original = TrackedWalk(routeName: "Old walk", distanceMeters: 100, activeSeconds: 60, completed: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TrackedWalk.self, from: data)
        XCTAssertNil(decoded.ownerID); XCTAssertNil(decoded.activityKind)
        XCTAssertEqual(decoded.distanceMeters, 100)
    }
    func testRunningOwnershipRoundTrip() throws {
        let walk = TrackedWalk(routeName: "Run", distanceMeters: 1000, activeSeconds: 400, completed: true, activityKind: "Running", ownerID: "alice")
        let decoded = try JSONDecoder().decode(TrackedWalk.self, from: JSONEncoder().encode(walk))
        XCTAssertEqual(decoded.ownerID, "alice"); XCTAssertEqual(decoded.activityKind, "Running")
    }
    func testOptionalEnergyGoalPreservesExistingProfiles() throws {
        let oldProfile = try JSONSerialization.data(withJSONObject: [
            "goal": PersonalGoalProfile.generalFitness.rawValue,
            "weeklyWalkTarget": 4,
            "weeklyMinutesTarget": 90,
            "dailyRecapNotifications": false
        ])
        var profile = try JSONDecoder().decode(PausePathProfile.self, from: oldProfile)
        XCTAssertNil(profile.weeklyActiveEnergyTargetKcal)
        XCTAssertEqual(profile.weeklyWalkTarget, 4)
        profile.weeklyActiveEnergyTargetKcal = 500
        let saved = try JSONDecoder().decode(PausePathProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(saved.weeklyActiveEnergyTargetKcal, 500)
    }
}
