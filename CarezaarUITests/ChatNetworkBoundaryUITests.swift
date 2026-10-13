import XCTest
import Foundation

/// Bounded native P09-004 offline-preflight/retry and P20-004 slow-send portions.
/// Sequential root dispatch only: exact retained owned pair initially NONE.
/// Two synthetic native messages remain as evidence; no arbitrary-user staging.
final class ChatNetworkBoundaryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private let marker = "Synthetic chat network " + UUID().uuidString
    private var cleanupFixture: Fixture?
    private var launchedAt = Date()
    private var verifiedIncomingMessageIDs: [String: Int] = [:]

    private struct Fixture {
        let primaryToken: String, peerToken: String
        let role: String, primaryID: String, peerID: String, peerName: String
        let labels: [String: String]
        var profileEndpoint: String { "\(role == "client" ? "clients/caregivers" : "caregivers/clients")/\(peerID)" }
        var peerEndpoint: String { "\(role == "client" ? "caregivers/clients" : "clients/caregivers")/\(primaryID)" }
        var listEndpoint: String { "\(role == "client" ? "clients" : "caregivers")/matches" }
        func label(_ slug: String, _ fallback: String) -> String {
            guard let value = labels[slug], !value.isEmpty else { return fallback }; return value
        }
    }

    override func setUp() {
        continueAfterFailure = false; app = XCUIApplication()
        verifiedIncomingMessageIDs.removeAll()
    }
    override func tearDown() {
        app?.terminate()
        if let f = cleanupFixture {
            do { try restoreNone(f) }
            catch { XCTFail("Owned chat-network relationship cleanup failed; inspect retained pair before another allocation") }
        }
        super.tearDown()
    }

    /// October 13 replaces the historical English-only uncertainty controls.
    /// Closed local port failure proves no delivery connection was established;
    /// committed-message/lost-ack reconciliation is covered by controlled service tests.
    func testOwnedNativeOfflineDirectSendPreservesDraftAndRecoversWithoutBlockingNotice() throws {
        let (f, chatID) = try stageOwnedActiveChat()
        let draft = "Synthetic offline direct Send " + UUID().uuidString
        XCTAssertFalse(try chatTexts(ownedChat(chatID, fixture: f, active: true)).contains(draft))
        launchChat(chatID, faults: ["--qa-offline", "100", "125", "--qa-latency", "8"])
        let field = try loadedComposer(chatID, fixture: f, timeout: 90)
        field.tap(); field.typeText(draft)
        XCTAssertEqual(field.value as? String, draft)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.exists && send.isEnabled && send.isHittable)
        waitUntilLaunchPlus(104)
        let elapsedBeforeSend = Date().timeIntervalSince(launchedAt)
        guard elapsedBeforeSend < 119 else {
            try record("owned-offline-direct-send-timing-prerequisite-\(f.role)", [
                "elapsedBeforeSend": elapsedBeforeSend, "nativePOSTs": messagePOSTs(chatID),
                "nativeSendAttempted": false, "timingPrerequisiteSatisfied": false])
            throw XCTSkip("Native initialization/input missed the bounded offline-send window; no Send attempted")
        }
        send.tap()
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.messagePOSTs(chatID) == 4 && send.isEnabled
                && !self.app.staticTexts["Please wait..."].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 35), .completed,
                       "One direct Send must exhaust its safe preconnection attempts and restore its composer")
        let failedAttempts = messagePOSTs(chatID)
        XCTAssertEqual(failedAttempts, 4)
        XCTAssertEqual(field.value as? String, draft)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "chat-send-uncertain").firstMatch.exists)
        XCTAssertFalse(app.buttons["Allow retry"].exists)
        XCTAssertFalse(app.alerts["Allow another send attempt?"].exists)
        let connectionError = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            f.label("general_network_title", "Cannot communicate with server."))).firstMatch
        XCTAssertTrue(connectionError.exists, "Failed Send must present the standard managed connection error")
        controlProof(connectionError, "owned-direct-send-managed-connection-error-only-\(f.role)")
        try assertOwnedUncertainDraftAbsent(draft, chatID: chatID, fixture: f)

        waitUntilLaunchPlus(137)
        XCTAssertEqual(messagePOSTs(chatID), failedAttempts, "Connectivity recovery must never send automatically")
        XCTAssertTrue(send.isEnabled && send.isHittable)
        send.tap()
        let acknowledged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (field.value as? String) != draft && self.app.staticTexts[draft].exists
                && !self.app.staticTexts["Please wait..."].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [acknowledged], timeout: 35), .completed,
                       "A later intentional Send after proven preconnection failure must deliver and clear its draft")
        XCTAssertEqual(messagePOSTs(chatID), 5, "Four failed preconnection attempts plus one acknowledged Send")
        XCTAssertEqual(try chatTexts(ownedChat(chatID, fixture: f, active: true)).filter { $0 == draft }.count, 1)
        send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(messagePOSTs(chatID), 5, "Empty-draft tap must not replay")
        try record("owned-native-direct-send-offline-recovered-\(f.role)", [
            "role": f.role, "elapsedBeforeNativeSend": elapsedBeforeSend,
            "configuredGlobalLatencySeconds": 8, "configuredOfflineWindowSeconds": [100, 125],
            "configuredFaultTarget": "closed local port 9", "logicalNativeSendActions": 2,
            "safePreconnectionTransportAttempts": 4, "acknowledgedRecoveryPOSTs": 1,
            "englishBlockingNoticeAbsent": true, "exactSyntheticDraftRetainedAfterFailure": true,
            "draftClearedAfterAcknowledgement": true, "backendStoredSyntheticMessageCount": 1,
            "committedMessageOrLostAcknowledgementCovered": false,
            "deviceNetworkChanged": false, "requestBodyCaptured": false])
        try finish(f)
    }

    private func assertOwnedUncertainDraftAbsent(_ draft: String, chatID: Int, fixture f: Fixture) throws {
        XCTAssertFalse(try chatTexts(ownedChat(chatID, fixture: f, active: true)).contains(draft))
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/chats/\(chatID)", token: f.peerToken)
        XCTAssertEqual(response.status, 200)
        let row = try XCTUnwrap(response.body["result"] as? [String: Any])
        guard row["id"] as? Int == chatID, nestedUserID(row, side: f.role) == f.primaryID,
              nestedUserID(row, side: f.role == "client" ? "caregiver" : "client") == f.peerID else {
            XCTFail("Uncertain delivery verification must read only the exact retained owned conversation")
            throw URLError(.userAuthenticationRequired)
        }
        let messages = try XCTUnwrap(row["messages"] as? [[String: Any]])
        XCTAssertFalse(messages.contains { $0["message"] as? String == draft })
    }

    /// Two actual incoming messages; uses retained synthetic history rather than
    /// creating a conversation or seeding an arbitrary twenty-message transcript.
    func testOwnedIncomingChatFollowsBottomPreservesOlderReadingAndStoredTimestamp() throws {
        let (f, chatID) = try stageOwnedActiveChat()
        let initial = try XCTUnwrap(ownedChat(chatID, fixture: f, active: true)["messages"] as? [[String: Any]])
        let quotedIDs = Set(initial.compactMap { ($0["parent"] as? [String: Any])?["id"] as? Int })
        let chronological = initial.sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
        let eligible = chronological.filter { row in
            guard let id = row["id"] as? Int, id > 0, !quotedIDs.contains(id),
                  let text = row["message"] as? String, text.hasPrefix("Synthetic "),
                  !text.contains("\n"), text.count <= 160 else { return false }
            return initial.filter { $0["message"] as? String == text }.count == 1
        }
        guard let last = chronological.last, let latestID = last["id"] as? Int,
              let latest = last["message"] as? String,
              eligible.contains(where: { ($0["id"] as? Int) == latestID }), eligible.count >= 4 else {
            throw XCTSkip("Existing owned chat needs a unique short synthetic latest message and older synthetic history; no history is seeded")
        }
        let olderTexts = eligible.filter { ($0["id"] as? Int) != latestID }
            .reversed().compactMap { $0["message"] as? String }
        launchChat(chatID, faults: [])
        let field = try loadedComposer(chatID, fixture: f, timeout: 60)
        let transcript = try ownedIncomingTranscript(above: field)
        let latestBubble = app.staticTexts.matching(NSPredicate(format: "label == %@", latest)).firstMatch
        XCTAssertTrue(latestBubble.waitForExistence(timeout: 15) && latestBubble.isHittable,
                      "Initial native load must reveal actual latest retained message without a manual scroll")

        let atBottomText = "Synthetic incoming bottom " + UUID().uuidString
        let firstTimestamp = try postOneOwnedIncoming(atBottomText, chatID: chatID, fixture: f)
        let atBottomBubble = app.staticTexts.matching(NSPredicate(format: "label == %@", atBottomText)).firstMatch
        let followed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            atBottomBubble.exists && atBottomBubble.isHittable && transcript.frame.contains(atBottomBubble.frame)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [followed], timeout: 35), .completed,
                       "At the bottom, native quiet polling must reveal the complete incoming message")
        let firstStampControl = try adjacentStoredTimestamp(firstTimestamp, below: atBottomBubble, in: transcript)
        controlProof(atBottomBubble, "owned-incoming-bottom-synthetic-message-only-\(f.role)")
        controlProof(firstStampControl, "owned-incoming-bottom-stored-timestamp-only-\(f.role)")

        func visibleOlder() -> XCUIElement? {
            olderTexts.compactMap { text -> XCUIElement? in
                let bubble = self.app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
                guard bubble.exists && bubble.isHittable,
                      transcript.frame.insetBy(dx: 0, dy: 12).contains(bubble.frame) else { return nil }
                return bubble
            }.first
        }
        var gestures = 0
        for _ in 0..<16 {
            if !atBottomBubble.isHittable, visibleOlder() != nil { break }
            transcript.swipeDown(velocity: .slow); gestures += 1
        }
        guard !atBottomBubble.isHittable, let older = visibleOlder() else {
            throw XCTSkip("Existing retained synthetic history cannot establish a fully visible older-message viewport away from bottom; no additional history seeded")
        }
        let originalY = older.frame.midY
        let beforePoll = count("GET /api/users/chats/\(chatID)")
        let whileReadingText = "Synthetic incoming reading " + UUID().uuidString
        let secondTimestamp = try postOneOwnedIncoming(whileReadingText, chatID: chatID, fixture: f)
        let whileReadingBubble = app.staticTexts.matching(NSPredicate(format: "label == %@", whileReadingText)).firstMatch
        let polled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.count("GET /api/users/chats/\(chatID)") >= beforePoll + 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [polled], timeout: 40), .completed,
                       "Native quiet reads must continue while the user reads older history")
        // The ledger records dispatch, not completion. The unique new message
        // must already exist in native AX before measuring retained position.
        // LazyVStack may omit an offscreen node: that allocation is unverified,
        // never a PASS inferred from GET counts or from a later manual scroll.
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in whileReadingBubble.exists }, object: nil)
        guard XCTWaiter.wait(for: [applied], timeout: 15) == .completed else {
            try record("owned-incoming-applied-data-prerequisite-\(f.role)", [
                "role": f.role, "quietGETDispatchesObserved": count("GET /api/users/chats/\(chatID)") - beforePoll,
                "uniqueNewMessageNativeAXExistsBeforeManualReturn": false,
                "retainedReadingPositionVerifiedAfterAppliedData": false,
                "manualReturnAttempted": false, "offscreenLazyAXPrerequisiteUnavailable": true])
            throw XCTSkip("Offscreen LazyVStack did not expose the unique new native message; dispatched reads alone cannot prove applied data before older-position verification")
        }
        XCTAssertTrue(older.isHittable && transcript.frame.contains(older.frame),
                      "An actual incoming message must not displace the older-message reader")
        XCTAssertEqual(older.frame.midY, originalY, accuracy: 3,
                       "The exact observed older synthetic message must retain its viewport position")
        XCTAssertFalse(whileReadingBubble.isHittable,
                       "Incoming message must remain outside the older-reading viewport")
        controlProof(older, "owned-incoming-preserved-older-synthetic-message-only-\(f.role)")
        let preservedY = older.frame.midY
        for _ in 0..<20 {
            if whileReadingBubble.exists && whileReadingBubble.isHittable
                && transcript.frame.contains(whileReadingBubble.frame)
                && observedAdjacentStoredTimestamp(secondTimestamp, below: whileReadingBubble, in: transcript) != nil { break }
            transcript.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(whileReadingBubble.exists && whileReadingBubble.isHittable
            && transcript.frame.contains(whileReadingBubble.frame),
                      "Returning to bottom must reveal the same acknowledged incoming message")
        let secondStampControl = try adjacentStoredTimestamp(secondTimestamp, below: whileReadingBubble, in: transcript)
        controlProof(whileReadingBubble, "owned-incoming-after-manual-return-synthetic-message-only-\(f.role)")
        controlProof(secondStampControl, "owned-incoming-reading-stored-timestamp-only-\(f.role)")
        XCTAssertEqual(try persistedOwnedIncoming(atBottomText, chatID: chatID, fixture: f), firstTimestamp)
        XCTAssertEqual(try persistedOwnedIncoming(whileReadingText, chatID: chatID, fixture: f), secondTimestamp)

        // Ordinary native Back and the exact owned Messages button test reentry;
        // no fabricated route or incoming-during-initial-load claim is made.
        try returnToOwnedConversationList(f)
        let row = try ownedConversationListRow(chatID, fixture: f)
        XCTAssertTrue((row.value as? String)?.contains(whileReadingText) == true)
        row.tap()
        let reenteredField = try loadedComposer(chatID, fixture: f, timeout: 45)
        let reenteredTranscript = try ownedIncomingTranscript(above: reenteredField)
        XCTAssertTrue(whileReadingBubble.waitForExistence(timeout: 15) && whileReadingBubble.isHittable
            && reenteredTranscript.frame.contains(whileReadingBubble.frame),
                      "Ordinary reentry must initially show the latest actual message")
        _ = try adjacentStoredTimestamp(secondTimestamp, below: whileReadingBubble, in: reenteredTranscript)
        XCTAssertEqual(messagePOSTs(chatID), 0, "Incoming-scroll verification must never send an outgoing native message")
        try record("owned-incoming-bottom-older-position-timestamps-\(f.role)", [
            "role": f.role, "existingOwnedChatUsed": true, "syntheticHistorySeeded": false,
            "initialLatestMessageVisibleWithoutManualScroll": true, "ownedPeerSyntheticPOSTs": 2,
            "incomingAtBottomFullyVisible": true, "olderViewportAwayFromBottomEstablished": true,
            "olderReadingGestureCount": gestures, "olderMessageYBeforeIncoming": Double(originalY),
            "olderMessageYAfterTwoNativeQuietReads": Double(preservedY),
            "olderMessagePositionTolerancePoints": 3, "newMessageInitiallyOutsideOlderViewport": true,
            "uniqueNewMessageNativeAXExistsBeforePositionMeasurement": true,
            "GETDispatchCountsAloneUsedAsAppliedDataProof": false,
            "manualReturnRevealedIncoming": true, "ordinaryNativeBackAndReentryLatestVisible": true,
            "bothActualStoredTimestampsExactlyEqualAdjacentNativeLabels": true,
            "createdAtUnchangedOnBothLaterReads": true, "nativeOutgoingMessagePOSTs": 0,
            "arbitraryTimestampFormatVariantsInjected": false, "incomingDuringInitialLoadCovered": false,
            "fullTranscriptScreenshotCaptured": false])
        try finish(f)
    }

    /// Incoming during the actual initial ChatView detail operation's controlled
    /// pre-transport latency. Does not claim a dispatched held HTTP response.
    func testOwnedIncomingDuringInitialChatLoadAppliesLatestAndTimestamp() throws {
        let (f, chatID) = try stageOwnedActiveChat()
        launchChat(chatID, faults: ["--qa-latency", "30"])
        let operationText = f.label("loading_chat_get_one", "Getting chat details")
        let operation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", operationText)).firstMatch
        let header = app.navigationBars[f.label("chat_screen_messages_title", "Chat Messages")]
        let rows = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-message-"))
        func initialDetailPending() -> Bool {
            // Only ChatView.load uses this exact managed operation; its work is
            // UserService.chat(chatId). No metadata preflight or Send is invoked.
            header.exists && operation.exists && rows.count == 0
                && self.count("GET /api/users/chats/\(chatID)") == 0
                && self.messagePOSTs(chatID) == 0
        }
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in initialDetailPending() }, object: nil)
        guard XCTWaiter.wait(for: [pending], timeout: 150) == .completed, initialDetailPending() else {
            try record("owned-incoming-initial-load-prerequisite", [
                "initialDetailOperationPendingBeforePeerPOST": false, "peerPOSTAttempted": false,
                "controlledPreTransportLatencySeconds": 30, "dispatchedHeldHTTPResponseCovered": false])
            throw XCTSkip("Actual initial chat-detail operation pending before transport was not observed; no peer message posted")
        }
        let incomingText = "Synthetic initial loading " + UUID().uuidString
        let timestamp = try postOneOwnedIncoming(incomingText, chatID: chatID, fixture: f)
        guard initialDetailPending() else {
            try record("owned-incoming-initial-load-prerequisite", [
                "initialDetailOperationPendingBeforePeerPOST": true,
                "initialDetailOperationStillPendingAfterPersistedPeerPOST": false,
                "ownedPeerSyntheticPOSTs": 1, "controlledPreTransportLatencySeconds": 30,
                "dispatchedHeldHTTPResponseCovered": false])
            throw XCTSkip("Initial detail loading ceased before the persisted peer POST could be attested; incoming-during-load remains unverified")
        }
        try record("owned-incoming-during-initial-load-pending", [
            "actualManagedInitialDetailOperationObservedBeforeAndAfterPeerPOST": true,
            "chatHeaderAndNoMessageRowsObservedBeforeAndAfterPeerPOST": true,
            "exactNativeDetailGETDispatchesBeforeAndAfterPeerPOST": 0,
            "controlledPreTransportLatencySeconds": 30, "ownedPeerSyntheticPOSTs": 1,
            "dispatchedHeldHTTPResponseCovered": false, "metadataPreflightUsedAsInitialLoadProof": false])
        let field = try loadedComposer(chatID, fixture: f, timeout: 100, readyTimeout: 60)
        let transcript = try ownedIncomingTranscript(above: field)
        let incoming = app.staticTexts.matching(NSPredicate(format: "label == %@", incomingText)).firstMatch
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            incoming.exists && incoming.isHittable && transcript.frame.contains(incoming.frame)
                && self.observedAdjacentStoredTimestamp(timestamp, below: incoming, in: transcript) != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 15), .completed,
                       "Actual initial response must apply the latest owned message and full row/footer without manual scroll")
        XCTAssertEqual(count("GET /api/users/chats/\(chatID)"), 1,
                       "Applied native row must come from the initial detail read, not a later quiet refresh")
        _ = try adjacentStoredTimestamp(timestamp, below: incoming, in: transcript)
        XCTAssertEqual(messagePOSTs(chatID), 0)
        controlProof(incoming, "owned-incoming-during-initial-load-synthetic-message-only-\(f.role)")
        try returnToOwnedConversationList(f, timeout: 60)
        let row = try ownedConversationListRow(chatID, fixture: f)
        XCTAssertTrue((row.value as? String)?.contains(incomingText) == true)
        row.tap()
        let reenteredField = try loadedComposer(chatID, fixture: f, timeout: 100, readyTimeout: 60)
        let reenteredTranscript = try ownedIncomingTranscript(above: reenteredField)
        XCTAssertTrue(incoming.waitForExistence(timeout: 15) && incoming.isHittable
            && reenteredTranscript.frame.contains(incoming.frame))
        _ = try adjacentStoredTimestamp(timestamp, below: incoming, in: reenteredTranscript)
        XCTAssertEqual(try persistedOwnedIncoming(incomingText, chatID: chatID, fixture: f), timestamp)
        XCTAssertEqual(messagePOSTs(chatID), 0)
        try record("owned-incoming-during-initial-load-completed", [
            "existingOwnedChatUsed": true, "ownedPeerSyntheticPOSTs": 1, "syntheticHistorySeeded": false,
            "incomingPersistedWhileActualInitialDetailOperationPending": true,
            "pendingBeforeTransportDispatchWithControlledLatency": true,
            "dispatchedHeldHTTPResponseCovered": false,
            "initialNativeResponseAppliedUniqueOwnedRowAndFullyVisibleFooter": true,
            "manualScrollUsedToRevealInitialAppliedMessage": false,
            "actualStoredPositiveMessageIDVerified": true, "actualStoredTimestampMatchesNativeFooter": true,
            "ordinaryNativeBackAndReentryLatestVisible": true, "createdAtUnchangedOnLaterRead": true,
            "nativeOutgoingMessagePOSTs": 0, "fullTranscriptScreenshotCaptured": false])
        try finish(f)
    }

    /// Independently complete bottom-follow scope; older offscreen AX availability
    /// is not a prerequisite. One peer POST, no history seed or outgoing send.
    func testOwnedKeyboardIncomingAtBottomAndNativeReentry() throws {
        let (f, chatID) = try stageOwnedActiveChat()
        let initial = try XCTUnwrap(ownedChat(chatID, fixture: f, active: true)["messages"] as? [[String: Any]])
        let latestRow = try XCTUnwrap(initial.max { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) })
        guard let latestText = latestRow["message"] as? String,
              latestText.hasPrefix("Synthetic "), !latestText.contains("\n"), latestText.count <= 160,
              initial.filter({ $0["message"] as? String == latestText }).count == 1,
              !initial.contains(where: { ($0["parent"] as? [String: Any])?["id"] as? Int == latestRow["id"] as? Int }) else {
            throw XCTSkip("Keyboard bottom check requires an existing unique short unquoted synthetic latest message; no history seeded")
        }
        launchChat(chatID, faults: [])
        let field = try loadedComposer(chatID, fixture: f, timeout: 60)
        let latest = app.staticTexts.matching(NSPredicate(format: "label == %@", latestText)).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 15) && latest.isHittable)
        let draft = "Synthetic keyboard bottom draft " + String(UUID().uuidString.prefix(8))
        field.tap(); field.typeText(draft)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10) && keyboard.frame.height > 100)
        let transcript = try ownedIncomingTranscript(above: field)
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            keyboard.exists && latest.exists && latest.isHittable && transcript.frame.contains(latest.frame)
                && field.frame.maxY <= keyboard.frame.minY + 2
        }, object: nil)
        let focusedResult = XCTWaiter.wait(for: [focused], timeout: 15)
        try recordKeyboardFocusGeometry("owned-keyboard-bottom-focus-geometry", result: focusedResult,
                                       keyboard: keyboard, field: field, transcript: transcript, latest: latest)
        XCTAssertEqual(focusedResult, .completed,
                       "Actual keyboard resize must keep latest and composer visible without manual scrolling")
        let incomingText = "Synthetic keyboard follow " + UUID().uuidString
        let timestamp = try postOneOwnedIncoming(incomingText, chatID: chatID, fixture: f)
        let incoming = app.staticTexts.matching(NSPredicate(format: "label == %@", incomingText)).firstMatch
        let followed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            keyboard.exists && incoming.exists && incoming.isHittable && transcript.frame.contains(incoming.frame)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [followed], timeout: 35), .completed)
        XCTAssertEqual(field.value as? String, draft)
        _ = try adjacentStoredTimestamp(timestamp, below: incoming, in: transcript)
        controlProof(incoming, "owned-keyboard-bottom-follow-synthetic-message-only-\(f.role)")
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", [f.label("general_ok", "OK"), "Done", "Hide keyboard"]))
            .allElementsBoundByIndex.first { $0.exists && $0.isHittable && $0.frame.minY >= field.frame.maxY - 2 }
        var dismissalVerified = false
        if let done {
            done.tap()
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 10))
            XCTAssertTrue(incoming.exists && incoming.isHittable && transcript.frame.contains(incoming.frame))
            XCTAssertEqual(field.value as? String, draft)
            dismissalVerified = true
        }
        XCTAssertEqual(try persistedOwnedIncoming(incomingText, chatID: chatID, fixture: f), timestamp)
        XCTAssertEqual(messagePOSTs(chatID), 0)
        try returnToOwnedConversationList(f)
        let row = try ownedConversationListRow(chatID, fixture: f)
        XCTAssertTrue((row.value as? String)?.contains(incomingText) == true)
        row.tap()
        let reenteredField = try loadedComposer(chatID, fixture: f, timeout: 45)
        let reenteredTranscript = try ownedIncomingTranscript(above: reenteredField)
        XCTAssertTrue(incoming.waitForExistence(timeout: 15) && incoming.isHittable
            && reenteredTranscript.frame.contains(incoming.frame))
        _ = try adjacentStoredTimestamp(timestamp, below: incoming, in: reenteredTranscript)
        XCTAssertEqual(messagePOSTs(chatID), 0)
        try record("owned-keyboard-bottom-follow-reentry-\(f.role)", [
            "role": f.role, "existingOwnedChatUsed": true, "syntheticHistorySeeded": false,
            "ownedPeerSyntheticPOSTs": 1, "actualSoftwareKeyboardAndReducedViewportVerified": true,
            "initialLatestVisibleAfterFocusWithoutManualScroll": true,
            "actualIncomingAtBottomFullyVisibleWithKeyboard": true,
            "nativeKeyboardDismissalControlAvailable": done != nil,
            "keyboardDismissalLatestVisibleVerified": dismissalVerified,
            "keyboardDismissalUnverifiedWhenNoNativeControl": !dismissalVerified,
            "unsentDraftPreservedBeforeBack": true, "draftPersistenceAcrossReentryCovered": false,
            "ordinaryNativeBackAndReentryLatestVisible": true,
            "actualBackendTimestampMatchesAdjacentNativeFooter": true,
            "createdAtUnchangedOnLaterRead": true, "nativeOutgoingMessagePOSTs": 0,
            "olderReaderAfterAppliedIncomingCovered": false,
            "incomingDuringInitialLoadCovered": false, "hostKeyboardShortcutUsed": false,
            "fullTranscriptOrKeyboardScreenshotCaptured": false])
        try finish(f)
    }

    /// Same strict incoming boundary with the real software keyboard visible.
    /// Only an observed native dismissal control is used; Return is never treated
    /// as dismissal for the multiline composer and no host keyboard shortcut runs.
    func testOwnedKeyboardVisibleIncomingKeepsBottomAndOlderReadingPosition() throws {
        let (f, chatID) = try stageOwnedActiveChat()
        let initial = try XCTUnwrap(ownedChat(chatID, fixture: f, active: true)["messages"] as? [[String: Any]])
        let quotedIDs = Set(initial.compactMap { ($0["parent"] as? [String: Any])?["id"] as? Int })
        let chronological = initial.sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
        let eligible = chronological.filter { row in
            guard let id = row["id"] as? Int, id > 0, !quotedIDs.contains(id),
                  let text = row["message"] as? String, text.hasPrefix("Synthetic "),
                  !text.contains("\n"), text.count <= 160 else { return false }
            return initial.filter { $0["message"] as? String == text }.count == 1
        }
        guard let latestRow = chronological.last, let latestID = latestRow["id"] as? Int,
              let latestText = latestRow["message"] as? String,
              eligible.contains(where: { ($0["id"] as? Int) == latestID }), eligible.count >= 4 else {
            throw XCTSkip("Keyboard incoming check needs existing unique short synthetic latest and older history; no history is seeded")
        }
        let olderTexts = eligible.filter { ($0["id"] as? Int) != latestID }
            .reversed().compactMap { $0["message"] as? String }
        launchChat(chatID, faults: [])
        let field = try loadedComposer(chatID, fixture: f, timeout: 60)
        let latest = app.staticTexts.matching(NSPredicate(format: "label == %@", latestText)).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 15) && latest.isHittable)
        let draft = "Synthetic keyboard draft " + String(UUID().uuidString.prefix(8))
        field.tap(); field.typeText(draft)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10) && keyboard.frame.height > 100,
                      "Actual software keyboard must be present, not just an unfocused composer")
        XCTAssertEqual(field.value as? String, draft)
        let transcript = try ownedIncomingTranscript(above: field)
        let focusedBottom = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            keyboard.exists && latest.exists && latest.isHittable && transcript.frame.contains(latest.frame)
                && field.frame.maxY <= keyboard.frame.minY + 2
        }, object: nil)
        let focusedResult = XCTWaiter.wait(for: [focusedBottom], timeout: 15)
        try recordKeyboardFocusGeometry("owned-keyboard-older-focus-geometry", result: focusedResult,
                                       keyboard: keyboard, field: field, transcript: transcript, latest: latest)
        XCTAssertEqual(focusedResult, .completed,
                       "Keyboard focus must leave latest retained message and composer visible without a manual bottom scroll")
        controlProof(field, "owned-keyboard-incoming-unsent-synthetic-draft-only-\(f.role)")

        let bottomText = "Synthetic keyboard bottom " + UUID().uuidString
        let firstTimestamp = try postOneOwnedIncoming(bottomText, chatID: chatID, fixture: f)
        let bottom = app.staticTexts.matching(NSPredicate(format: "label == %@", bottomText)).firstMatch
        let followed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            keyboard.exists && bottom.exists && bottom.isHittable && transcript.frame.contains(bottom.frame)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [followed], timeout: 35), .completed,
                       "Actual incoming message at bottom must remain fully visible above the open keyboard")
        XCTAssertEqual(field.value as? String, draft)
        _ = try adjacentStoredTimestamp(firstTimestamp, below: bottom, in: transcript)
        controlProof(bottom, "owned-keyboard-incoming-bottom-synthetic-message-only-\(f.role)")

        func visibleOlder() -> XCUIElement? {
            olderTexts.compactMap { text -> XCUIElement? in
                let bubble = self.app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
                guard bubble.exists && bubble.isHittable,
                      transcript.frame.insetBy(dx: 0, dy: 12).contains(bubble.frame) else { return nil }
                return bubble
            }.first
        }
        for _ in 0..<16 {
            if !bottom.isHittable, visibleOlder() != nil { break }
            transcript.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(keyboard.exists, "Older-history gestures must keep the keyboard visible for this variant")
        guard !bottom.isHittable, let older = visibleOlder() else {
            throw XCTSkip("Retained synthetic history cannot establish an older viewport with keyboard visible; no extra history seeded")
        }
        let originalY = older.frame.midY
        let beforePoll = count("GET /api/users/chats/\(chatID)")
        let olderIncomingText = "Synthetic keyboard reading " + UUID().uuidString
        let secondTimestamp = try postOneOwnedIncoming(olderIncomingText, chatID: chatID, fixture: f)
        let newer = app.staticTexts.matching(NSPredicate(format: "label == %@", olderIncomingText)).firstMatch
        let dispatched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.count("GET /api/users/chats/\(chatID)") >= beforePoll + 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dispatched], timeout: 40), .completed)
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in newer.exists }, object: nil)
        guard XCTWaiter.wait(for: [applied], timeout: 15) == .completed else {
            try record("owned-keyboard-incoming-applied-data-prerequisite-\(f.role)", [
                "role": f.role, "keyboardVisible": keyboard.exists,
                "uniqueNewNativeMessageExistsBeforePositionMeasurement": false,
                "GETDispatchAloneUsedAsAppliedProof": false, "manualReturnAttempted": false])
            throw XCTSkip("Offscreen lazy AX did not expose actual new message; keyboard older-position-after-apply remains unverified")
        }
        XCTAssertTrue(keyboard.exists && older.isHittable && transcript.frame.contains(older.frame))
        XCTAssertEqual(older.frame.midY, originalY, accuracy: 3,
                       "Actual applied incoming data must not jump the keyboard-visible older reader")
        XCTAssertFalse(newer.isHittable)
        XCTAssertEqual(field.value as? String, draft)
        controlProof(older, "owned-keyboard-incoming-anchored-older-synthetic-message-only-\(f.role)")

        // Dismiss only through an available native control. Expanding the viewport
        // can legitimately reveal more rows; require the older reader to remain
        // visible, not an unchanged viewport height or hidden newest row.
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", [f.label("general_ok", "OK"), "Done", "Hide keyboard"]))
            .allElementsBoundByIndex.first { $0.exists && $0.isHittable && $0.frame.minY >= field.frame.maxY - 2 }
        var keyboardDismissalVerified = false
        if let done {
            done.tap()
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 10))
            XCTAssertTrue(older.exists && older.isHittable && transcript.frame.contains(older.frame),
                          "Native keyboard dismissal must not jump away from the observed older reader")
            XCTAssertEqual(field.value as? String, draft)
            keyboardDismissalVerified = true
        }
        for _ in 0..<20 {
            if newer.exists && newer.isHittable && transcript.frame.contains(newer.frame)
                && observedAdjacentStoredTimestamp(secondTimestamp, below: newer, in: transcript) != nil { break }
            transcript.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(newer.exists && newer.isHittable && transcript.frame.contains(newer.frame),
                      "Latest applied message must remain reachable after the keyboard/older-reader transition")
        if !keyboardDismissalVerified { XCTAssertTrue(keyboard.exists) }
        _ = try adjacentStoredTimestamp(secondTimestamp, below: newer, in: transcript)
        XCTAssertEqual(try persistedOwnedIncoming(bottomText, chatID: chatID, fixture: f), firstTimestamp)
        XCTAssertEqual(try persistedOwnedIncoming(olderIncomingText, chatID: chatID, fixture: f), secondTimestamp)
        XCTAssertEqual(field.value as? String, draft)
        XCTAssertEqual(messagePOSTs(chatID), 0)
        controlProof(newer, "owned-keyboard-incoming-latest-reachable-synthetic-message-only-\(f.role)")
        try record("owned-keyboard-visible-incoming-boundaries-\(f.role)", [
            "role": f.role, "existingOwnedChatUsed": true, "syntheticHistorySeeded": false,
            "ownedPeerSyntheticPOSTs": 2, "keyboardFocusAndReducedViewportVerified": true,
            "initialLatestVisibleAfterKeyboardFocusWithoutManualScroll": true,
            "incomingAtBottomFullyVisibleWithKeyboard": true,
            "newNativeUUIDMessageAXExistsBeforeOlderPositionAssertion": true,
            "olderPositionRetainedWithinThreePointsWithKeyboard": true,
            "nativeKeyboardDismissalControlAvailable": done != nil,
            "keyboardDismissalPreservedOlderReaderVerified": keyboardDismissalVerified,
            "keyboardDismissalUnverifiedWhenNoNativeControl": !keyboardDismissalVerified,
            "latestIncomingReachableAfterManualReturn": true,
            "bothActualBackendTimestampsMatchedNativeAdjacentFooters": true,
            "unsentSyntheticDraftPreserved": true, "nativeOutgoingMessagePOSTs": 0,
            "hostKeyboardShortcutUsed": false, "fullTranscriptOrKeyboardScreenshotCaptured": false,
            "incomingDuringInitialLoadCovered": false])
        try finish(f)
    }

    private func recordKeyboardFocusGeometry(_ name: String, result: XCTWaiter.Result,
                                            keyboard: XCUIElement, field: XCUIElement,
                                            transcript: XCUIElement, latest: XCUIElement) throws {
        func geometry(_ element: XCUIElement) -> [String: Any] {
            let exists = element.exists
            let rect = exists ? element.frame : .zero
            return ["exists": exists, "hittable": exists && element.isHittable,
                    "frame": ["x": Double(rect.minX), "y": Double(rect.minY),
                              "width": Double(rect.width), "height": Double(rect.height)]]
        }
        try record(name, ["waiterStatus": result.rawValue, "app": geometry(app),
                          "keyboard": geometry(keyboard), "field": geometry(field),
                          "transcript": geometry(transcript), "latest": geometry(latest)])
    }

    private func ownedIncomingTranscript(above field: XCUIElement) throws -> XCUIElement {
        let candidates = app.scrollViews.allElementsBoundByIndex.filter {
            $0.exists && $0.frame.width > app.frame.width * 0.5 && $0.frame.height > 60
                && $0.frame.maxY <= field.frame.minY && $0.descendants(matching: .textField).count == 0
        }
        return try XCTUnwrap(candidates.max(by: { $0.frame.height < $1.frame.height }),
                             "Actual native transcript above composer required; never gesture inside an input ScrollView")
    }

    private func postOneOwnedIncoming(_ text: String, chatID: Int, fixture f: Fixture) throws -> String {
        _ = try ownedChat(chatID, fixture: f, active: true)
        let response = try CarezaarAPI.callWithHTTPStatus("POST", "users/chats/\(chatID)",
            form: ["message": text], token: f.peerToken)
        XCTAssertTrue((200..<300).contains(response.status), "Single exact owned peer POST must succeed; no ambiguous mutation replay")
        guard (200..<300).contains(response.status) else { throw URLError(.badServerResponse) }
        return try persistedOwnedIncoming(text, chatID: chatID, fixture: f)
    }

    private func persistedOwnedIncoming(_ text: String, chatID: Int, fixture f: Fixture) throws -> String {
        // Read from the sender side, leaving primary incoming/read state to the
        // actual native quiet reads. Assert both pair IDs before trusting data.
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/chats/\(chatID)", token: f.peerToken)
        XCTAssertEqual(response.status, 200)
        let chat = try XCTUnwrap(response.body["result"] as? [String: Any])
        guard chat["id"] as? Int == chatID, nestedUserID(chat, side: f.role) == f.primaryID,
              nestedUserID(chat, side: f.role == "client" ? "caregiver" : "client") == f.peerID else {
            XCTFail("Incoming proof must resolve only to the preflight-verified owned conversation")
            throw URLError(.userAuthenticationRequired)
        }
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        let stored = messages.filter { $0["message"] as? String == text }
        XCTAssertEqual(stored.count, 1)
        let message = try XCTUnwrap(stored.first)
        let messageID = try XCTUnwrap(message["id"] as? Int)
        XCTAssertGreaterThan(messageID, 0)
        guard messageID > 0 else { throw URLError(.cannotParseResponse) }
        XCTAssertEqual(message["is_from_caregiver"] as? Bool, f.role == "client")
        let timestamp = try XCTUnwrap(message["created_at"] as? String)
        XCTAssertFalse(timestamp.isEmpty, "Actual owned incoming message must have a stored timestamp")
        if let previous = verifiedIncomingMessageIDs[text] {
            XCTAssertEqual(previous, messageID, "Verified unique incoming body must retain its actual server ID")
            guard previous == messageID else { throw URLError(.cannotParseResponse) }
        }
        verifiedIncomingMessageIDs[text] = messageID
        return timestamp
    }

    private func adjacentStoredTimestamp(_ timestamp: String, below bubble: XCUIElement,
                                         in transcript: XCUIElement) throws -> XCUIElement {
        let matches = adjacentStoredTimestampMatches(timestamp, below: bubble, in: transcript)
        if matches.count != 1 {
            func geometry(_ element: XCUIElement) -> [String: Any] {
                let exists = element.exists
                let rect = exists ? element.frame : .zero
                return ["exists": exists, "hittable": exists && element.isHittable,
                        "frame": ["x": Double(rect.minX), "y": Double(rect.minY),
                                  "width": Double(rect.width), "height": Double(rect.height)]]
            }
            let exactCandidates = app.staticTexts.matching(NSPredicate(format: "label == %@", timestamp))
                .allElementsBoundByIndex.map { geometry($0) }
            try record("owned-adjacent-timestamp-failure-geometry", [
                "filteredMatchCount": matches.count, "bubble": geometry(bubble),
                "transcript": geometry(transcript), "exactCandidateGeometry": exactCandidates,
                "structuralRowOwnershipVerified": verifiedIncomingRow(for: bubble, in: transcript) != nil])
        }
        XCTAssertEqual(matches.count, 1,
                       "Exact raw stored timestamp must be the observed adjacent footer of this incoming bubble, not another message sharing that time")
        if matches.count == 1 {
            try record("owned-adjacent-timestamp-structural-ownership", [
                "structuralRowOwnershipVerified": true, "exactUniqueBodyDescendantVerified": true,
                "exactUniqueFooterDescendantVerified": true, "wholeRowBodyFooterInsideTranscript": true,
                "bodyAndFooterHittable": true, "unchangedVerticalAdjacencyVerified": true,
                "horizontalBoundsFromActualMessageRow": true])
        }
        return try XCTUnwrap(matches.first)
    }

    /// Non-asserting observation for bounded manual-return gestures. A clipped
    /// footer or ambiguous exact match is not completion, even if text is visible.
    private func observedAdjacentStoredTimestamp(_ timestamp: String, below bubble: XCUIElement,
                                                 in transcript: XCUIElement) -> XCUIElement? {
        guard bubble.exists && bubble.isHittable && transcript.frame.contains(bubble.frame) else { return nil }
        let matches = adjacentStoredTimestampMatches(timestamp, below: bubble, in: transcript)
        return matches.count == 1 ? matches.first : nil
    }

    private func adjacentStoredTimestampMatches(_ timestamp: String, below bubble: XCUIElement,
                                               in transcript: XCUIElement) -> [XCUIElement] {
        guard let row = verifiedIncomingRow(for: bubble, in: transcript) else { return [] }
        let exactFooters = row.descendants(matching: .staticText).matching(NSPredicate(format: "label == %@", timestamp))
        guard exactFooters.count == 1 else { return [] }
        return exactFooters
            .allElementsBoundByIndex.filter {
                $0.exists && $0.isHittable && transcript.frame.contains($0.frame) && row.frame.contains($0.frame)
                    && $0.frame.minY >= bubble.frame.maxY - 2 && $0.frame.maxY <= bubble.frame.maxY + 40
                    && $0.frame.midX >= row.frame.minX - 16 && $0.frame.midX <= row.frame.maxX + 16
            }
    }

    private func verifiedIncomingRow(for bubble: XCUIElement, in transcript: XCUIElement) -> XCUIElement? {
        guard bubble.exists && bubble.isHittable && transcript.frame.contains(bubble.frame),
              let messageID = verifiedIncomingMessageIDs[bubble.label], messageID > 0 else { return nil }
        let rows = app.otherElements.matching(identifier: "chat-message-\(messageID)")
        guard rows.count == 1 else { return nil }
        let row = rows.firstMatch
        guard row.exists && transcript.frame.contains(row.frame) && row.frame.contains(bubble.frame) else { return nil }
        let bodies = row.descendants(matching: .staticText).matching(NSPredicate(format: "label == %@", bubble.label))
        let allBodies = app.staticTexts.matching(NSPredicate(format: "label == %@", bubble.label))
        guard bodies.count == 1 && allBodies.count == 1 else { return nil }
        let body = bodies.firstMatch
        guard body.exists && body.isHittable && body.frame == bubble.frame else { return nil }
        return row
    }

    /// Actual existing owned conversation: zero -> incoming -> native read -> zero.
    /// Its retained history cannot prove the separate never-opened empty case.
    func testOwnedConversationUnreadTracksBackendIncomingAndNativeReadClear() throws {
        let (f, chatID) = try stageOwnedActiveChat()
        let history = try chatTexts(ownedChat(chatID, fixture: f, active: true))
        guard !history.isEmpty else { throw XCTSkip("Retained owned conversation history required; no empty-conversation fixture is created") }

        // Establish read state through the real native screen, not a fabricated
        // list response or a backend fixture rewriting unread counters.
        launchChat(chatID, faults: [])
        _ = try loadedComposer(chatID, fixture: f, timeout: 60)
        try returnToOwnedConversationList(f)
        let baseline = try ownedConversationListRow(chatID, fixture: f)
        XCTAssertEqual(try actualOwnedUnreadCount(chatID, fixture: f), 0)
        try assertOwnedUnreadValue(baseline, fixture: f, expected: false)
        XCTAssertEqual(messagePOSTs(chatID), 0)

        // Stop the native chat's quiet reads before the peer sends. The one
        // synthetic incoming message targets only this preflight-verified pair.
        app.terminate()
        _ = try ownedChat(chatID, fixture: f, active: true)
        let incoming = "Synthetic unread " + UUID().uuidString
        XCTAssertFalse(history.contains(incoming))
        let posted = try CarezaarAPI.callWithHTTPStatus("POST", "users/chats/\(chatID)",
            form: ["message": incoming], token: f.peerToken)
        XCTAssertTrue((200..<300).contains(posted.status), "Single owned peer message must be acknowledged; never replay an uncertain POST")
        guard (200..<300).contains(posted.status) else { throw URLError(.badServerResponse) }
        let positiveCount = try actualOwnedUnreadCount(chatID, fixture: f)
        XCTAssertGreaterThan(positiveCount, 0, "Actual backend must report new incoming messages before native list assertion")

        launchOwnedConversationList()
        let unreadRow = try ownedConversationListRow(chatID, fixture: f)
        let incomingPreview = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (unreadRow.value as? String)?.contains(incoming) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [incomingPreview], timeout: 20), .completed,
                       "Exact unique synthetic preview must bind the observed native row to the acknowledged owned incoming message")
        try assertOwnedUnreadValue(unreadRow, fixture: f, expected: true)
        XCTAssertEqual(count("GET /api/users/chats/\(chatID)"), 0,
                       "Rendering Messages must not mark the owned chat read by opening its detail")
        XCTAssertGreaterThan(try actualOwnedUnreadCount(chatID, fixture: f), 0)
        let indicator = unreadRow.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Unread")).firstMatch
        let separateIndicator = indicator.exists && indicator.isHittable
            && unreadRow.frame.contains(indicator.frame) && indicator.frame.width <= 24 && indicator.frame.height <= 24
        if separateIndicator { controlProof(indicator, "owned-unread-indicator-control-only-\(f.role)") }
        func frame(_ rect: CGRect) -> [String: Double] {
            ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
        }
        try record("owned-unread-native-row-geometry-\(f.role)", [
            "exactOwnedNameButtonUnambiguous": true, "exactSyntheticIncomingPreviewPresent": true,
            "ownedRowHittable": unreadRow.isHittable, "ownedRowFrame": frame(unreadRow.frame),
            "separateUnreadControlAvailable": separateIndicator,
            "separateUnreadControlFrame": frame(separateIndicator ? indicator.frame : .zero),
            "managedUnreadValueSuffixPresent": true, "namesAndTimestampsRecorded": false])

        unreadRow.tap()
        _ = try loadedComposer(chatID, fixture: f, timeout: 45)
        let bubble = app.staticTexts.matching(NSPredicate(format: "label == %@", incoming)).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 15), "Native read must contain the exact one acknowledged owned incoming message")
        XCTAssertEqual(try actualOwnedUnreadCount(chatID, fixture: f), 0,
                       "Actual backend list must clear unread after the real native chat read")
        let readHistory = try XCTUnwrap(ownedChat(chatID, fixture: f, active: true)["messages"] as? [[String: Any]])
        let acknowledged = readHistory.filter { $0["message"] as? String == incoming }
        XCTAssertEqual(acknowledged.count, 1)
        XCTAssertEqual(try XCTUnwrap(acknowledged.first)["is_from_caregiver"] as? Bool, f.role == "client")
        try returnToOwnedConversationList(f)
        let cleared = try ownedConversationListRow(chatID, fixture: f)
        XCTAssertTrue((cleared.value as? String)?.contains(incoming) == true)
        try assertOwnedUnreadValue(cleared, fixture: f, expected: false)
        XCTAssertEqual(try actualOwnedUnreadCount(chatID, fixture: f), 0)
        XCTAssertEqual(messagePOSTs(chatID), 0, "Native list/read flow must not send an outgoing message")
        try record("owned-unread-zero-incoming-native-read-clear-\(f.role)", [
            "role": f.role, "existingConversationWithHistory": true,
            "neverOpenedEmptyConversationCovered": false, "initialBackendUnreadCount": 0,
            "initialNativeUnreadAbsent": true, "ownedPeerSyntheticPOSTs": 1,
            "incomingBackendUnreadCount": positiveCount, "incomingNativeManagedUnreadPresent": true,
            "nativeDetailGETBeforeOpening": 0, "nativeOpenReadBackCovered": true,
            "finalBackendUnreadCount": 0, "finalNativeUnreadAbsent": true,
            "nativeMessagePOSTs": 0, "separateSafeUnreadControlScreenshotCaptured": separateIndicator,
            "wholeConversationRowScreenshotCaptured": false, "foreignConversationMutation": false])
        try finish(f)
    }

    private func launchOwnedConversationList() {
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-tab", "messages",
            "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
    }

    private func returnToOwnedConversationList(_ f: Fixture, timeout: TimeInterval = 15) throws {
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable)
        back.tap()
        let messagesTab = app.buttons[f.label("bottom_navigation_messages", "Messages")].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            messagesTab.exists && messagesTab.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed,
                       "Ordinary Back must reach a hittable Messages tab after native list loading")
        messagesTab.tap()
    }

    private func ownedConversationListRow(_ chatID: Int, fixture f: Fixture) throws -> XCUIElement {
        let row = app.buttons.matching(NSPredicate(format: "label == %@", f.peerName)).firstMatch
        XCTAssertTrue(app.staticTexts["qa-request-counts"].waitForExistence(timeout: 60))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.count("GET /api/users/chats") >= 1 && !self.app.staticTexts["Please wait..."].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 45), .completed)
        for _ in 0..<8 where !row.exists || !row.isHittable { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", f.peerName)).count, 1,
                       "Exact owned partner button must be unambiguous; no guessed or arbitrary conversation tap")
        XCTAssertTrue(row.exists && row.isHittable && app.frame.contains(row.frame))
        _ = try actualOwnedUnreadCount(chatID, fixture: f)
        return row
    }

    private func assertOwnedUnreadValue(_ row: XCUIElement, fixture f: Fixture, expected: Bool) throws {
        let unread = f.label("messages_unread", "Unread")
        let suffix = ". " + unread
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = row.value as? String, !value.isEmpty else { return false }
            return value.hasSuffix(suffix) == expected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 20), .completed,
                       "Exact owned row's managed unread accessibility value must match actual backend state")
        let value = try XCTUnwrap(row.value as? String)
        XCTAssertFalse(value.isEmpty)
        XCTAssertEqual(value.hasSuffix(suffix), expected)
    }

    private func actualOwnedUnreadCount(_ id: Int, fixture f: Fixture) throws -> Int {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/chats?page=1&perPage=50", token: f.primaryToken)
        XCTAssertEqual(response.status, 200)
        let rows = try XCTUnwrap(response.body["result"] as? [[String: Any]])
        let owned = rows.filter { ($0["id"] as? Int) == id }
        XCTAssertEqual(owned.count, 1)
        let row = try XCTUnwrap(owned.first)
        guard nestedUserID(row, side: f.role) == f.primaryID,
              nestedUserID(row, side: f.role == "client" ? "caregiver" : "client") == f.peerID else {
            XCTFail("Unread list reference must resolve only to the exact retained owned pair")
            throw URLError(.userAuthenticationRequired)
        }
        let count = try XCTUnwrap(row["new_message_count"] as? Int, "Actual unread counter must be present; never infer zero from a missing key")
        XCTAssertGreaterThanOrEqual(count, 0)
        return count
    }

    func testOwnedChatOfflinePreflightKeepsExactDraftThenNativeRetrySendsOnce() throws {
        let (f, chatID) = try stageOwnedActiveChat()
        let message = "Synthetic offline " + UUID().uuidString
        XCTAssertFalse(try chatTexts(ownedChat(chatID, fixture: f, active: true)).contains(message))
        launchChat(chatID, faults: ["--qa-offline", "30", "60"])
        let field = try loadedComposer(chatID, fixture: f, timeout: 28)
        field.tap(); field.typeText(message)
        XCTAssertTrue((field.value as? String) == message)
        waitUntilLaunchPlus(38)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.exists && send.isEnabled && send.isHittable)
        let getBefore = count("GET /api/users/chats/\(chatID)")
        send.tap()
        let networkCopy = f.label("general_network_title", "Cannot communicate with server.") + " "
            + f.label("error_check_connection", "Check your internet connection and try again.")
        let error = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", networkCopy)).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15), "Failed native preflight must show independently managed network feedback")
        XCTAssertTrue(error.exists, "Transient managed feedback must still exist for its control proof")
        controlProof(error, "owned-offline-managed-network-error-only-\(f.role)")
        XCTAssertGreaterThan(count("GET /api/users/chats/\(chatID)"), getBefore)
        XCTAssertEqual(messagePOSTs(chatID), 0, "Offline metadata failure must prevent delivery POST")
        XCTAssertTrue((field.value as? String) == message, "Offline preflight must preserve exact draft")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Couldn't confirm whether your message was sent")).firstMatch.exists,
                       "Zero-POST preflight failure must not be mislabeled as uncertain delivery")
        XCTAssertFalse(try chatTexts(ownedChat(chatID, fixture: f, active: true)).contains(message))
        waitUntilLaunchPlus(72) // app initialization begins after the test launch clock
        XCTAssertTrue(send.isEnabled && send.isHittable)
        send.tap()
        waitForExactEmptyDraft(field, fixture: f, timeout: 40)
        let bubble = app.staticTexts[message]
        XCTAssertTrue(bubble.waitForExistence(timeout: 10) && bubble.isHittable,
                      "Acknowledged retry must reveal the complete own synthetic bubble")
        XCTAssertEqual(messagePOSTs(chatID), 1)
        XCTAssertFalse(send.isEnabled)
        send.doubleTap() // real still-existing disabled Send; no stale coordinates
        let duplicate = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.messagePOSTs(chatID) != 1 }, object: nil)
        duplicate.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [duplicate], timeout: 3), .completed)
        XCTAssertFalse(send.isEnabled)
        try assertStoredOnce(message, chatID: chatID, fixture: f)
        controlProof(bubble, "owned-offline-retry-synthetic-bubble-only-\(f.role)")
        try record("owned-offline-preflight-retry-\(f.role)", ["role": f.role,
            "offlineInjection": "Debug native transport closed-local-port 30-to-60-seconds",
            "deviceWiFiOrCellularChanged": false, "failedPreflightMessagePOSTs": 0,
            "exactDraftPreserved": true, "explicitNativeRetryPOSTs": 1,
            "backendExactMessageOccurrencesBothOwnedPerspectives": 1,
            "emptyDraftRepeatedSendTapsExtraPOSTs": 0, "uncertainPOSTRecoveryCovered": false])
        try finish(f)
    }

    func testOwnedSlowNativeSendShowsProgressAndPreservesContinuedTyping() throws {
        let (f, chatID) = try stageOwnedActiveChat()
        let first = "Synthetic slow " + UUID().uuidString
        let second = "NEXT_" + String(UUID().uuidString.prefix(8))
        launchChat(chatID, faults: ["--qa-latency", "6"])
        let field = try loadedComposer(chatID, fixture: f, timeout: 120)
        field.tap(); field.typeText(first)
        XCTAssertTrue((field.value as? String) == first)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.exists && send.isEnabled && send.isHittable)
        let beforeGET = count("GET /api/users/chats/\(chatID)")
        send.tap()
        XCTAssertFalse(send.isEnabled, "Native Send must disable during its delayed delivery")
        field.typeText(second)
        XCTAssertTrue((field.value as? String) == first + second,
                      "Continued typing must actually occur before acknowledgement and append to the unchanged submitted baseline")
        let busy = app.staticTexts["Please wait..."]
        XCTAssertTrue(busy.waitForExistence(timeout: 20), "Native delivery POST must show real progress")
        XCTAssertFalse(send.isEnabled)
        XCTAssertTrue(busy.waitForNonExistence(timeout: 40), "Slow acknowledged delivery must finish")
        let retained = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (field.value as? String) == second }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [retained], timeout: 15), .completed,
                       "Acknowledgement must remove only submitted prefix, preserving exact new typing")
        XCTAssertEqual(count("GET /api/users/chats/\(chatID)"), beforeGET, "An acknowledged send must not add a conversation read")
        XCTAssertEqual(messagePOSTs(chatID), 1)
        XCTAssertTrue(send.isEnabled, "Retained new draft remains available for deliberate later submission")
        let bubble = app.staticTexts[first]
        XCTAssertTrue(bubble.waitForExistence(timeout: 10) && bubble.isHittable)
        try assertStoredOnce(first, chatID: chatID, fixture: f)
        let stored = try chatTexts(ownedChat(chatID, fixture: f, active: true))
        XCTAssertFalse(stored.contains(where: { $0.contains(second) }), "New typing must not be appended to or independently sent with the first message")
        controlProof(bubble, "owned-slow-send-first-synthetic-bubble-only-\(f.role)")
        controlProof(field, "owned-slow-send-retained-synthetic-draft-only-\(f.role)")
        try record("owned-slow-send-new-typing-\(f.role)", ["role": f.role,
            "injectedNativeTransportDelaySeconds": 6, "disabledSendDuringDeliveryObserved": true, "redundantConversationReads": 0,
            "actualPOSTProgressObserved": true, "exactContinuedTypingRetained": true,
            "nativeMessagePOSTs": 1, "backendFirstMessageOccurrencesBothOwnedPerspectives": 1,
            "continuedTypingSent": false, "rapidCardsConfirmSortCoverageClaimed": false])
        try finish(f)
    }

    func testOwnedDirectReplySendPersistsParentAndAllowsFutureReplyAfterAcknowledgement() throws {
        let (f, chatID) = try stageOwnedActiveChat()
        let initial = try ownedChat(chatID, fixture: f, active: true)
        let messages = try XCTUnwrap(initial["messages"] as? [[String: Any]])
        // Existing reply quotations repeat their parent's message label in the
        // native transcript. Select only unquoted peer messages so firstMatch
        // cannot resolve a quote instead of the actual message/menu pair.
        var quotedParentIDs = Set<Int>()
        for message in messages {
            guard let rawParent = message["parent"], !(rawParent is NSNull) else { continue }
            let parent = try XCTUnwrap(rawParent as? [String: Any], "Existing reply parent must have the actual backend object shape")
            let id = try XCTUnwrap(parent["id"] as? Int, "Existing reply parent must expose its real message ID")
            XCTAssertGreaterThan(id, 0)
            guard id > 0 else { throw URLError(.cannotParseResponse) }
            quotedParentIDs.insert(id)
        }
        let targets = messages.filter { row in
            guard let id = row["id"] as? Int, id > 0, !quotedParentIDs.contains(id),
                  row["parent"] == nil || row["parent"] is NSNull,
                  row["is_from_caregiver"] as? Bool == (f.role == "client"),
                  let text = row["message"] as? String, text.hasPrefix("Synthetic "),
                  !text.contains("\n"), text.count <= 120 else { return false }
            return messages.filter { $0["message"] as? String == text }.count == 1
        }.sorted { ($0["id"] as? Int ?? 0) > ($1["id"] as? Int ?? 0) }
        guard targets.count >= 2 else {
            throw XCTSkip("Two existing unique unquoted original owned synthetic peer messages required; no messages are seeded")
        }
        let a = targets[1], b = targets[0]
        let aID = try XCTUnwrap(a["id"] as? Int), bID = try XCTUnwrap(b["id"] as? Int)
        let aText = try XCTUnwrap(a["message"] as? String), bText = try XCTUnwrap(b["message"] as? String)
        XCTAssertNotEqual(aID, bID)
        launchChat(chatID, faults: ["--qa-latency", "20"])
        let field = try loadedComposer(chatID, fixture: f, timeout: 150)
        _ = try ownedChat(chatID, fixture: f, active: true)
        try selectSyntheticReply(aText, messageID: aID)
        XCTAssertTrue(replyBannerContains(aText, near: field))
        let sentText = "Synthetic reply race " + UUID().uuidString
        field.tap(); field.typeText(sentText)
        XCTAssertEqual(field.value as? String, sentText)
        // October13 R14 removes the historical delayed GET preflight. Delivery
        // starts immediately and its progress modal blocks interaction. This
        // migration does not certify changing reply selection during delivery.
        let send = app.buttons["Send"]
        let refresh = app.buttons[f.label("chat_screen_refresh", "Refresh")].firstMatch
        let busy = app.staticTexts[f.label("loading_please_wait", "Please wait...")]
        XCTAssertTrue(send.isEnabled && send.isHittable && refresh.isEnabled)
        let beforeGET = count("GET /api/users/chats/\(chatID)")
        XCTAssertEqual(messagePOSTs(chatID), 0)
        send.tap()
        XCTAssertTrue(busy.waitForExistence(timeout: 10), "Direct POST delivery must present progress")
        XCTAssertFalse(send.isEnabled)
        XCTAssertFalse(refresh.isEnabled, "Manual refresh stays disabled during delivery")
        XCTAssertEqual(count("GET /api/users/chats/\(chatID)"), beforeGET)
        XCTAssertFalse(refresh.isHittable, "Progress modal blocks the disabled refresh target")
        // The deliberate transport latency runs before the request counter.
        // Require actual dispatch after that delay, without inventing a GET
        // preflight or equating the progress UI with an already-sent request.
        let dispatched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.messagePOSTs(chatID) == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dispatched], timeout: 30), .completed)
        XCTAssertEqual(messagePOSTs(chatID), 1)
        // A quiet read begun before Send can finish its injected latency during
        // delivery. Its counter is not evidence of a new per-send preflight.
        // Dedicated direct-send tests retain the controlled no-extra-GET proof.
        let readsAtDispatch = count("GET /api/users/chats/\(chatID)")
        XCTAssertTrue(busy.waitForNonExistence(timeout: 45))
        waitForExactEmptyDraft(field, fixture: f, timeout: 15)
        XCTAssertFalse(app.buttons["Cancel"].exists, "Acknowledgement clears the submitted reply selection")
        let bubble = app.staticTexts.matching(NSPredicate(format: "label == %@", sentText)).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 10))
        try selectSyntheticReply(bText, messageID: bID)
        XCTAssertTrue(replyBannerContains(bText, near: field), "A future reply may be selected after acknowledgement")
        XCTAssertTrue(app.buttons["Cancel"].exists)
        XCTAssertEqual(messagePOSTs(chatID), 1, "Selecting a future reply cannot send another message")
        XCTAssertFalse(send.isEnabled, "Future reply still requires deliberate draft entry and send")
        let primary = try ownedChat(chatID, fixture: f, active: true)
        let peerResponse = try CarezaarAPI.callWithHTTPStatus("GET", "users/chats/\(chatID)", token: f.peerToken)
        XCTAssertEqual(peerResponse.status, 200)
        let peer = try XCTUnwrap(peerResponse.body["result"] as? [String: Any])
        XCTAssertEqual(peer["id"] as? Int, chatID)
        XCTAssertEqual(nestedUserID(peer, side: f.role), f.primaryID)
        XCTAssertEqual(nestedUserID(peer, side: f.role == "client" ? "caregiver" : "client"), f.peerID)
        for full in [primary, peer] {
            let stored = try XCTUnwrap(full["messages"] as? [[String: Any]])
                .filter { $0["message"] as? String == sentText }
            XCTAssertEqual(stored.count, 1)
            let message = try XCTUnwrap(stored.first)
            XCTAssertEqual(message["is_from_caregiver"] as? Bool, f.role == "caregiver")
            let parent = try XCTUnwrap(message["parent"] as? [String: Any])
            XCTAssertEqual(parent["id"] as? Int, aID, "Persisted native send must reply to initial A, not newer B")
            XCTAssertNotEqual(parent["id"] as? Int, bID)
        }
        controlProof(bubble, "owned-reply-race-synthetic-acknowledged-message-only-\(f.role)")
        try record("owned-reply-race-acknowledged-\(f.role)", ["role": f.role,
            "persistedOriginalParentVerifiedBothOwnedPerspectives": true,
            "futureReplySelectedAfterAcknowledgement": replyBannerContains(bText, near: field),
            "replyChangedDuringDeliveryVerified": false, "legacyPreflightTimingSupersededByDirectPOST": true,
            "conversationReadDeltaDuringInjectedDelay": readsAtDispatch - beforeGET,
            "quietReadAttributionVerified": false, "wholeDeliveryNoGETClaimed": false,
            "nativeMessagePOSTs": messagePOSTs(chatID), "emptyNewDraftSendDisabled": !send.isEnabled,
            "requestBodyCaptured": false, "syntheticPeerMessagesSeeded": false,
            "existingQuotedParentIDsExcludedFromTargets": true, "originalPeerTargetsWithoutParentQuotes": true])
        try finish(f)
    }

    private func observedAdjacentMessageMenu(for bubble: XCUIElement, messageID: Int? = nil) -> XCUIElement? {
        guard bubble.exists else { return nil }
        if let messageID {
            guard messageID > 0 else { return nil }
            let controls = app.buttons.matching(identifier: "chat-message-options-\(messageID)")
            guard controls.count == 1 else { return nil }
            let menu = controls.firstMatch
            guard menu.exists && menu.isHittable && menu.frame.midY >= bubble.frame.minY - 16
                && menu.frame.midY <= bubble.frame.maxY + 16 else { return nil }
            return menu
        }
        return app.buttons.matching(identifier: "Message options").allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable && $0.frame.midY >= bubble.frame.minY - 16
                && $0.frame.midY <= bubble.frame.maxY + 16 }
            .min { abs($0.frame.midY - (bubble.frame.minY + 8)) < abs($1.frame.midY - (bubble.frame.minY + 8)) }
    }
    private func adjacentMessageMenu(for bubble: XCUIElement, messageID: Int? = nil) throws -> XCUIElement {
        let menu = try XCTUnwrap(observedAdjacentMessageMenu(for: bubble, messageID: messageID),
                                 "Exact synthetic peer bubble requires its unique verified-ID adjacent native Menu")
        // AX frame subtraction can report 44 as 43.99999999999997.
        // Allow only eight CGFloat ULPs (under 0.0000000000001 point),
        // preserving the physical 44-point target requirement.
        let minimumTarget = CGFloat(44) - CGFloat(44).ulp * 8
        XCTAssertGreaterThanOrEqual(menu.frame.width, minimumTarget, "Message options requires a 44-point target")
        XCTAssertGreaterThanOrEqual(menu.frame.height, minimumTarget)
        return menu
    }
    private func selectSyntheticReply(_ text: String, reveal: Bool = true, messageID: Int? = nil) throws {
        let bubble: XCUIElement
        if reveal { bubble = try revealSyntheticPeerBubble(text, messageID: messageID) }
        else { bubble = app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch }
        XCTAssertTrue(bubble.exists && bubble.isHittable)
        let menu = try adjacentMessageMenu(for: bubble, messageID: messageID)
        menu.tap()
        let reply = app.buttons["Reply"].firstMatch
        // Preserve real readiness and the same bound without the convenience
        // wait's fixed first-poll overhead inside the strict measured interval.
        if !(reply.exists && reply.isHittable) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in reply.exists && reply.isHittable }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        }
        reply.tap()
    }
    private func revealSyntheticPeerBubble(_ text: String, messageID: Int? = nil) throws -> XCUIElement {
        let bubble = app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
        let field = app.textFields.firstMatch
        let candidates = app.scrollViews.allElementsBoundByIndex.filter {
            $0.exists && $0.frame.width > app.frame.width * 0.5 && $0.frame.height > 60
                && $0.frame.maxY <= field.frame.minY
                && $0.descendants(matching: .textField).count == 0
        }
        let transcript = try XCTUnwrap(candidates.max(by: { $0.frame.height < $1.frame.height }),
                                      "Actual transcript above composer required; never swipe multiline field's internal ScrollView")
        func ready() -> Bool {
            guard bubble.exists && bubble.isHittable && transcript.frame.contains(bubble.frame),
                  let menu = observedAdjacentMessageMenu(for: bubble, messageID: messageID) else { return false }
            return transcript.frame.contains(menu.frame)
        }
        // Advisory frames plan gestures only; ready() retains every exact-ID,
        // hittability, adjacency and complete-containment requirement.
        let firstUpward = bubble.exists ? bubble.frame.midY >= transcript.frame.midY : false
        var attempts = 0
        for attempt in 0..<48 {
            if ready() { break }
            let viewport = transcript.frame.intersection(app.frame)
            let availableRange = viewport.height - 16
            guard !viewport.isNull, viewport.width > 16, availableRange > 0 else { break }
            var targetUnion: CGRect?
            if bubble.exists, let messageID, messageID > 0 {
                let controls = app.buttons.matching(identifier: "chat-message-options-\(messageID)")
                if controls.count == 1, controls.firstMatch.exists {
                    targetUnion = bubble.frame.union(controls.firstMatch.frame)
                }
            }
            var upward = attempt < 24 ? firstUpward : !firstUpward
            let maximumDistance = min(40, viewport.height / 4, availableRange)
            var needed = maximumDistance
            if let targetUnion {
                if targetUnion.height > viewport.height {
                    try record("owned-reply-race-infeasible-reveal-geometry", [
                        "wholeTargetUnionTallerThanObservedViewport": true,
                        "targetUnionHeight": Double(targetUnion.height),
                        "observedViewportHeight": Double(viewport.height),
                        "visibilityGateRelaxed": false])
                    break
                }
                if targetUnion.minY < viewport.minY {
                    upward = false
                    needed = viewport.minY - targetUnion.minY + 2
                } else if targetUnion.maxY > viewport.maxY {
                    upward = true
                    needed = targetUnion.maxY - viewport.maxY + 2
                }
            }
            // Recalculate after each gesture; a half-screen sweep can skip the
            // feasible window. At least 20 points where available crosses native
            // drag slop; the viewport-based cap keeps the gesture small.
            let distance = min(maximumDistance, max(min(20, maximumDistance), needed))
            let centerY = viewport.midY
            let startY = centerY + (upward ? distance / 2 : -distance / 2)
            let endY = centerY + (upward ? -distance / 2 : distance / 2)
            let origin = transcript.coordinate(withNormalizedOffset: .zero)
            let observedFrame = transcript.frame
            let start = origin.withOffset(CGVector(dx: viewport.midX - observedFrame.minX, dy: startY - observedFrame.minY))
            let end = origin.withOffset(CGVector(dx: viewport.midX - observedFrame.minX, dy: endY - observedFrame.minY))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            attempts += 1
        }
        func frame(_ rect: CGRect) -> [String: Double] {
            ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
        }
        try record("owned-reply-race-native-transcript-reveal", ["syntheticTargetExists": bubble.exists,
            "syntheticTargetHittable": bubble.exists && bubble.isHittable,
            "targetFrame": frame(bubble.exists ? bubble.frame : .zero),
            "adjacentMenuExistsAndHittable": observedAdjacentMessageMenu(for: bubble, messageID: messageID) != nil,
            "adjacentMenuFrame": frame(observedAdjacentMessageMenu(for: bubble, messageID: messageID)?.frame ?? .zero),
            "wholeTextAndMenuInsideTranscript": ready(),
            "transcriptFrame": frame(transcript.frame), "composerFrame": frame(field.frame),
            "transcriptHasTextFieldDescendant": transcript.descendants(matching: .textField).count > 0,
            "boundedBothDirections": true, "gestureCount": attempts])
        XCTAssertTrue(ready(), "Exact original synthetic peer text and adjacent Menu must be fully visible in actual transcript")
        guard ready() else { throw URLError(.cannotParseResponse) }
        return bubble
    }
    private func replyBannerContains(_ text: String, near field: XCUIElement) -> Bool {
        let cancel = app.buttons["Cancel"].firstMatch
        guard cancel.exists else { return false }
        return app.staticTexts.matching(NSPredicate(format: "label == %@", text)).allElementsBoundByIndex.contains {
            $0.exists && $0.isHittable && $0.frame.maxY <= field.frame.minY
                && abs($0.frame.midY - cancel.frame.midY) <= max($0.frame.height, cancel.frame.height)
        }
    }

    private func stageOwnedActiveChat() throws -> (Fixture, Int) {
        let f = try preflight()
        let p = try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)
        let other = try profile(f.peerEndpoint, token: f.peerToken, expectedUser: f.primaryID)
        guard p["match_status"] as? String == "none", other["match_status"] as? String == "none" else {
            throw XCTSkip("Chat-network checks require exact owned pair initially NONE; no existing relation will be cleared")
        }
        let chatID = try existingOwnedChat(f) // no chat-creation fixture mutation
        cleanupFixture = f
        let id = try createRequest(f, fromPrimary: true)
        _ = try ownedEdge(id, fixture: f)
        let accepted = try CarezaarAPI.callWithHTTPStatus("PATCH", "users/matches/\(id)/accept", token: f.peerToken)
        XCTAssertTrue((200..<300).contains(accepted.status))
        XCTAssertEqual(try pairStatus(f), "active")
        _ = try ownedChat(chatID, fixture: f, active: true)
        return (f, chatID)
    }
    private func finish(_ f: Fixture) throws {
        try restoreNone(f)
        XCTAssertEqual(try pairStatus(f), "none")
        cleanupFixture = nil
    }
    private func launchChat(_ id: Int, faults: [String]) {
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", "Chat/\(id)",
            "-carezaar.languageId", "1", "-carezaar.languageCode", "en"] + faults
        launchedAt = Date(); app.launch()
    }
    private func loadedComposer(_ id: Int, fixture f: Fixture, timeout: TimeInterval, readyTimeout: TimeInterval = 30) throws -> XCUIElement {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            field.isHittable && !self.app.staticTexts["Please wait..."].exists
                && self.count("GET /api/users/chats/\(id)") >= 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: readyTimeout), .completed)
        XCTAssertEqual(app.textFields.count, 1)
        XCTAssertEqual(field.placeholderValue, f.label("chat_screen_message_placeholder", "Type a message..."))
        XCTAssertTrue(app.navigationBars[f.label("chat_screen_messages_title", "Chat Messages")].exists)
        XCTAssertEqual(messagePOSTs(id), 0)
        return field
    }
    private func waitUntilLaunchPlus(_ seconds: TimeInterval) {
        let target = launchedAt.addingTimeInterval(seconds)
        let elapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= target }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [elapsed], timeout: max(1, target.timeIntervalSinceNow + 3)), .completed)
    }
    private func waitForExactEmptyDraft(_ field: XCUIElement, fixture f: Fixture, timeout: TimeInterval) {
        let placeholder = f.label("chat_screen_message_placeholder", "Type a message...")
        let empty = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (field.value as? String) == "" || (field.value as? String) == placeholder
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: timeout), .completed,
                       "Acknowledged original draft must become exactly empty/placeholder")
    }
    private func assertStoredOnce(_ text: String, chatID: Int, fixture f: Fixture) throws {
        let primary = try ownedChat(chatID, fixture: f, active: true)
        let peerResponse = try CarezaarAPI.callWithHTTPStatus("GET", "users/chats/\(chatID)", token: f.peerToken)
        XCTAssertEqual(peerResponse.status, 200)
        let peer = try XCTUnwrap(peerResponse.body["result"] as? [String: Any])
        XCTAssertTrue(peer["id"] as? Int == chatID
            && nestedUserID(peer, side: f.role) == f.primaryID
            && nestedUserID(peer, side: f.role == "client" ? "caregiver" : "client") == f.peerID)
        for row in [primary, peer] {
            let matches = try XCTUnwrap(row["messages"] as? [[String: Any]]).filter { $0["message"] as? String == text }
            XCTAssertEqual(matches.count, 1, "Actual persisted synthetic message must occur exactly once")
            let message = try XCTUnwrap(matches.first)
            XCTAssertEqual(message["is_from_caregiver"] as? Bool, f.role == "caregiver")
            XCTAssertGreaterThan(try XCTUnwrap(message["id"] as? Int), 0)
            XCTAssertFalse((message["created_at"] as? String ?? "").isEmpty)
        }
    }
    private func messagePOSTs(_ id: Int) -> Int {
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.exists)
        let lines = ledger.label.split(separator: "\n").filter { $0.hasPrefix("POST /api/users/chats/") }
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("POST /api/users/chats/\(id)=") }, "Native send must target only exact owned existing chat")
        return lines.compactMap { Int($0.split(separator: "=").last ?? "") }.reduce(0, +)
    }
    private func count(_ key: String) -> Int {
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.exists)
        let prefix = key + "="
        return ledger.label.split(separator: "\n").first { $0.hasPrefix(prefix) }.flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
    }
    private func controlProof(_ element: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func record(_ name: String, _ values: [String: Any]) throws {
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func preflight() throws -> Fixture {
        let required = ["QA_EMAIL", "QA_PASSWORD", "QA_CLIENT_EMAIL", "QA_CLIENT_PASSWORD",
                        "QA_CG_EMAIL", "QA_CG_PASSWORD", "QA_CLIENT_USER_ID", "QA_CG_ID"]
        guard required.allSatisfy({ !(env[$0] ?? "").isEmpty }) else {
            throw XCTSkip("Explicit primary plus both retained owned role credentials/IDs required")
        }
        let clientID = env["QA_CLIENT_USER_ID"]!, caregiverID = env["QA_CG_ID"]!
        XCTAssertTrue(clientID != caregiverID)
        func auth(_ email: String, _ password: String, role: String, id: String) throws -> (String, [String: Any]) {
            let token = try CarezaarAPI.login(email, password)
            let user = try CarezaarAPI.me(token)
            guard !token.isEmpty, user["role"] as? String == role,
                  user["id"].map({ String(describing: $0) }) == id,
                  user["email"] as? String == email else {
                XCTFail("Mutation fixture failed exact private role/email/user-ID authorization")
                throw URLError(.userAuthenticationRequired)
            }
            return (token, user)
        }
        let client = try auth(env["QA_CLIENT_EMAIL"]!, env["QA_CLIENT_PASSWORD"]!, role: "client", id: clientID)
        let caregiver = try auth(env["QA_CG_EMAIL"]!, env["QA_CG_PASSWORD"]!, role: "caregiver", id: caregiverID)
        let primaryToken = try CarezaarAPI.login(env["QA_EMAIL"]!, env["QA_PASSWORD"]!)
        let primary = try CarezaarAPI.me(primaryToken)
        let role = primary["role"] as? String ?? ""
        let id = primary["id"].map { String(describing: $0) } ?? ""
        guard !primaryToken.isEmpty,
              (role == "client" && id == clientID && primary["email"] as? String == env["QA_CLIENT_EMAIL"])
                || (role == "caregiver" && id == caregiverID && primary["email"] as? String == env["QA_CG_EMAIL"]),
              primary["email"] as? String == env["QA_EMAIL"] else {
            XCTFail("Primary runner is outside the exact owned pair")
            throw URLError(.userAuthenticationRequired)
        }
        let peer = role == "client" ? caregiver : client
        let name = [peer.1["first_name"] as? String, peer.1["last_name"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertFalse(name.isEmpty)
        let contents = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: primaryToken)
        XCTAssertEqual(contents.status, 200)
        let rows = try XCTUnwrap(contents.body["result"] as? [[String: Any]])
        var labels = [String: String]()
        for row in rows {
            guard let slug = row["slug"] as? String, let translation = (row["translations"] as? [[String: Any]])?.first(where: {
                ($0["language_id"] as? NSNumber)?.intValue == 1 || ($0["language_id"] as? String) == "1"
            }), let name = translation["name"] as? String else { continue }
            labels[slug] = name
        }
        return Fixture(primaryToken: primaryToken, peerToken: peer.0, role: role, primaryID: id,
                       peerID: role == "client" ? caregiverID : clientID, peerName: name, labels: labels)
    }

    private func profile(_ endpoint: String, token: String, expectedUser: String) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", endpoint, token: token)
        XCTAssertEqual(response.status, 200)
        let row = try XCTUnwrap(response.body["result"] as? [String: Any])
        let user = try XCTUnwrap(row["user"] as? [String: Any])
        XCTAssertTrue(user["id"].map { String(describing: $0) } == expectedUser,
                      "Relationship reference must resolve only to the exact owned counterpart")
        return row
    }

    private func pairStatus(_ f: Fixture) throws -> String {
        let primary = try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)
        let peer = try profile(f.peerEndpoint, token: f.peerToken, expectedUser: f.primaryID)
        let status = try XCTUnwrap(primary["match_status"] as? String)
        let inverse = ["none": "none", "sent": "received", "received": "sent", "active": "active"]
        XCTAssertEqual(peer["match_status"] as? String, inverse[status])
        XCTAssertEqual(primary["is_match"] as? Bool, status == "active")
        XCTAssertEqual(peer["is_match"] as? Bool, status == "active")
        if status != "none" {
            let id = try XCTUnwrap(primary["match_id"] as? Int)
            XCTAssertGreaterThan(id, 0)
            XCTAssertEqual(peer["match_id"] as? Int, id)
            _ = try ownedEdge(id, fixture: f)
        }
        return status
    }

    private func ownedEdge(_ id: Int, fixture f: Fixture) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/matches/\(id)", token: f.primaryToken)
        XCTAssertEqual(response.status, 200)
        let row = try XCTUnwrap(response.body["result"] as? [String: Any])
        func userID(_ side: String) -> String {
            let user = (row[side] as? [String: Any])?["user"] as? [String: Any]
            return user?["id"].map { String(describing: $0) } ?? ""
        }
        guard userID(f.role) == f.primaryID,
              userID(f.role == "client" ? "caregiver" : "client") == f.peerID,
              row["introduction"] as? String == marker else {
            XCTFail("Refusing mutation/cleanup of an edge outside this run's exact marked owned pair")
            throw URLError(.userAuthenticationRequired)
        }
        return row
    }

    private func createRequest(_ f: Fixture, fromPrimary: Bool) throws -> Int {
        XCTAssertEqual(try pairStatus(f), "none", "Each stage must start without a relationship")
        let response = try CarezaarAPI.callWithHTTPStatus("POST", "users/matches",
            form: ["partner_id": fromPrimary ? f.peerID : f.primaryID, "introduction": marker],
            token: fromPrimary ? f.primaryToken : f.peerToken)
        XCTAssertTrue((200..<300).contains(response.status), "Owned staging request must succeed once")
        let row = try XCTUnwrap(response.body["result"] as? [String: Any])
        let id = try XCTUnwrap(row["id"] as? Int)
        _ = try ownedEdge(id, fixture: f)
        return id
    }

    private func restoreNone(_ f: Fixture) throws {
        let p = try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)
        let status = try XCTUnwrap(p["match_status"] as? String)
        if status == "none" { return }
        let id = try XCTUnwrap(p["match_id"] as? Int)
        _ = try ownedEdge(id, fixture: f)
        let suffix: String, token: String
        switch status {
        case "sent": suffix = "/withdraw"; token = f.primaryToken
        case "received": suffix = "/withdraw"; token = f.peerToken
        case "active": suffix = ""; token = f.primaryToken
        default: XCTFail("Unrecognized pair state blocks cleanup"); throw URLError(.cannotParseResponse)
        }
        let statusCode = try deleteOwnedEdge("users/matches/\(id)\(suffix)", token: token)
        XCTAssertTrue((200..<300).contains(statusCode), "Exact owned staged-edge cleanup must succeed")
        XCTAssertEqual(try pairStatus(f), "none")
    }

    private func existingOwnedChat(_ f: Fixture) throws -> Int {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/chats?page=1&perPage=50", token: f.primaryToken)
        XCTAssertEqual(response.status, 200)
        let rows = try XCTUnwrap(response.body["result"] as? [[String: Any]])
        let rowsForPair = rows.filter { row in
            nestedUserID(row, side: f.role) == f.primaryID
                && nestedUserID(row, side: f.role == "client" ? "caregiver" : "client") == f.peerID
        }
        guard !rowsForPair.isEmpty else { throw XCTSkip("Owned pair lacks an existing chat; no conversation fixture will be created") }
        XCTAssertEqual(rowsForPair.count, 1, "Owned existing conversation must be unambiguous")
        return try XCTUnwrap(rowsForPair.first?["id"] as? Int)
    }

    private func nestedUserID(_ row: [String: Any], side: String) -> String {
        let user = (row[side] as? [String: Any])?["user"] as? [String: Any]
        return user?["id"].map { String(describing: $0) } ?? ""
    }

    private func ownedChat(_ id: Int, fixture f: Fixture, active: Bool) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/chats/\(id)", token: f.primaryToken)
        XCTAssertEqual(response.status, 200, "Exact owned chat metadata must remain readable")
        let row = try XCTUnwrap(response.body["result"] as? [String: Any])
        XCTAssertTrue((row["id"] as? Int) == id)
        XCTAssertTrue(nestedUserID(row, side: f.role) == f.primaryID
            && nestedUserID(row, side: f.role == "client" ? "caregiver" : "client") == f.peerID,
                      "Chat must resolve only to the exact retained owned pair")
        let peer = try XCTUnwrap(row[f.role == "client" ? "caregiver" : "client"] as? [String: Any])
        XCTAssertEqual(peer["is_match"] as? Bool, active, "Chat metadata must reflect the actual current relationship")
        return row
    }

    private func chatTexts(_ row: [String: Any]) -> [String] {
        (row["messages"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
    }

    private func deleteOwnedEdge(_ path: String, token: String) throws -> Int {
        var request = URLRequest(url: URL(string: path, relativeTo: CarezaarAPI.base)!)
        request.httpMethod = "DELETE"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        var result: Result<Int, Error> = .failure(URLError(.unknown))
        URLSession.shared.dataTask(with: request) { _, response, error in
            defer { done.signal() }
            if let error { result = .failure(error); return }
            guard let response = response as? HTTPURLResponse else {
                result = .failure(URLError(.badServerResponse)); return
            }
            result = .success(response.statusCode)
        }.resume()
        done.wait()
        return try result.get()
    }
}
