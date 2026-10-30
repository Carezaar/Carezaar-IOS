import XCTest
@testable import Carezaar

final class MatchingTests: XCTestCase {
    func testAllMatchMutationsRejectSupersededAccountBeforeTransport() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "original", refreshToken: "original-refresh"))
        let original = tokens.generation
        tokens.save(Session(accessToken: "new-account", refreshToken: "new-refresh"))
        var requests = 0
        StubHTTP.handler = { _ in requests += 1; return (204, Data()) }
        let service = UserService(client: APIClient(tokens: tokens, session: StubHTTP.session()))
        for action in [MatchMutation.request, .accept, .reject, .withdraw, .unmatch] {
            do {
                switch action {
                case .request: _ = try await service.requestMatch(partnerId: "owned-peer", ifGeneration: original)
                case .accept: _ = try await service.acceptMatch(id: 42, ifGeneration: original)
                case .reject: try await service.rejectMatch(id: 42, ifGeneration: original)
                case .withdraw: try await service.withdrawMatch(id: 42, ifGeneration: original)
                case .unmatch: _ = try await service.breakMatch(id: 42, ifGeneration: original)
                }
                XCTFail("Superseded match intent must cancel before dispatch")
            } catch is CancellationError { }
            catch { XCTFail("Unexpected superseded-intent error") }
        }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(tokens.accessToken, "new-account")
    }

    @MainActor
    func testLostFavoriteResponseReadsRelevantProfileAndReflectsSavedStateWithoutAnotherWrite() async throws {
        var methods: [String] = []
        StubHTTP.handler = { request in
            let method = request.httpMethod ?? ""; methods.append(method)
            if method == "POST" {
                XCTAssertEqual(request.url?.path, "/api/users/bookmarks")
                throw URLError(.networkConnectionLost)
            }
            XCTAssertEqual(request.url?.path, "/api/clients/caregivers/profile-fixture")
            return (200, Data(#"{"result":{"id":"profile-fixture","user":{"id":"user-fixture","role":"caregiver","is_favorite":true}}}"#.utf8))
        }
        let partner = User(id: "user-fixture", countryId: 1, genderId: nil, role: .caregiver,
                           email: "fixture@example.invalid", firstName: nil, lastName: nil, photo: nil,
                           bio: nil, dateOfBirth: nil, status: .verified, isFavorite: false)
        let coordinator = FavoriteMutationCoordinator(service: UserService(client: APIClient(tokens: FixtureTokens(), session: StubHTTP.session())))
        let saved = try await coordinator.change(partner: partner, to: true, profileId: "profile-fixture", accountId: "account-fixture")
        XCTAssertEqual(saved.id, "user-fixture")
        XCTAssertTrue(saved.isFavorite)
        XCTAssertEqual(methods, ["POST", "GET"], "An uncertain favorite write is reconciled, never automatically repeated")
    }

    @MainActor
    func testMissingFavoriteFlagCannotConfirmUnknownRemovalOrAllowSecondMutation() async {
        var writes = 0, reads = 0
        StubHTTP.handler = { request in
            if request.httpMethod == "DELETE" {
                writes += 1
                throw URLError(.networkConnectionLost)
            }
            reads += 1
            return (200, Data(#"{"result":{"id":"profile-fixture","user":{"id":"user-fixture","role":"caregiver"}}}"#.utf8))
        }
        let partner = User(id: "user-fixture", countryId: 1, genderId: nil, role: .caregiver,
                           email: "fixture@example.invalid", firstName: nil, lastName: nil, photo: nil,
                           bio: nil, dateOfBirth: nil, status: .verified, isFavorite: true)
        let coordinator = FavoriteMutationCoordinator(service: UserService(client: APIClient(tokens: FixtureTokens(), session: StubHTTP.session())))
        for _ in 0..<2 {
            do {
                _ = try await coordinator.change(partner: partner, to: false, profileId: "profile-fixture", accountId: "account-fixture")
                XCTFail("Missing saved favorite state cannot confirm an uncertain removal")
            } catch { }
        }
        XCTAssertEqual(writes, 1, "A later tap may reconcile but must not repeat the unknown mutation")
        XCTAssertEqual(reads, 2)
    }

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
    func testClearingAMatchLeavesNoRelationshipOnTheProfile() throws {
        let json = #"{"id":"g1","user":{"id":"c1","role":"caregiver","is_favorite":false},"is_match":true,"match_status":"active","match_id":41}"#
        let profile = try JSONDecoder().decode(CaregiverFull.self, from: Data(json.utf8))
        XCTAssertEqual(profile.matchState?.status, .active)
        let cleared = profile.with(matchStatus: "none", matchId: nil)
        XCTAssertEqual(cleared.matchState?.status, ProfileMatchStatus.none)
        XCTAssertNil(cleared.matchState?.id)
        XCTAssertFalse(cleared.isMatch)
        XCTAssertEqual(profile.with(matchStatus: "sent", matchId: 42).matchState?.id, 42)
    }

}
