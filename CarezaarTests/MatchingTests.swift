import XCTest
@testable import Carezaar

final class MatchingTests: XCTestCase {
    private func match(active: Bool, client: Bool, caregiver: Bool, finished: String? = nil) -> Match {
        Match(id: 42, client: nil, caregiver: nil, clientReview: nil, caregiverReview: nil,
              createdAt: nil, finishedAt: finished, isClientAccepted: client,
              isCaregiverAccepted: caregiver, isActive: active, introduction: nil)
    }

    func testInactiveAcceptanceFlagsNeverProduceAnActiveMatch() {
        XCTAssertEqual(match(active: false, client: true, caregiver: true).stage, .pending)
        XCTAssertEqual(match(active: true, client: true, caregiver: true, finished: "2026-10-10").stage, .history)
    }

    func testRequestAndActiveStatesRemainDistinctForBothRoles() {
        let pending = match(active: false, client: true, caregiver: false)
        XCTAssertTrue(pending.awaitsPartner(for: .client))
        XCTAssertTrue(pending.awaitsResponse(from: .caregiver))
        XCTAssertFalse(pending.awaitsResponse(from: .client))
        let active = match(active: true, client: true, caregiver: true)
        XCTAssertEqual(active.stage, .active)
        XCTAssertFalse(active.awaitsResponse(from: .caregiver))
        XCTAssertFalse(active.awaitsPartner(for: .client))
    }

    func testActiveResponseWithoutRequestedPartnerCannotOpenSuccess() {
        XCTAssertFalse(match(active: true, client: true, caregiver: true).isActive(with: "other-person", for: .client))
        XCTAssertFalse(match(active: true, client: true, caregiver: true).isActive(with: "other-person", for: .caregiver))
    }

    func testMissingOrContradictoryProfileStateCannotAuthorizeActions() {
        XCTAssertNil(ProfileMatchState(status: nil, id: nil))
        XCTAssertNil(ProfileMatchState(status: "active", id: nil))
        XCTAssertNil(ProfileMatchState(status: "active", id: 0))
        XCTAssertNil(ProfileMatchState(status: "none", id: 2))
        XCTAssertNil(ProfileMatchState(status: "ended", id: 2))
        XCTAssertEqual(ProfileMatchState(status: "active", id: 2)?.status, .active)
        XCTAssertEqual(ProfileMatchState(status: "none", id: nil)?.status, ProfileMatchStatus.none)
    }

    func testMutationPreconditionsNeverInterchangeRelationshipActions() {
        XCTAssertEqual(MatchMutation.request.expectedStatus, .none)
        XCTAssertEqual(MatchMutation.withdraw.expectedStatus, .sent)
        XCTAssertEqual(MatchMutation.accept.expectedStatus, .received)
        XCTAssertEqual(MatchMutation.reject.expectedStatus, .received)
        XCTAssertEqual(MatchMutation.unmatch.expectedStatus, .active)
    }
    func testFailedWriteWithChangedProfileUsesStandardChangedPresentation() {
        let before = ProfileMatchState(status: "received", id: 41)!
        let accepted = ProfileMatchState(status: "active", id: 41)!
        let replacement = ProfileMatchState(status: "received", id: 42)!
        XCTAssertEqual(MatchFailureResolution.resolve(before: before, after: accepted), .changed)
        XCTAssertEqual(MatchFailureResolution.resolve(before: before, after: replacement), .changed)
    }

    func testFailedWriteWithoutVerifiableProfileUsesCheckWindow() {
        let before = ProfileMatchState(status: "sent", id: 41)!
        XCTAssertEqual(MatchFailureResolution.resolve(before: before, after: nil), .checkUnavailable)
    }

    func testFailedWriteWithUnchangedProfileRetainsOperationError() {
        let state = ProfileMatchState(status: "received", id: 41)!
        XCTAssertEqual(MatchFailureResolution.resolve(before: state, after: state), .originalError)
    }

}
