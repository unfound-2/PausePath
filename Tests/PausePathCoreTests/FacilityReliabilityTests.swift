import XCTest
@testable import PausePathCore

final class FacilityReliabilityTests: XCTestCase {
    func schedule(_ json: String) throws -> FacilityHours { try JSONDecoder().decode(FacilityHours.self, from: Data(json.utf8)) }
    func date(_ text: String) -> Date { FacilityHours.date(text)! }
    func testExpectedArrivalAndClosingBoundary() throws {
        let hours = try schedule(#"{"timezone":"America/Chicago","weekly":[{"weekday":0,"open":"08:00","close":"18:00"}]}"#)
        XCTAssertEqual(hours.isOpen(at: date("2026-10-19T13:30:00Z")), true)
        XCTAssertEqual(hours.isOpen(at: date("2026-10-19T23:00:00Z")), false)
        XCTAssertEqual(hours.isOpen(at: date("2026-10-19T22:58:00Z"), duration: 300), false)
    }
    func testDateExceptionOverridesOvernight() throws {
        let hours = try schedule(#"{"timezone":"UTC","weekly":[{"weekday":0,"open":"22:00","close":"02:00"}],"exceptions":{"2026-10-20":[]}}"#)
        XCTAssertEqual(hours.isOpen(at: date("2026-10-19T23:00:00Z")), true)
        XCTAssertEqual(hours.isOpen(at: date("2026-10-20T01:00:00Z")), false)
    }
    func testUnsupportedRawHoursStayUnknown() throws {
        let hours = try schedule(#"{"raw":"Mo-Fr 08:00-18:00; PH off"}"#)
        XCTAssertNil(hours.isOpen(at: date("2026-10-19T13:30:00Z")))
    }
    func testMalformedNormalizedHoursStayUnknown() throws {
        let hours = try schedule(#"{"timezone":"UTC","weekly":[{"weekday":0,"open":"12:garbage:30","close":"18:00"}]}"#)
        XCTAssertNil(hours.isOpen(at: date("2026-10-19T13:30:00Z")))
    }
    func testClosedBenchDoesNotShortenFinalGap() {
        let result = RestGapAssessment.assess(distance: 1000, limit: 400, benches: [
            BenchBoundary(meters: 300, open: true, publicAccess: true),
            BenchBoundary(meters: 600, open: false, publicAccess: true)])
        XCTAssertEqual(result.longestGap, 700)
        XCTAssertEqual(result.status, .exceeds)
    }
    func testUnknownAndPrivateBenchesCannotBeCalledVerified() {
        let bench = BenchBoundary(meters: 300, open: nil, publicAccess: nil)
        XCTAssertEqual(RestGapAssessment.assess(distance: 600, limit: 350, benches: [bench]).status, .unverified)
        XCTAssertEqual(RestGapAssessment.assess(distance: 600, limit: 350, benches: [bench], allowUnknown: false).status, .exceeds)
        XCTAssertEqual(RestGapAssessment.assess(distance: 600, limit: 350, benches: [BenchBoundary(meters: 300, open: true, publicAccess: false)]).status, .exceeds)
    }
}
