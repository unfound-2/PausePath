import XCTest
@testable import PausePathCore

final class DistanceDisplayTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    func testOneMileAndOneKilometer() {
        XCTAssertEqual(DistanceDisplayUnit.miles.distance(1609.344, locale: locale), "1.0 mi")
        XCTAssertEqual(DistanceDisplayUnit.kilometers.distance(1000, locale: locale), "1.0 km")
    }
    func testNearbyUsesSelectedSystem() {
        XCTAssertEqual(DistanceDisplayUnit.miles.nearby(30.48, locale: locale), "100 ft")
        XCTAssertEqual(DistanceDisplayUnit.miles.nearby(400, locale: locale), "0.2 mi")
        XCTAssertEqual(DistanceDisplayUnit.kilometers.nearby(400, locale: locale), "400 m")
        XCTAssertEqual(DistanceDisplayUnit.kilometers.nearby(1200, locale: locale), "1.2 km")
    }
    func testInvalidReadingsStayUnknown() {
        XCTAssertEqual(DistanceDisplayUnit.miles.distance(.nan), "Unknown")
        XCTAssertEqual(DistanceDisplayUnit.kilometers.nearby(-10), "Unknown")
        XCTAssertEqual(DistanceDisplayUnit.miles.nearby(.infinity), "Unknown")
    }
    func testZeroAndPrecision() {
        XCTAssertEqual(DistanceDisplayUnit.miles.distance(0, locale: locale), "0.0 mi")
        XCTAssertEqual(DistanceDisplayUnit.miles.distance(1000, digits: 2, locale: locale), "0.62 mi")
    }
}
