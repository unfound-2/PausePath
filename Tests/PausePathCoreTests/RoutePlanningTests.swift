import XCTest
@testable import PausePathCore

final class RoutePlanningTests: XCTestCase {
    let departure = Date(timeIntervalSince1970: 10000)
    func fixture(seatOffsets: [Double], windows: [OpeningWindow]? = nil, grade: Double? = 2) -> WalkingRoute {
        WalkingRoute(id: "test", name: "Test", meters: 1200, maximumGradePercent: grade, coordinates: [], facilities: seatOffsets.enumerated().map { index, offset in
            RouteFacility(id: "\(index)", name: "Seat", kind: .bench, coordinate: Coordinate(0, 0), metersFromStart: offset, hasSeating: true, openingWindows: windows)
        })
    }
    var preferences: RoutePreferences { var p = RoutePreferences(); p.departure = departure; return p }
    var open: [OpeningWindow] { [OpeningWindow(start: departure, end: departure.addingTimeInterval(2000))] }
    func testChecksEndGap() {
        let result = RoutePlanner.assess(fixture(seatOffsets: [300, 600], windows: open), preferences: preferences)
        XCTAssertFalse(result.matches)
        XCTAssertEqual(result.maximumRestGapMeters, 600)
    }
    func testExactGapAllowed() {
        XCTAssertTrue(RoutePlanner.assess(fixture(seatOffsets: [400, 800], windows: open), preferences: preferences).matches)
    }
    func testUnknownHoursCannotGuaranteeSeat() {
        XCTAssertFalse(RoutePlanner.assess(fixture(seatOffsets: [400, 800]), preferences: preferences).matches)
    }
    func testArrivalInsteadOfDepartureDeterminesOpening() {
        let hours = [OpeningWindow(start: departure, end: departure.addingTimeInterval(700))]
        XCTAssertFalse(RoutePlanner.assess(fixture(seatOffsets: [400, 800], windows: hours), preferences: preferences).matches)
    }
    func testUnknownSlopeDoesNotMatchFlat() {
        XCTAssertFalse(RoutePlanner.assess(fixture(seatOffsets: [400, 800], windows: open, grade: nil), preferences: preferences).matches)
    }
    func testSpeedChangesETAAndOpeningEligibility() {
        var p = preferences; p.speedMetersPerSecond = 0.5
        let result = RoutePlanner.assess(fixture(seatOffsets: [400, 800], windows: [OpeningWindow(start: departure, end: departure.addingTimeInterval(1200))]), preferences: p)
        XCTAssertEqual(result.durationSeconds, 2400)
        XCTAssertFalse(result.matches)
    }
    func testMissingRequestedFacilityRejectsCandidate() {
        var p = preferences; p.facilities.insert(.bathroom)
        XCTAssertFalse(RoutePlanner.assess(fixture(seatOffsets: [400, 800], windows: open), preferences: p).matches)
    }
    func testClosingBoundaryIsExclusive() {
        let facility = fixture(seatOffsets: [400], windows: open).facilities[0]
        XCTAssertEqual(facility.isOpen(at: departure.addingTimeInterval(2000)), false)
    }
    func testAdjustmentsRequireExplicitApplication() {
        var p = preferences
        let original = p.distanceMeters
        _ = WalkFeedback(routeName: "Test", manageability: .comfortable, facilitiesAvailable: true, note: "", activityID: nil)
        XCTAssertEqual(p.distanceMeters, original)
        RouteAdjustment.longer.apply(to: &p)
        XCTAssertEqual(p.distanceMeters, original + 200)
    }
    func testMappedBenchGapIncludesFinalLeg() {
        XCTAssertEqual(RoutePreviewMetrics.maximumMappedBenchGap(legDistances: [200, 300, 700], stopKinds: [.bench, .bench]), 700)
    }
    func testOtherAmenitiesDoNotImplySeating() {
        XCTAssertEqual(RoutePreviewMetrics.maximumMappedBenchGap(legDistances: [200, 300, 400], stopKinds: [.cafe, .bathroom]), 900)
    }
    func testDirectRouteGapIsFullRouteDistance() {
        XCTAssertEqual(RoutePreviewMetrics.maximumMappedBenchGap(legDistances: [1200], stopKinds: []), 1200)
    }
    func testMissingOrInvalidLegDataStaysUnknown() {
        XCTAssertNil(RoutePreviewMetrics.maximumMappedBenchGap(legDistances: [200], stopKinds: [.bench]))
        XCTAssertNil(RoutePreviewMetrics.maximumMappedBenchGap(legDistances: [.nan], stopKinds: []))
    }

}
