import XCTest
@testable import PausePathCore

final class CommunitySubmissionTests: XCTestCase {
    func testAcceptsFormattedCodesAndPausePathInvites() {
        XCTAssertEqual(CommunityInvite.normalizedCode(" abcd - 2345 "), "ABCD2345")
        XCTAssertEqual(CommunityInvite.normalizedCode("pausepath://community/join?code=abcd2345"), "ABCD2345")
        XCTAssertTrue(CommunityInvite.isValid("ABCD2345"))
        XCTAssertFalse(CommunityInvite.isValid(CommunityInvite.normalizedCode("https://example.org/join?code=ABCD2345")))
        XCTAssertFalse(CommunityInvite.isValid("ABC!"))
    }
    func testRetryAndRestoredDraftKeepRequestIdentity() throws {
        var draft = CommunitySubmissionDraft()
        draft.prepare(ownerID: "user-a", joining: false, name: " Weekend walkers ", code: "", username: "Walker")
        let request = draft.requestID
        draft.prepare(ownerID: "user-a", joining: false, name: "Weekend walkers", code: "unused", username: "Walker")
        XCTAssertEqual(draft.requestID, request)
        let restored = try JSONDecoder().decode(CommunitySubmissionDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(restored, draft)
    }
    func testChangedPayloadOrAccountGetsNewRequestIdentity() {
        var draft = CommunitySubmissionDraft()
        draft.prepare(ownerID: "user-a", joining: true, name: "", code: "ABCD2345", username: "Walker")
        let first = draft.requestID
        draft.prepare(ownerID: "user-a", joining: true, name: "", code: "WXYZ6789", username: "Walker")
        XCTAssertNotEqual(first, draft.requestID)
        let second = draft.requestID
        draft.prepare(ownerID: "user-b", joining: true, name: "", code: "WXYZ6789", username: "Walker")
        XCTAssertNotEqual(second, draft.requestID)
    }
}

final class GoalSubmissionTests: XCTestCase {
    func testRequestIdentitySurvivesSavedRetry() throws {
        var draft = GoalSubmissionDraft()
        draft.prepare(ownerID: "one", scope: "group", name: " Walk ", metric: "walks", target: 3, shared: true)
        let original = draft.requestID
        var restored = try JSONDecoder().decode(GoalSubmissionDraft.self, from: JSONEncoder().encode(draft))
        restored.prepare(ownerID: "one", scope: "group", name: "Walk", metric: "walks", target: 3, shared: true)
        XCTAssertEqual(restored.requestID, original)
        restored.prepare(ownerID: "one", scope: "group", name: "Walk", metric: "walks", target: 4, shared: true)
        XCTAssertNotEqual(restored.requestID, original)
    }
    func testAccountAndGroupIsolation() {
        var draft = GoalSubmissionDraft()
        draft.prepare(ownerID: "one", scope: "group", name: "Walk", metric: "walks", target: 3, shared: false)
        let first = draft.requestID
        draft.prepare(ownerID: "two", scope: "group", name: "Walk", metric: "walks", target: 3, shared: false)
        XCTAssertNotEqual(draft.requestID, first)
        let second = draft.requestID
        draft.prepare(ownerID: "two", scope: "other", name: "Walk", metric: "walks", target: 3, shared: false)
        XCTAssertNotEqual(draft.requestID, second)
    }
}

final class CommunityPresentationTests: XCTestCase {
    func testGoalStateSeparatesCompletedAndArchived() {
        XCTAssertEqual(CommunityGoalState.classify(archived: false, progress: 2, target: 3), .active)
        XCTAssertEqual(CommunityGoalState.classify(archived: false, progress: 3, target: 3), .completed)
        XCTAssertEqual(CommunityGoalState.classify(archived: false, progress: 4, target: 3), .completed)
        XCTAssertEqual(CommunityGoalState.classify(archived: true, progress: 4, target: 3), .archived)
    }
    func testSectionFreshnessHasBoundedLifetime() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(CommunityFreshness.shouldRefresh(lastLoaded: nil, now: now))
        XCTAssertFalse(CommunityFreshness.shouldRefresh(lastLoaded: now.addingTimeInterval(-59), now: now))
        XCTAssertTrue(CommunityFreshness.shouldRefresh(lastLoaded: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(CommunityFreshness.shouldRefresh(lastLoaded: now.addingTimeInterval(10), now: now))
    }
}
