import XCTest
@testable import PausePathCore

final class RouteRuleFixesTests: XCTestCase {
    // A 5 km route is "hard" on distance, but a 50-minute duration is only "moderate".
    private let input = RouteDifficultyInput(distanceMeters: 5_000, durationSeconds: 50 * 60)

    func testSwitchedOffFactorCannotRaiseTheRating() {
        let durationOnly = RouteDifficultyPreferences(includedFactors: [.duration])
        XCTAssertEqual(RouteDifficultyCalculator.assess(input, preferences: durationOnly).rating, .moderate)
    }

    func testSelectedFactorStillSetsTheFloor() {
        let both = RouteDifficultyPreferences(includedFactors: [.distance, .duration])
        XCTAssertEqual(RouteDifficultyCalculator.assess(input, preferences: both).rating, .hard)
    }

    func testNoSelectedFactorsGivesNoRating() {
        let none = RouteDifficultyPreferences(includedFactors: [])
        XCTAssertNil(RouteDifficultyCalculator.assess(input, preferences: none).rating)
    }

    func testHeatThreshold() {
        XCTAssertFalse(HeatGuidance.isHot(maximumFeelsLikeCelsius: nil))
        XCTAssertFalse(HeatGuidance.isHot(maximumFeelsLikeCelsius: .nan))
        XCTAssertFalse(HeatGuidance.isHot(maximumFeelsLikeCelsius: 31.9))
        XCTAssertTrue(HeatGuidance.isHot(maximumFeelsLikeCelsius: 32))
        XCTAssertTrue(HeatGuidance.isHot(maximumFeelsLikeCelsius: 38.5))
    }

    func testDetourMustShortenTheLongestGap() {
        XCTAssertTrue(RestGapAssessment.detourImproves(previousLongestGap: 700, revisedLongestGap: 420))
        XCTAssertFalse(RestGapAssessment.detourImproves(previousLongestGap: 700, revisedLongestGap: 700))
        XCTAssertFalse(RestGapAssessment.detourImproves(previousLongestGap: 700, revisedLongestGap: 700.4))
        XCTAssertFalse(RestGapAssessment.detourImproves(previousLongestGap: 700, revisedLongestGap: 699.5))
        XCTAssertFalse(RestGapAssessment.detourImproves(previousLongestGap: 700, revisedLongestGap: 900))
    }

    func testUnknownGapsAreHandledConservatively() {
        XCTAssertTrue(RestGapAssessment.detourImproves(previousLongestGap: nil, revisedLongestGap: 400))
        XCTAssertFalse(RestGapAssessment.detourImproves(previousLongestGap: 700, revisedLongestGap: nil))
        XCTAssertFalse(RestGapAssessment.detourImproves(previousLongestGap: nil, revisedLongestGap: nil))
    }
}
