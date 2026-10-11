import XCTest

/// P08-007 revisit branch: observe exact source-derived APK parity (empty draft,
/// no selected reply after a popped chat is reopened), with no accidental send.
/// APK m6.java:738/744 creates ordinary empty/null composer state; mv.java:37–39,
/// jw0L.java:362 and y72.java:71–78 pop without saving that state. This is a source
/// expectation, not Android runtime proof. Only the exact retained owned pair is
/// used. Never presses Send or stages a relationship.
final class UnsentChatDraftUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app?.terminate(); super.tearDown() }

    func testUnsentOwnedChatDraftResetsOnBackAndRevisitWithoutSend() throws {
        try exerciseRevisit(withReply: false)
    }

    func testUnsentOwnedChatReplyAndDraftResetOnBackAndRevisitWithoutSend() throws {
        try exerciseRevisit(withReply: true)
    }

    private func exerciseRevisit(withReply: Bool) throws {
        let fixture = try ownedConversation()
        let fullBefore = try verifiedFull(chatID: fixture.chatID, token: fixture.token,
                                          clientID: fixture.clientID, caregiverID: fixture.caregiverID)
        let messages = fullBefore["messages"] as? [[String: Any]] ?? []
        let peerMessages = messages.filter {
            ($0["is_from_caregiver"] as? Bool) == (fixture.role == "client")
        }.sorted { ($0["id"] as? Int ?? 0) > ($1["id"] as? Int ?? 0) }
        let replyText = peerMessages.compactMap { $0["message"] as? String }.first { text in
            !text.isEmpty && messages.filter { ($0["message"] as? String) == text }.count == 1
        }
        if withReply && replyText == nil {
            throw XCTSkip("Existing owned chat lacks a unique peer message; no reply fixture will be injected")
        }
        let draft = "Synthetic unsent revisit " + UUID().uuidString
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let messagesTab = app.buttons["Messages"].firstMatch
        XCTAssertTrue(messagesTab.waitForExistence(timeout: 60))
        // Main exposes its tabs while its initial Matches request still has a
        // blocking feedback overlay. The stable Modern failure attempted this
        // tap during that overlay and computed {-1,-1}; no chats GET followed.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            messagesTab.isHittable && self.app.frame.contains(messagesTab.frame)
                && !self.app.staticTexts["Please wait..."].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 45), .completed,
                       "Messages must be reachable after the native startup busy overlay clears")
        messagesTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            messagesTab.isSelected && self.count("GET /api/users/chats") >= 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 15), .completed,
                       "Actual native Messages must become selected and request its conversation list")
        let row = app.buttons.matching(NSPredicate(format: "label == %@", fixture.partnerName)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "Exact owned conversation must appear in Messages")
        XCTAssertGreaterThanOrEqual(count("GET /api/users/chats"), 1)
        XCTAssertTrue(row.isHittable, "Owned conversation row must be reachable")
        row.tap()
        // SwiftUI's vertical TextField drops the placeholder AX identifier once
        // populated. The actual chat has exactly one TextField composer.
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 40))
        XCTAssertEqual(app.textFields.count, 1, "Owned native chat must have one unambiguous composer")
        XCTAssertEqual(field.placeholderValue, "Type a message...", "Initial unique field must be the managed chat composer")
        XCTAssertGreaterThanOrEqual(count(fixture.getPath), 1,
                                    "The actual opened conversation must match the independently verified chat")
        // The ledger records request start; the empty composer can already
        // exist behind Getting chat details. Require completed native content
        // and the exact owned partner header before interacting with input.
        let chatLoaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            field.isHittable && !self.app.staticTexts["Please wait..."].exists
                && self.app.navigationBars["Chat Messages"].exists
                && self.app.staticTexts[fixture.partnerName].firstMatch.exists
                && self.count(fixture.getPath) >= 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [chatLoaded], timeout: 30), .completed,
                       "Owned chat must finish loading and expose its actual partner header and reachable composer")
        if withReply, let replyText {
            let bubble = app.staticTexts.matching(NSPredicate(format: "label == %@", replyText)).firstMatch
            let transcript = app.scrollViews.firstMatch
            XCTAssertTrue(transcript.exists)
            for _ in 0..<16 {
                if bubble.exists && bubble.isHittable { break }
                transcript.swipeDown(velocity: .slow)
            }
            XCTAssertTrue(bubble.exists && bubble.isHittable, "Existing exact peer reply target must be reachable")
            // ChatView exposes a genuine Menu button beside every bubble. Pick
            // its observed vertical alignment with the exact peer text instead
            // of depending on a static text long-press context-menu gesture.
            let options = app.buttons.matching(identifier: "Message options").allElementsBoundByIndex
                .filter { $0.isHittable && $0.frame.midY >= bubble.frame.minY - 16
                    && $0.frame.midY <= bubble.frame.maxY + 16 }
                .min { abs($0.frame.midY - (bubble.frame.minY + 8))
                    < abs($1.frame.midY - (bubble.frame.minY + 8)) }
            let menu = try XCTUnwrap(options, "Exact peer bubble must expose its adjacent native message menu")
            menu.tap()
            let reply = app.buttons["Reply"].firstMatch
            XCTAssertTrue(reply.waitForExistence(timeout: 5) && reply.isHittable)
            reply.tap()
            XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "Native selected-reply banner missing")
            XCTAssertTrue(replyBannerContains(replyText, near: field), "Banner must contain the exact selected peer text")
        }
        XCTAssertTrue(field.isHittable)
        field.tap(); field.typeText(draft)
        XCTAssertTrue((field.value as? String) == draft, "Exact synthetic draft must be entered")
        // This is a vertical multiline TextField: Return inserts a newline.
        // Leave its keyboard visible; the genuine navigation Back remains
        // reachable and no input-changing keyboard gesture is necessary.
        XCTAssertTrue((field.value as? String) == draft,
                      "Exact synthetic draft baseline must remain unchanged before navigating")
        XCTAssertTrue(app.buttons["Send"].isEnabled, "Populated native draft should be sendable")
        XCTAssertEqual(count(fixture.postPath), 0)
        attachField(field, name: "P08-007-synthetic-draft-before-back")
        let before = count(fixture.getPath)
        // BackHeader supplies NavigationStack's native Back control, not the
        // design-scene BackButton identifier. Its trailing logo is an image.
        let chatBar = app.navigationBars["Chat Messages"]
        XCTAssertTrue(chatBar.exists, "Actual native chat navigation bar missing")
        let back = chatBar.buttons.firstMatch
        XCTAssertTrue(back.exists && back.isHittable)
        XCTAssertTrue((field.value as? String) == draft,
                      "Exact pre-Back baseline must match the initial synthetic input")
        if withReply, let replyText {
            XCTAssertTrue(app.buttons["Cancel"].exists && replyBannerContains(replyText, near: field),
                          "Exact selected reply baseline must remain before Back")
        }
        back.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Back must restore the Messages conversation list")
        XCTAssertFalse(field.exists, "Back must leave the conversation rather than merely dismiss the keyboard")
        XCTAssertEqual(count(fixture.postPath), 0, "Leaving must never send the draft")
        XCTAssertTrue(row.isHittable)
        row.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Owned conversation must reopen")
        let reloaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.count(fixture.getPath) > before && field.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reloaded], timeout: 30), .completed,
                       "Revisit must actually load the same conversation")
        XCTAssertEqual(count(fixture.postPath), 0, "Navigation must not attempt a send")
        let stored = try verifiedFull(chatID: fixture.chatID, token: fixture.token,
                                      clientID: fixture.clientID, caregiverID: fixture.caregiverID)
        let texts = (stored["messages"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
        XCTAssertFalse(texts.contains(draft), "Unsent synthetic draft must not reach the backend")
        let placeholder = "Type a message..."
        let observed = field.value as? String ?? ""
        // An empty native TextField may expose an empty AX value or its exact
        // placeholder; neither permits any retained whitespace/synthetic text.
        let reset = field.placeholderValue == placeholder && (observed.isEmpty || observed == placeholder)
        let replyReset = !app.buttons["Cancel"].exists
        let sendDisabled = !app.buttons["Send"].isEnabled
        record(role: fixture.role, reset: reset, sendAttempts: count(fixture.postPath),
               replyCovered: withReply, replyReset: replyReset, sendDisabled: sendDisabled)
        // Field-only screenshots contain synthetic input/placeholder, never peer
        // identity, transcript, credentials, conversation IDs or profile data.
        attachField(field, name: "P08-007-synthetic-draft-after-revisit")
        XCTAssertTrue(reset, "Reopened chat must reset to the exact empty composer/placeholder, matching APK source behavior")
        XCTAssertFalse(observed.contains(draft), "Reopened composer must not retain the prior synthetic draft")
        XCTAssertTrue(replyReset, "Reopened chat must have no selected-reply Cancel banner")
        XCTAssertTrue(app.buttons["Send"].exists && sendDisabled, "Empty reopened composer must keep Send disabled")
    }

    private struct Fixture {
        let token: String
        let role: String
        let clientID: String
        let caregiverID: String
        let chatID: Int
        let partnerName: String
        var getPath: String { "GET /api/users/chats/\(chatID)" }
        var postPath: String { "POST /api/users/chats/\(chatID)" }
    }

    private func ownedConversation() throws -> Fixture {
        guard let email = env["QA_EMAIL"], !email.isEmpty,
              let password = env["QA_PASSWORD"], !password.isEmpty,
              let clientID = env["QA_CLIENT_USER_ID"], !clientID.isEmpty,
              let caregiverID = env["QA_CG_ID"], !caregiverID.isEmpty else {
            throw XCTSkip("Exact retained owned pair and primary credentials required")
        }
        let token = try CarezaarAPI.login(email, password)
        let me = try CarezaarAPI.me(token)
        let role = me["role"] as? String ?? ""
        let id = me["id"].map { String(describing: $0) } ?? ""
        guard !token.isEmpty, (role == "client" && id == clientID) || (role == "caregiver" && id == caregiverID) else {
            XCTFail("Primary fixture is outside the exact authorized role/identity pair")
            throw URLError(.userAuthenticationRequired)
        }
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/chats?page=1&perPage=50", token: token)
        XCTAssertEqual(response.status, 200)
        let rows = try XCTUnwrap(response.body["result"] as? [[String: Any]])
        let owned = rows.filter { row in
            userID(row, side: "client") == clientID && userID(row, side: "caregiver") == caregiverID
        }
        XCTAssertEqual(owned.count, 1, "Require one unambiguous existing owned-pair conversation; no chat creation")
        let row = try XCTUnwrap(owned.first)
        let chatID = try XCTUnwrap(row["id"] as? Int)
        XCTAssertGreaterThan(chatID, 0)
        _ = try verifiedFull(chatID: chatID, token: token, clientID: clientID, caregiverID: caregiverID)
        let partnerSide = role == "client" ? "caregiver" : "client"
        func name(_ row: [String: Any]) -> String {
            let user = (row[partnerSide] as? [String: Any])?["user"] as? [String: Any] ?? [:]
            return [user["first_name"] as? String, user["last_name"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        let partnerName = name(row)
        XCTAssertFalse(partnerName.isEmpty)
        XCTAssertEqual(rows.filter { name($0) == partnerName }.count, 1,
                       "Visible partner label must uniquely identify the owned conversation")
        return Fixture(token: token, role: role, clientID: clientID, caregiverID: caregiverID,
                       chatID: chatID, partnerName: partnerName)
    }

    private func userID(_ row: [String: Any], side: String) -> String {
        let user = (row[side] as? [String: Any])?["user"] as? [String: Any]
        return user?["id"].map { String(describing: $0) } ?? ""
    }

    private func verifiedFull(chatID: Int, token: String, clientID: String, caregiverID: String) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/chats/\(chatID)", token: token)
        XCTAssertEqual(response.status, 200, "Owned conversation metadata must be readable")
        let full = try XCTUnwrap(response.body["result"] as? [String: Any])
        XCTAssertTrue((full["id"] as? Int) == chatID)
        XCTAssertTrue(userID(full, side: "client") == clientID && userID(full, side: "caregiver") == caregiverID,
                      "Refusing a conversation outside the exact owned pair")
        return full
    }

    private func count(_ route: String) -> Int {
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.exists, "Actual native request ledger missing")
        let prefix = route + "="
        return ledger.label.split(separator: "\n").first { $0.hasPrefix(prefix) }
            .flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
    }

    private func attachField(_ field: XCUIElement, name: String) {
        XCTAssertTrue(field.exists && field.isHittable && app.frame.contains(field.frame))
        let attachment = XCTAttachment(screenshot: field.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func replyBannerContains(_ text: String, near field: XCUIElement) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label == %@", text)).allElementsBoundByIndex.contains {
            $0.isHittable && $0.frame.maxY <= field.frame.minY && $0.frame.minY >= field.frame.minY - 100
        }
    }

    private func record(role: String, reset: Bool, sendAttempts: Int, replyCovered: Bool, replyReset: Bool, sendDisabled: Bool) {
        let data: [String: Any] = ["case": "P08-007", "role": role, "navigation": "Back-to-Messages-and-revisit",
            "expectedRevisitBehavior": "empty-draft-no-selected-reply-Send-disabled",
            "nativeDraftResetToExactEmptyPlaceholder": reset, "nativeSendPOSTs": sendAttempts,
            "exactUnchangedSyntheticBaselineVerifiedImmediatelyBeforeBack": true,
            "syntheticTextAbsentFromBackend": true, "ownedPairIndependentlyVerified": true,
            "replySelectionCovered": replyCovered, "nativeSelectedReplyAbsentAfterRevisit": replyReset,
            "nativeSendDisabledAfterRevisit": sendDisabled,
            "AndroidExpectationBasis": "decompiled-APK-composer-state-and-popBackStack-source",
            "AndroidRuntimeExecuted": false,
            "processRelaunchCovered": false]
        guard let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else {
            XCTFail("Could not encode anonymous draft evidence"); return
        }
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "P08-007-unsent-draft-revisit-\(role)"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
