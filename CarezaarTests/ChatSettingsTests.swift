import XCTest
@testable import Carezaar

final class ChatSettingsTests: XCTestCase {
    @MainActor
    func testRejectedSendAndFailedRenewalNeverBecomeUncertainDelivery() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "original", refreshToken: "original-refresh"))
        var methods: [String] = []
        StubHTTP.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.url!.lastPathComponent == "refresh" { return (503, Data(#"{"message":"Service unavailable"}"#.utf8)) }
            if request.httpMethod == "POST" { return (403, Data(#"{"message":"Expired access"}"#.utf8)) }
            return (200, Data(#"{"result":{"id":42,"messages":[]}}"#.utf8))
        }
        let coordinator = ChatSendCoordinator(service: UserService(client: APIClient(tokens: tokens, session: StubHTTP.session())))
        do { _ = try await coordinator.submit(chatId: 42, text: "Retain unsent draft", parentId: nil); XCTFail("Renewal failed") }
        // Parity v3 Q1: an HTTP error answer to renewal ends the session.
        catch { XCTAssertEqual(Feedback.message(error), Feedback.message(APIError.unauthenticated(""))) }
        XCTAssertEqual(methods, ["POST", "PUT"], "An explicitly rejected Send needs no delivery reconciliation read")
        XCTAssertFalse(coordinator.uncertain)
        XCTAssertFalse(tokens.hasSession)
    }

    @MainActor
    func testCancelledOldAccountSendNeverReconcilesUsingNewAccount() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        var methods: [String] = []
        StubHTTP.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                tokens.save(Session(accessToken: "new-account", refreshToken: "new-refresh"))
                throw URLError(.networkConnectionLost)
            }
            return (200, Data(#"{"result":{"id":42,"messages":[{"id":101,"message":"Old draft","is_from_caregiver":false}]}}"#.utf8))
        }
        let coordinator = ChatSendCoordinator(service: UserService(client: APIClient(tokens: tokens, session: StubHTTP.session())))
        do {
            _ = try await coordinator.submit(chatId: 42, text: "Old draft", parentId: nil)
            XCTFail("Old account Send must not complete using a new account read")
        } catch is CancellationError { }
        catch { XCTFail("Superseded Send must cancel") }
        XCTAssertEqual(methods, ["POST"])
        XCTAssertFalse(coordinator.uncertain)
        XCTAssertEqual(tokens.accessToken, "new-account")
    }

    func testViewportPreferenceDoesNotEraseMeasuredGeometryWithDefaultNil() {
        let measured = ChatViewportMetrics(contentBottom: 700, viewportHeight: 700)
        var value: ChatViewportMetrics?
        ChatViewportPreference.reduce(value: &value) { nil }
        XCTAssertNil(value)
        ChatViewportPreference.reduce(value: &value) { measured }
        XCTAssertEqual(value, measured)
        ChatViewportPreference.reduce(value: &value) { nil }
        ChatViewportPreference.reduce(value: &value) { nil }
        XCTAssertEqual(value, measured, "A sibling without geometry cannot erase the transcript's measurement")
        let resized = ChatViewportMetrics(contentBottom: 700, viewportHeight: 430)
        ChatViewportPreference.reduce(value: &value) { resized }
        XCTAssertEqual(value, resized)
    }

    func testKeyboardResizeRetainsBottomIntentUntilGeometrySettles() {
        var position = ChatViewportPosition()
        XCTAssertFalse(position.observe(contentBottom: 700, viewportHeight: 700))
        XCTAssertTrue(position.observe(contentBottom: 700, viewportHeight: 500))
        XCTAssertTrue(position.isAtBottom)
        XCTAssertTrue(position.observe(contentBottom: 700, viewportHeight: 430))
        XCTAssertTrue(position.isAtBottom, "Intermediate keyboard geometry cannot discard pending bottom intent")
        XCTAssertFalse(position.observe(contentBottom: 430, viewportHeight: 430))
        XCTAssertTrue(position.isAtBottom)
        XCTAssertFalse(position.observe(contentBottom: 650, viewportHeight: 430), "Content alone cannot start a resize scroll")
        XCTAssertFalse(position.isAtBottom)
    }

    func testOlderReaderAndUserDragNeverAcquireResizeBottomIntent() {
        var position = ChatViewportPosition()
        XCTAssertFalse(position.observe(contentBottom: 1100, viewportHeight: 700))
        XCTAssertFalse(position.isAtBottom)
        XCTAssertFalse(position.observe(contentBottom: 1100, viewportHeight: 430))
        XCTAssertFalse(position.observe(contentBottom: 1300, viewportHeight: 430))
        XCTAssertFalse(position.isAtBottom)
        XCTAssertFalse(position.observe(contentBottom: 430, viewportHeight: 430))
        XCTAssertTrue(position.observe(contentBottom: 430, viewportHeight: 300))
        position.beganUserScroll()
        XCTAssertFalse(position.isAtBottom)
        XCTAssertFalse(position.observe(contentBottom: 500, viewportHeight: 260), "A user drag cancels pending resize following")
        XCTAssertFalse(position.isAtBottom)
    }

    func testIntroductionPreviewPreservesWholeFirstLine() {
        let first = "Hello. I can help! " + String(repeating: "care ", count: 30)
        XCTAssertEqual(ManageMatchesView.preview(first + "\nSecond line"), first)
        XCTAssertEqual(ManageMatchesView.preview("First\r\nSecond"), "First")
        XCTAssertEqual(ManageMatchesView.preview("  مرحبا؟ 🙂\nNext"), "  مرحبا؟ 🙂")
        XCTAssertNil(ManageMatchesView.preview(nil))
        XCTAssertNil(ManageMatchesView.preview(""))
    }
    func testBottomDetectionPreservesReadingOlderMessages() {
        XCTAssertTrue(ChatScrollPosition.isAtBottom(contentBottom: 680, viewportHeight: 700))
        XCTAssertTrue(ChatScrollPosition.isAtBottom(contentBottom: 100, viewportHeight: 700))
        XCTAssertTrue(ChatScrollPosition.isAtBottom(contentBottom: 720, viewportHeight: 700))
        XCTAssertFalse(ChatScrollPosition.isAtBottom(contentBottom: 900, viewportHeight: 700))
        XCTAssertFalse(ChatScrollPosition.isAtBottom(contentBottom: .infinity, viewportHeight: 700))
        XCTAssertFalse(ChatScrollPosition.isAtBottom(contentBottom: 0, viewportHeight: 0))
    }

    func testEndedNotificationShowsPartnerProfileForBothRoles() {
        XCTAssertEqual(NotificationsView.destination(for: notification(role: .caregiver), code: "unmatch"),
                       .caregiverDetails(caregiverId: "partner"))
        XCTAssertEqual(NotificationsView.destination(for: notification(role: .client), code: "unmatch"),
                       .clientDetails(clientId: "partner"))
    }

    func testAcceptedNotificationOpensMatchAndMissingTargetHasSafeFallback() {
        XCTAssertEqual(NotificationsView.destination(for: notification(role: .client), code: "match_accept"),
                       .matched(partner: .client(id: "partner")))
        let missing = AppNotification(id: 1, user: nil, partner: nil, chat: nil, subjectId: 1,
                                      createdAt: "2026-10-10T12:30:00+03:00", seenAt: nil)
        for code in ["match", "match_accept", "unmatch", "chat_new", ""] {
            XCTAssertNil(NotificationsView.destination(for: missing, code: code))
        }
    }

    func testChatNotificationUsesChatRatherThanPartnerProfile() {
        let chat = ChatBrief(id: 42, client: nil, caregiver: nil, updatedAt: nil,
                             newMessageCount: 1, lastMessage: "Hello", isSeen: false)
        let n = AppNotification(id: 1, user: nil, partner: nil, chat: chat, subjectId: 1,
                                createdAt: nil, seenAt: nil)
        XCTAssertEqual(NotificationsView.destination(for: n, code: "chat_new"), .chat(chatId: 42))
    }

    private func notification(role: UserRole) -> AppNotification {
        let partner = User(id: "partner", countryId: 1, genderId: nil, role: role, email: "qa@example.invalid",
                           firstName: "QA", lastName: "Partner", photo: nil, bio: nil, dateOfBirth: nil,
                           status: .verified, isFavorite: false)
        return AppNotification(id: 1, user: nil, partner: partner, chat: nil, subjectId: 1,
                               createdAt: "2026-10-10 12:30", seenAt: nil)
    }

    /// October 13 supersedes the old blanket uncertain-send blocking flow.
    /// Historical October 12 results remain in the existing QA reports.
    @MainActor
    func testLostMessageResponseReadsConversationAndConfirmsStoredMessageWithoutSecondPost() async throws {
        var requests: [String] = []
        StubHTTP.handler = { request in
            let method = request.httpMethod ?? ""
            requests.append(method)
            XCTAssertEqual(request.url?.path, "/api/users/chats/42")
            if method == "POST" { throw URLError(.networkConnectionLost) }
            return (200, Data(#"{"result":{"id":42,"messages":[{"id":101,"message":"Keep my draft","is_from_caregiver":false}]}}"#.utf8))
        }
        let coordinator = ChatSendCoordinator(service: UserService(client: APIClient(tokens: FixtureTokens(), session: StubHTTP.session())))
        let reconciled = try await coordinator.submit(chatId: 42, text: "Keep my draft", parentId: nil)
        XCTAssertEqual(reconciled.messages.map(\.id), [101])
        XCTAssertEqual(requests, ["POST", "GET"], "Read only after ambiguity, and never replay POST")
        XCTAssertEqual(ChatDraftReconciliation.afterAcknowledgedSend(current: "Keep my draft", submitted: "Keep my draft"), "")
    }

    @MainActor
    func testProvenPreconnectionFailureAllowsDeliberateSameDraftSendAfterRecovery() async throws {
        var recovered = false
        var attempts = 0, acknowledgements = 0, reads = 0
        StubHTTP.handler = { request in
            if request.httpMethod == "GET" {
                reads += 1
                return (200, Data(#"{"result":{"id":42,"messages":[]}}"#.utf8))
            }
            attempts += 1
            guard recovered else { throw URLError(.cannotConnectToHost) }
            acknowledgements += 1
            return (200, Data(#"{"result":{"id":42,"messages":[{"id":101,"message":"Retry my draft","is_from_caregiver":false}]}}"#.utf8))
        }
        let coordinator = ChatSendCoordinator(service: UserService(client: APIClient(tokens: FixtureTokens(), session: StubHTTP.session())))
        do { _ = try await coordinator.submit(chatId: 42, text: "Retry my draft", parentId: nil); XCTFail("Offline Send") } catch {}
        XCTAssertEqual(acknowledgements, 0)
        recovered = true
        let full = try await coordinator.submit(chatId: 42, text: "Retry my draft", parentId: nil)
        XCTAssertEqual(full.messages.first?.message, "Retry my draft")
        XCTAssertEqual(acknowledgements, 1, "The later explicit user Send delivers once")
        XCTAssertEqual(attempts, 5, "Four safe closed-connection attempts then one acknowledged intentional Send")
        XCTAssertEqual(reads, 0, "Proven preconnection failure needs no outcome reconciliation or pre-send read")
    }

    @MainActor
    func testAcknowledgedMessageSendsImmediatelyWithoutConversationRead() async throws {
        var methods: [String] = []
        StubHTTP.handler = { request in
            methods.append(request.httpMethod ?? "")
            return (200, Data(#"{"result":{"id":42,"messages":[{"id":101,"message":"Immediate","is_from_caregiver":false}]}}"#.utf8))
        }
        let coordinator = ChatSendCoordinator(service: UserService(client: APIClient(tokens: FixtureTokens(), session: StubHTTP.session())))
        let full = try await coordinator.submit(chatId: 42, text: "Immediate", parentId: nil)
        XCTAssertEqual(full.messages.first?.message, "Immediate")
        XCTAssertEqual(methods, ["POST"], "Requirement 14 forbids a conversation read before normal Send")
    }

    @MainActor
    func testAmbiguousMessageRequiresNewIDCorrectSenderAndExactReplyBeforeAcknowledgement() async throws {
        let prior = ChatMessage(id: 100, parent: nil, message: "Repeated", createdAt: nil,
                                updatedAt: nil, seenAt: nil, isFromCaregiver: false)
        let mismatches = [
            #"{"id":100,"message":"Repeated","is_from_caregiver":false}"#,
            #"{"id":101,"message":"Repeated","is_from_caregiver":true}"#,
            #"{"id":101,"message":"Repeated","is_from_caregiver":false,"parent":{"id":7,"message":"Parent","is_from_caregiver":true}}"#,
            #"{"id":101,"message":"Different","is_from_caregiver":false}"#
        ]
        for wire in mismatches {
            var methods: [String] = []
            StubHTTP.handler = { request in
                let method = request.httpMethod ?? ""; methods.append(method)
                if method == "POST" { throw URLError(.networkConnectionLost) }
                return (200, Data(("{\"result\":{\"id\":42,\"messages\":[" + wire + "]}}").utf8))
            }
            let coordinator = ChatSendCoordinator(service: UserService(client: APIClient(tokens: FixtureTokens(), session: StubHTTP.session())))
            do {
                _ = try await coordinator.submit(chatId: 42, text: "Repeated", parentId: nil, baseline: [prior])
                XCTFail("An older message, other sender, other reply, or different text is not proof of this Send")
            } catch {}
            XCTAssertTrue(coordinator.uncertain)
            XCTAssertEqual(methods, ["POST", "GET"])
        }
    }

    @MainActor
    func testUnresolvedMessageSurvivesDifferentSendAndLaterTapReadsWithoutReplay() async throws {
        var methods: [String] = []
        var stored = false
        StubHTTP.handler = { request in
            let method = request.httpMethod ?? ""; methods.append(method)
            if method == "POST" {
                if StubHTTP.body(request).contains("message=Uncertain") { throw URLError(.networkConnectionLost) }
                return (200, Data(#"{"result":{"id":42,"messages":[{"id":102,"message":"Different","is_from_caregiver":false}]}}"#.utf8))
            }
            return (200, Data((stored
                ? #"{"result":{"id":42,"messages":[{"id":101,"message":"Uncertain","is_from_caregiver":false}]}}"#
                : #"{"result":{"id":42,"messages":[]}}"#).utf8))
        }
        let coordinator = ChatSendCoordinator(service: UserService(client: APIClient(tokens: FixtureTokens(), session: StubHTTP.session())))
        do { _ = try await coordinator.submit(chatId: 42, text: "Uncertain", parentId: nil); XCTFail("Absent message") } catch {}
        _ = try await coordinator.submit(chatId: 42, text: "Different", parentId: nil)
        do { _ = try await coordinator.submit(chatId: 42, text: "Uncertain", parentId: nil); XCTFail("Still absent") } catch {}
        XCTAssertEqual(methods, ["POST", "GET", "POST", "GET"], "Returning to the old draft cannot reset its unresolved outcome")
        stored = true
        let verified = try await coordinator.submit(chatId: 42, text: "Uncertain", parentId: nil)
        XCTAssertEqual(verified.messages.first?.message, "Uncertain")
        XCTAssertFalse(coordinator.uncertain)
        XCTAssertEqual(methods, ["POST", "GET", "POST", "GET", "GET"])
    }

    @MainActor
    func testFailedReconciliationReadPreservesOutcomeAndNeverRepostsSameDraft() async {
        var posts = 0, reads = 0
        StubHTTP.handler = { request in
            if request.httpMethod == "POST" { posts += 1; throw URLError(.networkConnectionLost) }
            reads += 1
            return (503, Data(#"{"message":"Synthetic unavailable"}"#.utf8))
        }
        let coordinator = ChatSendCoordinator(service: UserService(client: APIClient(tokens: FixtureTokens(), session: StubHTTP.session())))
        for _ in 0..<2 {
            do { _ = try await coordinator.submit(chatId: 42, text: "Retained", parentId: nil); XCTFail("Unverified outcome") }
            catch { XCTAssertFalse(Feedback.message(error).isEmpty) }
        }
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(coordinator.uncertain)
    }

    @MainActor
    func testConcurrentSendDoesNotQueueAnotherMessage() async throws {
        let started = expectation(description: "first actual POST started")
        var posts = 0
        StubHTTP.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            posts += 1
            started.fulfill()
            Thread.sleep(forTimeInterval: 0.25)
            return (200, Data(#"{"result":{"id":42,"messages":[{"id":101,"message":"First","is_from_caregiver":false}]}}"#.utf8))
        }
        let coordinator = ChatSendCoordinator(service: UserService(client: APIClient(tokens: FixtureTokens(), session: StubHTTP.session())))
        let first = Task { try await coordinator.submit(chatId: 42, text: "First", parentId: nil) }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await coordinator.submit(chatId: 42, text: "Second", parentId: nil); XCTFail("Second Send must not queue") } catch {}
        let acknowledged = try await first.value
        XCTAssertEqual(acknowledged.messages.first?.message, "First")
        XCTAssertEqual(posts, 1)
    }

    @MainActor
    func testConfirmedValidationRejectionDoesNotBecomeUncertainDelivery() async {
        StubHTTP.handler = { _ in (422, Data(#"{"errors":{"message":["Required"]},"message":"Invalid message"}"#.utf8)) }
        let coordinator = ChatSendCoordinator(service: UserService(client: APIClient(tokens: FixtureTokens(), session: StubHTTP.session())))
        do { _ = try await coordinator.submit(chatId: 42, text: "", parentId: nil) }
        catch {}
        XCTAssertFalse(coordinator.uncertain)
    }

    func testAcknowledgedSendClearsOnlyItsOwnDraftContent() {
        XCTAssertEqual(ChatDraftReconciliation.afterAcknowledgedSend(current: "Original", submitted: "Original"), "")
        XCTAssertEqual(ChatDraftReconciliation.afterAcknowledgedSend(current: "Original next message", submitted: "Original"), "next message")
        XCTAssertEqual(ChatDraftReconciliation.afterAcknowledgedSend(current: "Replacement message", submitted: "Original"), "Replacement message")
        XCTAssertEqual(ChatDraftReconciliation.afterAcknowledgedSend(current: "Edited original", submitted: "Original"), "Edited original")
        XCTAssertEqual(ChatDraftReconciliation.afterAcknowledgedSend(current: "مرحبا جديد", submitted: "مرحبا"), "جديد")
    }

    @MainActor
    func testHeldManualReadCannotReplaceAcknowledgedSend() async throws {
        var operations = ChatOperationOwnership()
        var transcript: [String] = []
        let oldRead = operations.beginExplicitRead()
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "actual manual GET result held before application")
        StubHTTP.handler = { request in
            if request.httpMethod == "GET" {
                return (200, Data(#"{"result":{"id":42,"messages":[{"id":1,"message":"stale manual response","is_from_caregiver":false}]}}"#.utf8))
            }
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, Data(#"{"result":{"id":42,"messages":[{"id":2,"message":"acknowledged message","is_from_caregiver":false}]}}"#.utf8))
        }
        let service = UserService(client: APIClient(tokens: FixtureTokens(), session: StubHTTP.session()))
        let read = Task { @MainActor in
            let full = try await service.chat(id: 42)
            await withCheckedContinuation { continuation in
                release = continuation
                started.fulfill()
            }
            if operations.canCommit(oldRead) { transcript = full.messages.map(\.message) }
            operations.finishExplicitRead(oldRead)
        }
        await fulfillment(of: [started], timeout: 2)
        let send = operations.beginSend()
        let coordinator = ChatSendCoordinator(service: service)
        let acknowledged = try await coordinator.submit(chatId: 42, text: "acknowledged message", parentId: nil)
        XCTAssertTrue(operations.canCommit(send))
        transcript = acknowledged.messages.map(\.message)
        release?.resume()
        try await read.value
        XCTAssertEqual(transcript, ["acknowledged message"])
        XCTAssertFalse(operations.canCommit(oldRead))
    }

    func testLatestExplicitReadOwnsSuccessAndFailureAndQuietReadsCannotSupersedeIt() {
        var operations = ChatOperationOwnership()
        let older = operations.beginExplicitRead()
        let newer = operations.beginExplicitRead()
        XCTAssertNil(operations.beginQuietRead())
        operations.finishExplicitRead(older)
        XCTAssertNil(operations.beginQuietRead(), "Finishing an older read must not release the newer read's ownership")
        var presentation = "newer success"
        if operations.canCommit(older) { presentation = "older error" }
        XCTAssertEqual(presentation, "newer success")
        XCTAssertTrue(operations.canCommit(newer))
        presentation = "newer error"
        if operations.canCommit(older) { presentation = "older success" }
        XCTAssertEqual(presentation, "newer error")
        operations.finishExplicitRead(newer)
        let quiet = operations.beginQuietRead()!
        let manual = operations.beginExplicitRead()
        XCTAssertFalse(operations.canCommit(quiet))
        XCTAssertTrue(operations.canCommit(manual))
        operations.invalidate()
        XCTAssertFalse(operations.canCommit(manual), "Disappearance invalidates both results and failures")
    }

    @MainActor
    func testSubmittedReplyRemainsImmutableWhenSelectionChangesDuringPreflight() async {
        var replies = ChatReplyOwnership()
        replies.selectionChanged()
        let submitted = replies.capture(parentId: 7)
        // Simulate the metadata await: the user selects another reply before POST.
        replies.selectionChanged()
        let currentParent = 9
        var posts = 0
        StubHTTP.handler = { request in
            posts += 1
            let body = StubHTTP.body(request)
            XCTAssertTrue(body.split(separator: "&").contains("parent_id=7"), "Delivery must use the captured original reply")
            XCTAssertFalse(body.contains("parent_id=9"))
            return (422, Data(#"{"errors":{"message":["Synthetic rejection"]},"message":"Rejected"}"#.utf8))
        }
        let coordinator = ChatSendCoordinator(service: UserService(client: APIClient(tokens: FixtureTokens(), session: StubHTTP.session())))
        do { _ = try await coordinator.submit(chatId: 42, text: "Synthetic reply", parentId: submitted.parentId); XCTFail("Expected controlled rejection") }
        catch {}
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(submitted.parentId, 7)
        XCTAssertFalse(replies.canClear(submitted, currentParentId: currentParent), "An older acknowledgement must retain the newer reply")
    }

    func testReplyCancellationAndSameIdentityReselectionAreNewIntent() {
        var replies = ChatReplyOwnership()
        replies.selectionChanged()
        let submitted = replies.capture(parentId: 7)
        XCTAssertTrue(replies.canClear(submitted, currentParentId: 7))
        replies.selectionChanged() // Cancel while the send is in flight.
        XCTAssertFalse(replies.canClear(submitted, currentParentId: nil))
        replies.selectionChanged() // Deliberately select the same message again.
        XCTAssertFalse(replies.canClear(submitted, currentParentId: 7))
        let next = replies.capture(parentId: 7)
        XCTAssertTrue(replies.canClear(next, currentParentId: 7))
        let noReply = replies.capture(parentId: nil)
        replies.selectionChanged()
        XCTAssertFalse(replies.canClear(noReply, currentParentId: 9))
    }


    // MARK: Parity v3 K2/K3 — closed conversations and deleted accounts

    private func chat(partnerDeleted: Bool, isMatch: Bool) throws -> ChatFull {
        let names = partnerDeleted ? #""first_name":null,"last_name":null,"is_deleted":true"# : #""first_name":"Ben","last_name":"PV3","is_deleted":false"#
        let json = #"{"id":7,"messages":[],"client":{"id":"c","user":{"id":"c","role":"client","first_name":"Ava","last_name":"PV3"},"is_match":true},"caregiver":{"id":"g","user":{"id":"g","role":"caregiver",\#(names),"email":null,"photo":null,"status":"unverified","is_favorite":false},"salary_min":25,"salary_max":60,"distance":0,"is_match":\#(isMatch)}}"#
        return try JSONDecoder().decode(ChatFull.self, from: Data(json.utf8))
    }

    func testDeletedAccountDecodesAndWinsOverMatchCheck() throws {
        let deleted = try chat(partnerDeleted: true, isMatch: false)
        XCTAssertEqual(deleted.caregiver?.user.isDeleted, true)
        XCTAssertEqual(ChatAvailability(chat: deleted, role: .client), .accountDeleted)
        XCTAssertEqual(ChatAvailability(chat: try chat(partnerDeleted: false, isMatch: false), role: .client), .notMatched)
        XCTAssertEqual(ChatAvailability(chat: try chat(partnerDeleted: false, isMatch: true), role: .client), .open)
        XCTAssertEqual(try chat(partnerDeleted: false, isMatch: true).caregiver?.user.isDeleted, false)
    }

    @MainActor func testDeletedAccountNameUsesManagedText() throws {
        let loc = Localization()
        let user = try XCTUnwrap(try chat(partnerDeleted: true, isMatch: false).caregiver?.user)
        XCTAssertEqual(user.displayName(loc), "Deleted Account")
        XCTAssertEqual(try XCTUnwrap(try chat(partnerDeleted: false, isMatch: true).caregiver?.user).displayName(loc), "Ben PV3")
        XCTAssertTrue(user.with(isFavorite: true).isDeleted, "Favourite updates keep the deleted flag")
    }

}

/// R3: public coordinators, actual UserService/AuthService/APIClient transport,
/// controlled responses only. This class never contacts production.
@MainActor
final class SettingsMutationReconciliationTests: XCTestCase {
    func testLostIssueAcknowledgementFindsOnlyNewExactIssueWithoutRepeatingCreate() async throws {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
        let draft = IssueSubmissionDraft(issuetypeId: nil, title: "Synthetic issue", description: "Synthetic description")
        let prior = Issue(id: 101, issuetypeId: nil, title: draft.title, description: draft.description,
                          reply: nil, createdAt: nil, repliedAt: nil, isReplied: false)
        var posts = 0, reads = 0
        StubHTTP.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/users/issues")
            if request.httpMethod == "POST" {
                posts += 1
                throw URLError(.networkConnectionLost)
            }
            XCTAssertEqual(request.httpMethod, "GET")
            reads += 1
            return (200, Data(#"{"result":[{"id":101,"title":"Synthetic issue","description":"Synthetic description","is_replied":false},{"id":102,"title":"Synthetic issue","description":"Synthetic description","is_replied":false}]}"#.utf8))
        }
        let coordinator = IssueSubmissionCoordinator(service: UserService(client: APIClient(tokens: tokens, session: StubHTTP.session())))
        do {
            let created = try await coordinator.submit(draft, baseline: [prior])
            XCTAssertEqual(created.id, 102, "An old identical issue must never confirm this request")
        } catch { XCTFail("A new exact issue confirms the lost acknowledgement; no error expected") }
        XCTAssertEqual(posts, 1, "Never repeat issue creation after an uncertain response")
        XCTAssertEqual(reads, 1, "Use one authoritative read for reconciliation")
        XCTAssertTrue(tokens.hasSession)
    }

    func testPredefinedIssueReconciliationUsesSubmittedTypeAndDescriptionNotGeneratedTitle() async throws {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
        StubHTTP.handler = { request in
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (200, Data(#"{"result":[{"id":102,"issuetype_id":7,"title":"Server category caption","description":"Synthetic description","is_replied":false}]}"#.utf8))
        }
        let coordinator = IssueSubmissionCoordinator(service: UserService(client: APIClient(tokens: tokens, session: StubHTTP.session())))
        let draft = IssueSubmissionDraft(issuetypeId: 7, title: nil, description: "Synthetic description")
        let saved = try await coordinator.submit(draft, baseline: [])
        XCTAssertEqual(saved.id, 102)
        XCTAssertEqual(saved.issuetypeId, 7)
    }

    func testLostDeletionAcknowledgementAndRejectedSessionClearsLocalStateWithoutAnotherDelete() async throws {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
        var deletes = 0, reads = 0
        StubHTTP.handler = { request in
            switch request.url!.path {
            case "/api/users":
                XCTAssertEqual(request.httpMethod, "DELETE")
                deletes += 1
                throw URLError(.networkConnectionLost)
            case "/api/auth/info":
                reads += 1
                if reads == 1 { return (200, Data(#"{"result":{"id":"fixture-owner","role":"client"}}"#.utf8)) }
                return (403, Data(#"{"message":"Valid JWT token is required!"}"#.utf8))
            case "/api/auth/refresh":
                return (403, Data(#"{"message":"Refresh credential rejected"}"#.utf8))
            default: XCTFail("Unexpected deletion request"); return (500, Data())
            }
        }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        XCTAssertEqual(manager.state.user?.id, "fixture-owner")
        do { try await manager.deleteAccount(reasonId: 1) }
        catch { XCTFail("Rejected saved session after uncertain deletion must finish local deletion flow") }
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(reads, 2, "Verify the session read-only after losing acknowledgement")
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertFalse(tokens.hasSession)
    }
}
