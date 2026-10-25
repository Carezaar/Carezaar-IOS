import XCTest

/// Loading UI, duplicate actions and Idempotency-Key (client request, 25 Oct 2026), on the live
/// API with the owned QA pair (QA_CLIENT_* / QA_CG_*), run as the client. Each test stages its
/// own match (and chat) through the API and ends it. Every message says "Synthetic".
/// Requests are counted by the Debug ledger (`--qa-request-counts`, including how many
/// different Idempotency-Key values a path has seen); the server is read to count what it stored.
final class LoadingIdempotencyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment
    private var clientToken = "", caregiverToken = "", clientID = "", caregiverID = ""
    private var stagedMatch: Int?

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let ce = env["QA_CLIENT_EMAIL"], let cp = env["QA_CLIENT_PASSWORD"],
              let ge = env["QA_CG_EMAIL"], let gp = env["QA_CG_PASSWORD"],
              let cid = env["QA_CLIENT_USER_ID"], let gid = env["QA_CG_ID"] else { throw XCTSkip("Owned QA pair required") }
        clientToken = try CarezaarAPI.login(ce, cp); caregiverToken = try CarezaarAPI.login(ge, gp)
        clientID = cid; caregiverID = gid
        try endPair()
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        try? endPair()
    }

    // MARK: staging

    private func pairMatches(_ type: String) throws -> [[String: Any]] {
        let r = try CarezaarAPI.call("GET", "users/matches?type=\(type)&page=1&perPage=50", token: clientToken)
        return ((r["result"] as? [[String: Any]]) ?? []).filter { row in
            let data = (try? JSONSerialization.data(withJSONObject: row)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return data.contains(caregiverID)
        }
    }
    private func endPair() throws {
        for m in try pairMatches("matches") { _ = try? CarezaarAPI.callWithHTTPStatus("DELETE", "users/matches/\(m["id"] as? Int ?? 0)", token: clientToken) }
        for m in try pairMatches("requests") {
            let token = (m["is_client_accepted"] as? Bool) == true ? clientToken : caregiverToken
            _ = try? CarezaarAPI.callWithHTTPStatus("DELETE", "users/matches/\(m["id"] as? Int ?? 0)/withdraw", token: token)
        }
    }
    /// The caregiver requests the client; returns the request id.
    private func stageRequest() throws -> Int {
        _ = try CarezaarAPI.callWithHTTPStatus("POST", "users/matches", form: ["partner_id": clientID], token: caregiverToken)
        let id = try XCTUnwrap(try pairMatches("requests").first?["id"] as? Int)
        stagedMatch = id
        return id
    }
    /// An active match with an open conversation; returns the chat id.
    private func stageChat() throws -> Int {
        let id = try stageRequest()
        let accepted = try CarezaarAPI.callWithHTTPStatus("PATCH", "users/matches/\(id)/accept", token: clientToken)
        XCTAssertTrue((200..<300).contains(accepted.status))
        let chat = try CarezaarAPI.call("POST", "users/chats", form: ["partner_id": caregiverID], token: clientToken)
        return try XCTUnwrap((chat["result"] as? [String: Any])?["id"] as? Int)
    }
    private func serverMessages(_ chat: Int, _ text: String) throws -> Int {
        let r = try CarezaarAPI.call("GET", "users/chats/\(chat)", token: clientToken)
        let messages = ((r["result"] as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
        return messages.filter { $0["message"] as? String == text }.count
    }

    // MARK: app

    private func launch(_ push: String?, faults: [String] = []) {
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = env["QA_CLIENT_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_CLIENT_PASSWORD"]
        app.launchEnvironment["OS_ACTIVITY_DT_MODE"] = "NO"
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
            + (push.map { ["--qa-push", $0] } ?? []) + faults
        app.launch()
    }
    private func ledger() -> [String: Int] {
        let element = app.staticTexts.matching(identifier: "qa-request-counts").firstMatch
        guard element.exists else { return [:] }
        var out: [String: Int] = [:]
        for line in element.label.split(separator: "\n") {
            guard let eq = line.lastIndex(of: "="), let n = Int(line[line.index(after: eq)...]) else { continue }
            out[String(line[..<eq])] = n
        }
        return out
    }
    private func count(_ key: String) -> Int { ledger()[key] ?? 0 }
    private func waitFor(_ timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout) == .completed
    }
    private var pleaseWait: XCUIElement { app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch }
    private var skeleton: XCUIElement { app.descendants(matching: .any).matching(identifier: "skeleton").firstMatch }
    private var send: XCUIElement { app.buttons.matching(identifier: "chat-send").firstMatch }
    private var composer: XCUIElement { app.textFields.firstMatch }
    private func attach(_ name: String, _ facts: [String: Any]) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name + "-screen"; shot.lifetime = .keepAlways; add(shot)
        if let data = try? JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]) {
            let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); a.name = name; a.lifetime = .keepAlways; add(a)
        }
    }
    private func openChat(_ chat: Int, faults: [String] = []) {
        launch("Chat/\(chat)", faults: faults)
        XCTAssertTrue(composer.waitForExistence(timeout: 90))
        XCTAssertTrue(waitFor(60) { self.count("GET /api/users/chats/\(chat)") >= 1 && !self.skeleton.exists })
    }

    // MARK: tests

    func testFirstLoadsShowSkeletonsNeverTheLoadingWindow() throws {
        let chat = try stageChat()
        var sawWindow = false
        // Conversation, then the Messages list, Report an Issue and the partner's profile, on a slow network.
        for (route, ready) in [("Chat/\(chat)", { self.composer.exists && self.count("GET /api/users/chats/\(chat)") >= 1 }),
                               ("ReportAnIssue", { self.count("GET /api/users/issues") >= 1 }),
                               ("CaregiverDetails/\(caregiverID)", { self.app.buttons.matching(identifier: "match-unmatch").firstMatch.exists })] {
            launch(route, faults: ["--qa-latency", "3"])
            let shown = skeleton.waitForExistence(timeout: 30)
            XCTAssertTrue(shown, "\(route): a skeleton stands in for the first load")
            sawWindow = sawWindow || pleaseWait.exists
            XCTAssertTrue(waitFor(90, ready), "\(route): the content arrives")
            XCTAssertTrue(waitFor(10) { !self.skeleton.exists }, "\(route): the skeleton is gone once the content is there")
            sawWindow = sawWindow || pleaseWait.exists
            attach("skeleton-\(route.split(separator: "/").first!)", ["route": String(route.split(separator: "/").first!), "skeletonShown": shown, "loadingWindow": sawWindow])
        }
        XCTAssertFalse(sawWindow, "No blocking loading window")
    }

    func testRapidSendTapsSendOneMessageWithOneKey() throws {
        let chat = try stageChat()
        openChat(chat, faults: ["--qa-latency", "2"])
        let text = "Synthetic rapid \(UUID().uuidString.prefix(8))"
        composer.tap(); composer.typeText(text)
        send.tap()
        let disabled = !send.isEnabled
        for _ in 0..<4 { if send.isHittable { send.tap() } }
        XCTAssertTrue(waitFor(30) { ((self.composer.value as? String) ?? "") != text })
        sleep(2)
        let posts = count("POST /api/users/chats/\(chat)"), keys = count("KEYS POST /api/users/chats/\(chat)")
        let stored = try serverMessages(chat, text)
        attach("rapid-send", ["posts": posts, "keys": keys, "stored": stored, "disabledAtOnce": disabled, "loadingWindow": pleaseWait.exists])
        XCTAssertTrue(disabled, "Send disables at once")
        XCTAssertEqual(posts, 1); XCTAssertEqual(keys, 1); XCTAssertEqual(stored, 1)
        XCTAssertFalse(pleaseWait.exists)
    }

    func testLostAnswerKeepsTheTextAndTheRetryReusesTheKeySoTheServerKeepsOne() throws {
        let chat = try stageChat()
        openChat(chat, faults: ["--qa-lose-answer", "POST", "/api/users/chats/\(chat)", "1"])
        let text = "Synthetic lost \(UUID().uuidString.prefix(8))"
        composer.tap(); composer.typeText(text)
        send.tap()
        XCTAssertTrue(waitFor(30) { self.count("QA lost-answer") == 1 })
        XCTAssertTrue(waitFor(15) { self.send.isEnabled })
        let kept = composer.value as? String
        let note = app.descendants(matching: .any).matching(identifier: "chat-unconfirmed-note").firstMatch.waitForExistence(timeout: 5)
        send.tap()
        XCTAssertTrue(waitFor(30) { ((self.composer.value as? String) ?? "") != text })
        sleep(2)
        let posts = count("POST /api/users/chats/\(chat)"), keys = count("KEYS POST /api/users/chats/\(chat)")
        let stored = try serverMessages(chat, text)
        let shown = app.staticTexts.matching(NSPredicate(format: "label == %@", text)).count
        attach("lost-answer", ["posts": posts, "keys": keys, "stored": stored, "keptText": kept == text, "note": note, "shown": shown])
        XCTAssertEqual(kept, text, "The text stays after the lost answer")
        XCTAssertTrue(note, "Says the message may not have been sent")
        XCTAssertEqual(posts, 2); XCTAssertEqual(keys, 1, "Both attempts sent the same key")
        XCTAssertEqual(stored, 1, "The server kept the message once")
        XCTAssertEqual(shown, 1)
    }

    func testAfterARestartTheUnconfirmedMessageIsOfferedAgainAndSentWithItsKey() throws {
        let chat = try stageChat()
        openChat(chat, faults: ["--qa-lose-answer", "POST", "/api/users/chats/\(chat)", "1"])
        let text = "Synthetic restart \(UUID().uuidString.prefix(8))"
        composer.tap(); composer.typeText(text)
        send.tap()
        XCTAssertTrue(waitFor(30) { self.count("QA lost-answer") == 1 })
        // Restart (no fault this time): the box shows the message again, with the note.
        openChat(chat)
        let restored = waitFor(15) { (self.composer.value as? String) == text }
        let note = app.descendants(matching: .any).matching(identifier: "chat-unconfirmed-note").firstMatch.waitForExistence(timeout: 5)
        send.tap()
        XCTAssertTrue(waitFor(30) { ((self.composer.value as? String) ?? "") != text })
        sleep(2)
        let stored = try serverMessages(chat, text)
        attach("restart", ["restored": restored, "note": note, "stored": stored, "keysAfterRestart": count("KEYS POST /api/users/chats/\(chat)")])
        XCTAssertTrue(restored); XCTAssertTrue(note)
        XCTAssertEqual(stored, 1, "Sent with the same key: the server kept it once")
    }

    func testTheSameTextTwiceOnPurposeIsTwoMessages() throws {
        let chat = try stageChat()
        openChat(chat)
        let text = "Synthetic twice \(UUID().uuidString.prefix(8))"
        for _ in 0..<2 {
            composer.tap(); composer.typeText(text); send.tap()
            XCTAssertTrue(waitFor(30) { ((self.composer.value as? String) ?? "").isEmpty || (self.composer.value as? String) == self.composer.placeholderValue })
        }
        sleep(2)
        let keys = count("KEYS POST /api/users/chats/\(chat)"), stored = try serverMessages(chat, text)
        attach("twice", ["keys": keys, "stored": stored])
        XCTAssertEqual(keys, 2); XCTAssertEqual(stored, 2)
    }

    func testLeavingAndReturningDuringASendCannotSendItTwice() throws {
        let chat = try stageChat()
        openChat(chat, faults: ["--qa-latency", "4"])
        let text = "Synthetic navigate \(UUID().uuidString.prefix(8))"
        composer.tap(); composer.typeText(text)
        send.tap()
        app.navigationBars.buttons.firstMatch.tap() // Back, then the conversation again from Messages
        let messagesTab = app.buttons.matching(NSPredicate(format: "label == %@", "Messages")).allElementsBoundByIndex.last
        XCTAssertNotNil(messagesTab); messagesTab?.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ios")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The conversation in the Messages list")
        row.tap()
        XCTAssertTrue(send.waitForExistence(timeout: 30))
        let busyOnReturn = !send.isEnabled
        if send.isHittable { send.tap() }
        XCTAssertTrue(waitFor(40) { self.count("POST /api/users/chats/\(chat)") >= 1 && self.send.isEnabled })
        sleep(2)
        let posts = count("POST /api/users/chats/\(chat)"), stored = try serverMessages(chat, text)
        attach("navigate", ["posts": posts, "stored": stored, "busyOnReturn": busyOnReturn])
        XCTAssertEqual(posts, 1); XCTAssertEqual(stored, 1)
    }

    func testRapidIssueSubmitFilesOneIssueShownFromTheAnswer() throws {
        launch("ReportAnIssue", faults: ["--qa-latency", "2"])
        XCTAssertTrue(waitFor(60) { self.count("GET /api/users/issues") >= 1 && !self.skeleton.exists })
        let fab = app.buttons["Report An Issue"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 20)); fab.tap()
        let subject = app.textFields["Enter your issue subject..."]
        XCTAssertTrue(subject.waitForExistence(timeout: 20)); subject.tap(); subject.typeText("Synthetic QA check - please ignore")
        let description = "Automated duplicate-submit check by the developer. Please ignore. \(UUID().uuidString.prefix(8))"
        let field = app.textFields["Write your issue here..."]
        let body = field.waitForExistence(timeout: 5) ? field : app.textViews.firstMatch
        body.tap(); body.typeText(description)
        let submit = app.buttons.matching(identifier: "issue-submit").firstMatch
        let readsBefore = count("GET /api/users/issues")
        submit.tap()
        let disabled = !submit.isEnabled
        for _ in 0..<3 { if submit.exists && submit.isHittable { submit.tap() } }
        XCTAssertTrue(waitFor(40) { !submit.exists })
        sleep(2)
        let posts = count("POST /api/users/issues"), keys = count("KEYS POST /api/users/issues")
        let shown = app.staticTexts[description].exists
        let r = try CarezaarAPI.call("GET", "users/issues", token: clientToken)
        let stored = ((r["result"] as? [[String: Any]]) ?? []).filter { $0["description"] as? String == description }.count
        attach("issue", ["posts": posts, "keys": keys, "stored": stored, "shown": shown, "reloads": count("GET /api/users/issues") - readsBefore, "disabled": disabled])
        XCTAssertTrue(disabled); XCTAssertEqual(posts, 1); XCTAssertEqual(keys, 1); XCTAssertEqual(stored, 1)
        XCTAssertTrue(shown, "The new issue is shown from the server's answer")
    }

    func testAcceptAndRejectOnTheSameMatchNeverBothRun() throws {
        _ = try stageRequest()
        launch("CaregiverDetails/\(caregiverID)", faults: ["--qa-latency", "3"])
        let accept = app.buttons.matching(identifier: "match-accept").firstMatch
        let reject = app.buttons.matching(identifier: "match-reject").firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 90))
        accept.tap()
        let confirm = app.buttons.matching(identifier: "match-action-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.tap()
        sleep(1)
        let rejectDisabled = !reject.isEnabled
        if reject.exists && reject.isHittable { reject.tap(); if confirm.waitForExistence(timeout: 2) { confirm.tap() } }
        XCTAssertTrue(waitFor(60) { self.count("PATCH /api/users/matches/\(self.stagedMatch!)/accept") >= 1 })
        sleep(6)
        let accepts = count("PATCH /api/users/matches/\(stagedMatch!)/accept"), rejects = count("DELETE /api/users/matches/\(stagedMatch!)/reject")
        attach("accept-reject", ["accepts": accepts, "rejects": rejects, "rejectDisabled": rejectDisabled, "loadingWindow": pleaseWait.exists])
        XCTAssertTrue(rejectDisabled, "Reject is disabled while accepting")
        XCTAssertEqual(accepts, 1); XCTAssertEqual(rejects, 0)
    }

    func testMatchRequestSendsOneRequestWithAKey() throws {
        launch("CaregiverDetails/\(caregiverID)", faults: ["--qa-latency", "2"])
        let request = app.buttons.matching(identifier: "match-request").firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 90))
        request.tap()
        let confirm = app.buttons.matching(identifier: "match-request-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.tap()
        sleep(1)
        let disabled = !request.isEnabled
        if request.exists && request.isHittable { request.tap() }
        XCTAssertTrue(waitFor(60) { self.count("POST /api/users/matches") >= 1 })
        sleep(6)
        let posts = count("POST /api/users/matches"), keys = count("KEYS POST /api/users/matches")
        let pending = try pairMatches("requests").count
        attach("request", ["posts": posts, "keys": keys, "pendingOnServer": pending, "disabled": disabled])
        XCTAssertEqual(posts, 1); XCTAssertEqual(keys, 1); XCTAssertEqual(pending, 1)
    }
}
