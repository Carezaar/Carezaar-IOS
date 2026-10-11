import XCTest
@testable import Carezaar

final class ChatSettingsTests: XCTestCase {
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

    @MainActor
    func testLostMessageResponseBlocksRepeatUntilExplicitChoice() async {
        var posts = 0
        StubHTTP.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            posts += 1
            throw URLError(.networkConnectionLost)
        }
        let coordinator = ChatSendCoordinator(service: UserService(client: APIClient(tokens: FixtureTokens(), session: StubHTTP.session())))
        do { _ = try await coordinator.submit(chatId: 42, text: "Keep my draft", parentId: nil); XCTFail("Lost response") }
        catch {}
        XCTAssertTrue(coordinator.uncertain, "A lost response cannot prove message rejection")
        do { _ = try await coordinator.submit(chatId: 42, text: "Keep my draft", parentId: nil) }
        catch {}
        XCTAssertEqual(posts, 1, "Repeating Send must not silently duplicate a potentially committed POST")
        coordinator.allowExplicitRetry()
        do { _ = try await coordinator.submit(chatId: 42, text: "Keep my draft", parentId: nil) }
        catch {}
        XCTAssertEqual(posts, 2, "Only an explicit duplicate-risk acknowledgement permits another attempt")
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

}
