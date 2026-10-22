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
