import XCTest
@testable import PausePathCore

final class RouteStopOrderingTests: XCTestCase {
    func testOrdersWaypointsAndRetainsIndividualAlternatives() {
        let plans = RouteStopOrdering.plans(start: Coordinate(0, 0), end: Coordinate(0, 0.1),
                                            stops: [Coordinate(0, 0.08), Coordinate(0, 0.02), Coordinate(0, 0.05)])
        XCTAssertEqual(plans, [[], [1, 2, 0], [1], [2], [0]])
    }
    func testEndpointStopsDoNotInvalidateWholePlan() {
        XCTAssertEqual(RouteStopOrdering.plans(start: Coordinate(0, 0), end: Coordinate(0, 0.1),
                                               stops: [Coordinate(0, 0), Coordinate(0, 0.1), Coordinate(0, 0.05)]), [[], [2]])
    }
    func testNoStopsStillProvidesDirectPlan() {
        XCTAssertEqual(RouteStopOrdering.plans(start: Coordinate(1, 1), end: Coordinate(1, 2), stops: []), [[]])
    }
}
