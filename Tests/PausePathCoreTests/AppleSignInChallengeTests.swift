import XCTest
@testable import PausePathCore

final class AppleSignInChallengeTests: XCTestCase {
    func testFreshCryptographicChallengesAndSHA256() throws {
        let first = try AppleSignInChallenge()
        let second = try AppleSignInChallenge()
        XCTAssertEqual(first.nonce.count, 43)
        XCTAssertEqual(first.hashedNonce.count, 64)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.nonce, first.hashedNonce)
        XCTAssertTrue(first.accepts(state: first.state))
        XCTAssertFalse(first.accepts(state: second.state))
        XCTAssertFalse(first.accepts(state: nil))
    }
    func testExpiredAndFutureChallengesAreRejected() throws {
        let now = Date()
        let challenge = try AppleSignInChallenge(now: now)
        XCTAssertTrue(challenge.accepts(state: challenge.state, now: now.addingTimeInterval(599)))
        XCTAssertFalse(challenge.accepts(state: challenge.state, now: now.addingTimeInterval(600)))
        XCTAssertFalse(challenge.accepts(state: challenge.state, now: now.addingTimeInterval(-1)))
    }
}
