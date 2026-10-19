import XCTest

/// The client's October 2026 match specification, end to end, with the client and the
/// caregiver on two simulators at the same time (`scripts/match-lifecycle.sh` starts
/// both methods). Every action is taken in the app; the server is read only to check
/// the result. Steps hand over through files in `QA_SIGNAL_DIR`.
///
///  1. Client: Request a Match → Cancel sends nothing → Request with an Introduction →
///     Pending Acceptance + Cancel.                                        → "requested"
///  2. Caregiver: the `match` notification opens the client's profile (Accept, Reject,
///     an introduction in confirmation); the Requests card has no buttons; Reject.  → "rejected"
///  3. Client: Request a Match again (no Introduction) → Cancel.        → "withdrawn"
///  4. Caregiver: Request a Match with an Introduction.                   → "cg-requested"
///  5. Client: Accept from the profile → "It's a Match!" → back to Unmatch; the Matches
///     card has no buttons and opens the profile.                         → "accepted"
///  6. Caregiver: the `match_accept` notification opens "It's a Match!" → View Profile →
///     Unmatch (Cancel keeps it) → Request a Match; the same notification again shows
///     the partner profile.                                     → "unmatched"
///  7. Client: the profile shows Request a Match; History has the ended match.
final class MatchLifecycleTests: XCTestCase {
    var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var run: String { env["QA_RUN"] ?? "solo" }

    /// Unicode, emoji, punctuation, and a second line to prove the preview boundary.
    private var introduction: String {
        "Hello from the iOS test \(run)! I care for my mother (82) — près de chez vous, 你好, مرحبا 👋🏽. Second sentence here.\nSecond line only in the full introduction."
    }

    private var clientMessage: String { "Hi from the client \(run) 😊 مرحبا" }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        if let run = testRun, run.failureCount > 0 { shot("zz-failure-\(name.contains("Client") ? "client" : "caregiver")") }
    }

    // MARK: Modes

    /// Both people on one simulator, signing out and in between steps. Used when the Mac
    /// can't hold two simulators at once.
    func testLifecycleOneDevice() throws {
        let t = try setUpRun()
        try clientRequests(t); try caregiverOpensAndRejects(t); try clientRequestsAgainAndCancels(t)
        try caregiverRequests(t); try clientAccepts(t); try clientChecksMatchesList(t)
        try caregiverOpensAcceptedAndReplies(t); try caregiverUnmatches(t); try clientSeesEnded(t)
    }

    /// The client's half, on its own simulator, in step with `testCaregiverSide`.
    func testClientSide() throws {
        let t = try setUpRun()
        signal("ready-client"); XCTAssertTrue(waitForSignal("ready-caregiver", timeout: 300))
        try clientRequests(t); signal("requested")
        XCTAssertTrue(waitForSignal("rejected", timeout: 500), "caregiver never rejected")
        try clientRequestsAgainAndCancels(t); signal("withdrawn")
        XCTAssertTrue(waitForSignal("cg-requested", timeout: 500), "caregiver never requested")
        try clientAccepts(t); try clientChecksMatchesList(t); signal("accepted")
        XCTAssertTrue(waitForSignal("unmatched", timeout: 500), "caregiver never unmatched")
        try clientSeesEnded(t)
    }

    /// The caregiver's half, on its own simulator.
    func testCaregiverSide() throws {
        try XCTSkipIf(true, "Quarantined unsafe legacy fixture: Legacy caregiver-side flow bypasses safe relation reset and can mutate existing requests. Use the strict owned-pair MatchActionBoundaryUITests or MatchStateMatrixUITests instead.")

        let t = try sessions()
        signal("ready-caregiver"); XCTAssertTrue(waitForSignal("ready-client", timeout: 300))
        XCTAssertTrue(waitForSignal("requested", timeout: 500), "client never requested")
        try caregiverOpensAndRejects(t); signal("rejected")
        XCTAssertTrue(waitForSignal("withdrawn", timeout: 500), "client never withdrew")
        try caregiverRequests(t); signal("cg-requested")
        XCTAssertTrue(waitForSignal("accepted", timeout: 500), "client never accepted")
        try caregiverOpensAcceptedAndReplies(t); try caregiverUnmatches(t); signal("unmatched")
    }

    // MARK: Steps

    private struct Run { let client: String; let caregiver: String; let clientId: String; let caregiverId: String; let clientName: String; let caregiverName: String }

    private func setUpRun() throws -> Run {
        let t = try sessions()
        try reset(t)
        return t
    }

    /// 1. Client: Cancel sends nothing; Match sends the Introduction → Pending Acceptance.
    private func clientRequests(_ t: Run) throws {
        signIn(env["QA_EMAIL"], env["QA_PASSWORD"], push: "CaregiverDetails/\(t.caregiverId)")
        let request = button("Request a Match")
        XCTAssertTrue(request.waitForExistence(timeout: 40), "none: Request a Match")
        assertAbsent(["Unverified", "Background Check", "Cancel", "Accept", "Unmatch"])
        shot("C1-profile-none")
        openSheet(request)
        XCTAssertTrue(app.staticTexts["match-request-heading"].waitForExistence(timeout: 10), "confirmation sheet")
        XCTAssertEqual(app.staticTexts["match-request-heading"].label, "Request a Match")
        XCTAssertTrue(text("They should accept your request").exists, "confirmation message")
        shot("C2-request-sheet")
        app.navigationBars.buttons["Cancel"].tap()
        sleep(3)
        XCTAssertEqual(try status(of: t.caregiverId, as: t.client), "none", "Cancel created a request")
        openSheet(request)
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(introduction)
        shot("C3-request-sheet-introduction")
        app.navigationBars.buttons["Match"].tap()
        XCTAssertTrue(text("Pending Acceptance").waitForExistence(timeout: 30), "sent: Pending Acceptance")
        XCTAssertTrue(button("Cancel").exists, "sent: Cancel")
        assertAbsent(["Request a Match", "Accept", "Unmatch"])
        XCTAssertFalse(text("Hello from the iOS test").exists, "outgoing profile must not show the Introduction")
        assertAbsent(["Message"])
        shot("C4-profile-sent")
        XCTAssertEqual(try status(of: t.caregiverId, as: t.client), "sent")
    }

    /// 2. Caregiver: the `match` notification opens the profile; the Requests card has no
    /// buttons; Reject asks first.
    private func caregiverOpensAndRejects(_ t: Run) throws {
        signIn(env["QA_CG_EMAIL"], env["QA_CG_PASSWORD"], push: "Notifications")
        let incoming = notificationRow("new match request")
        XCTAssertTrue(incoming.waitForExistence(timeout: 40), "caregiver: match notification")
        shot("G1-notifications")
        incoming.tap()
        XCTAssertTrue(button("Show").waitForExistence(timeout: 10), "notification detail first")
        XCTAssertFalse(button("Accept").exists, "notification tap navigated before Show")
        button("Show").tap()
        XCTAssertTrue(button("Accept").waitForExistence(timeout: 40), "match notification opens the profile")
        XCTAssertTrue(button("Reject").exists)
        assertAbsent(["Request a Match", "Unmatch", "Cancel"])
        XCTAssertFalse(text(introduction).exists, "profile must not show the request introduction")
        assertAbsent(["Message"])
        XCTAssertLessThanOrEqual(button("Reject").frame.minY, button("Accept").frame.minY, "Reject precedes Accept")
        if abs(button("Reject").frame.minY - button("Accept").frame.minY) < 4 {
            XCTAssertLessThan(button("Reject").frame.minX, button("Accept").frame.minX, "Reject first in English row")
        }
        shot("G2-profile-received")
        XCTAssertEqual(try status(of: t.clientId, as: t.caregiver), "received")

        signIn(env["QA_CG_EMAIL"], env["QA_CG_PASSWORD"], push: "ManageMatches")
        let requests = app.buttons["Requests"].firstMatch
        XCTAssertTrue(requests.waitForExistence(timeout: 20))
        for _ in 0..<5 where !requests.isSelected { requests.tap(); _ = requests.waitForSelected(timeout: 3) }
        let card = button(t.clientName)
        XCTAssertTrue(card.waitForExistence(timeout: 30), "request card")
        XCTAssertTrue(text("Hello from the iOS test").exists, "Introduction preview on the card")
        assertAbsent(["Accept", "Reject", "Cancel", "Unmatch"])
        shot("G3-requests-card")
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "match-introduction-")).firstMatch
        XCTAssertTrue(preview.exists, "separate introduction preview control")
        XCTAssertFalse(preview.label.contains("Second line only"), "preview includes a later line")
        preview.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "match-introduction-detail").firstMatch.waitForExistence(timeout: 10), "preview opens introduction modal")
        XCTAssertTrue(text("Second line only").exists, "full introduction inside modal")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "match-introduction-detail").firstMatch.staticTexts[t.clientName].exists, "partner name inside introduction modal")
        XCTAssertFalse(app.buttons["match-reject"].exists, "preview navigated to profile")
        app.buttons["Cancel"].firstMatch.tap()
        card.tap()
        XCTAssertTrue(button("Reject").waitForExistence(timeout: 30), "card opens the profile")
        button("Reject").tap()
        XCTAssertTrue(alert().waitForExistence(timeout: 5), "Reject asks first")
        XCTAssertTrue(alert().staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Second line only")).firstMatch.exists, "Reject includes full introduction")
        XCTAssertTrue(alert().buttons["Reject"].firstMatch.exists, "Reject action label")
        shot("G4-reject-confirm")
        alert().buttons["Cancel"].firstMatch.tap()
        sleep(2)
        XCTAssertEqual(try status(of: t.clientId, as: t.caregiver), "received", "Cancel rejected")
        button("Reject").tap()
        alert().buttons["Reject"].firstMatch.tap()
        XCTAssertTrue(button("Request a Match").waitForExistence(timeout: 30), "rejected: Request a Match")
        XCTAssertEqual(try status(of: t.clientId, as: t.caregiver), "none")
    }

    /// 3. Client: request without an Introduction, then Cancel (Cancel keeps it).
    private func clientRequestsAgainAndCancels(_ t: Run) throws {
        signIn(env["QA_EMAIL"], env["QA_PASSWORD"], push: "CaregiverDetails/\(t.caregiverId)")
        XCTAssertTrue(button("Request a Match").waitForExistence(timeout: 30), "after reject: Request a Match")
        openSheet(button("Request a Match"))
        XCTAssertTrue(app.staticTexts["match-request-heading"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["match-request-heading"].label, "Request a Match")
        app.navigationBars.buttons["Match"].tap()
        XCTAssertTrue(button("Cancel").waitForExistence(timeout: 30))
        XCTAssertEqual(try status(of: t.caregiverId, as: t.client), "sent")
        button("Cancel").tap()
        XCTAssertTrue(alert().waitForExistence(timeout: 5), "Cancel asks first")
        shot("C5-withdraw-confirm")
        alert().buttons["Close"].firstMatch.tap()
        sleep(2)
        XCTAssertEqual(try status(of: t.caregiverId, as: t.client), "sent", "Cancel withdrew the request")
        button("Cancel").tap()
        alert().buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(button("Request a Match").waitForExistence(timeout: 30), "withdrawn: Request a Match")
        XCTAssertEqual(try status(of: t.caregiverId, as: t.client), "none")
    }

    /// 4. Caregiver: Request a Match with an Introduction.
    private func caregiverRequests(_ t: Run) throws {
        signIn(env["QA_CG_EMAIL"], env["QA_CG_PASSWORD"], push: "ClientDetails/\(t.clientId)")
        XCTAssertTrue(button("Request a Match").waitForExistence(timeout: 30))
        openSheet(button("Request a Match"))
        XCTAssertTrue(app.staticTexts["match-request-heading"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["match-request-heading"].label, "Request a Match")
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap(); field.typeText("Hi from the caregiver \(run). Available weekdays.")
        app.navigationBars.buttons["Match"].tap()
        XCTAssertTrue(text("Pending Acceptance").waitForExistence(timeout: 30))
        XCTAssertEqual(try status(of: t.clientId, as: t.caregiver), "sent")
    }

    /// 5. Client: the notification opens the profile; Accept → "It's a Match!" → chat.
    private func clientAccepts(_ t: Run) throws {
        signIn(env["QA_EMAIL"], env["QA_PASSWORD"], push: "Notifications")
        let incoming = notificationRow("new match request")
        XCTAssertTrue(incoming.waitForExistence(timeout: 40), "client: match notification")
        incoming.tap()
        XCTAssertTrue(button("Show").waitForExistence(timeout: 10), "notification detail first")
        XCTAssertFalse(button("Accept").exists, "notification tap navigated before Show")
        button("Show").tap()
        XCTAssertTrue(button("Accept").waitForExistence(timeout: 40), "match notification opens the profile")
        XCTAssertTrue(button("Reject").exists)
        XCTAssertFalse(text("Hi from the caregiver \(run)").exists, "introduction removed from profile")
        assertAbsent(["Message"])
        shot("C6-profile-received")
        button("Accept").tap()
        XCTAssertTrue(alert().waitForExistence(timeout: 5))
        XCTAssertTrue(alert().staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Hi from the caregiver")).firstMatch.exists, "Accept includes introduction")
        alert().buttons["Cancel"].firstMatch.tap()
        sleep(2)
        XCTAssertEqual(try status(of: t.caregiverId, as: t.client), "received", "Cancel accepted")
        button("Accept").tap()
        alert().buttons["Accept"].firstMatch.tap()
        XCTAssertTrue(text("have matched!").waitForExistence(timeout: 40), "Accept opens It's a Match!")
        XCTAssertTrue(app.staticTexts["It's a Match!"].exists || app.navigationBars["It's a Match!"].exists, "title")
        XCTAssertTrue(text("You and " + t.caregiverName).exists, "partner full name in the prompt")
        XCTAssertTrue(text("You").exists, "current user card labelled You")
        XCTAssertTrue(text("Caregiver").exists && text("Client").exists, "both role labels")
        shot("C7-its-a-match")
        XCTAssertEqual(try status(of: t.caregiverId, as: t.client), "active")
        button("Send a Message").tap()
        XCTAssertTrue(app.textFields["Type a message..."].waitForExistence(timeout: 30), "Send a Message opens the chat")
        typeInComposer(clientMessage)
        app.buttons["Send"].tap()
        XCTAssertTrue(text(clientMessage).waitForExistence(timeout: 30), "message sent")
        shot("C7b-chat")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(button("View Profile").waitForExistence(timeout: 15), "back to It's a Match!")
        button("View Profile").tap()
        XCTAssertTrue(button("Unmatch").waitForExistence(timeout: 30), "active: Unmatch")
        assertAbsent(["Request a Match", "Cancel", "Accept", "Pending Acceptance"])
        shot("C8-profile-active")
    }

    /// Matches list: no action buttons; the card opens the profile.
    private func clientChecksMatchesList(_ t: Run) throws {
        signIn(env["QA_EMAIL"], env["QA_PASSWORD"], push: "ManageMatches")
        let card = button(t.caregiverName)
        XCTAssertTrue(card.waitForExistence(timeout: 30), "match card")
        assertAbsent(["Unmatch", "Accept", "Reject", "Cancel"])
        shot("C9-matches-list")
        card.tap()
        XCTAssertTrue(button("Unmatch").waitForExistence(timeout: 30), "card opens the profile")
    }

    /// 6a. Caregiver: `match_accept` opens "It's a Match!"; reply in the chat.
    private func caregiverOpensAcceptedAndReplies(_ t: Run) throws {
        signIn(env["QA_CG_EMAIL"], env["QA_CG_PASSWORD"], push: "Notifications")
        let accepted = notificationRow("has been accepted")
        XCTAssertTrue(accepted.waitForExistence(timeout: 40), "caregiver: match_accept notification")
        accepted.tap()
        XCTAssertTrue(button("Show").waitForExistence(timeout: 10))
        button("Show").tap()
        XCTAssertTrue(text("have matched!").waitForExistence(timeout: 40), "match_accept opens It's a Match!")
        shot("G5-its-a-match-from-notification")
        button("Send a Message").tap()
        XCTAssertTrue(text(clientMessage).waitForExistence(timeout: 30), "caregiver receives the client's message")
        typeInComposer("Reply from caregiver \(run) 😊")
        app.buttons["Send"].tap()
        XCTAssertTrue(text("Reply from caregiver \(run)").waitForExistence(timeout: 30), "reply sent")
        shot("G5b-chat-reply")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(button("View Profile").waitForExistence(timeout: 15))
    }

    /// 6b. Caregiver: Unmatch (Cancel keeps it); the old notification is now stale.
    private func caregiverUnmatches(_ t: Run) throws {
        button("View Profile").tap()
        XCTAssertTrue(button("Unmatch").waitForExistence(timeout: 30), "active: Unmatch")
        button("Unmatch").tap()
        XCTAssertTrue(alert().waitForExistence(timeout: 5), "Unmatch asks first")
        alert().buttons["Cancel"].firstMatch.tap()
        sleep(2)
        XCTAssertEqual(try status(of: t.clientId, as: t.caregiver), "active", "Cancel unmatched")
        button("Unmatch").tap()
        alert().buttons["Unmatch"].firstMatch.tap()
        XCTAssertTrue(button("Request a Match").waitForExistence(timeout: 30), "unmatched: Request a Match")
        XCTAssertEqual(try status(of: t.clientId, as: t.caregiver), "none")
        shot("G6-profile-after-unmatch")
        signIn(env["QA_CG_EMAIL"], env["QA_CG_PASSWORD"], push: "Notifications")
        XCTAssertTrue(notificationRow("has been accepted").waitForExistence(timeout: 40))
        notificationRow("has been accepted").tap()
        XCTAssertTrue(button("Show").waitForExistence(timeout: 10))
        button("Show").tap()
        XCTAssertTrue(button("Request a Match").waitForExistence(timeout: 40), "inactive matched notification opens partner profile")
        XCTAssertFalse(text("no longer active").exists, "obsolete stale error")
        shot("G7-stale-notification")
    }

    /// 7. Client: Request a Match again; the reply arrived; History has the ended match.
    private func clientSeesEnded(_ t: Run) throws {
        let list = (try CarezaarAPI.call("GET", "users/chats?page=1&perPage=10", token: t.client)["result"] as? [[String: Any]]) ?? []
        XCTAssertTrue(list.contains { "\($0["last_message"] ?? "")".contains("Reply from caregiver \(run)") },
                      "the caregiver's reply did not reach the client")
        signIn(env["QA_EMAIL"], env["QA_PASSWORD"], push: "CaregiverDetails/\(t.caregiverId)")
        XCTAssertTrue(button("Request a Match").waitForExistence(timeout: 30), "ended: Request a Match")
        XCTAssertEqual(try status(of: t.caregiverId, as: t.client), "none")
        shot("C10-profile-after-unmatch")
        signIn(env["QA_EMAIL"], env["QA_PASSWORD"], push: "ManageMatches")
        app.buttons["History"].firstMatch.tap()
        XCTAssertTrue(button(t.caregiverName).waitForExistence(timeout: 30), "ended match in History")
        XCTAssertFalse(button("Review").exists, "history exposes review control")
        XCTAssertFalse(app.buttons["Submit"].exists, "history exposes review submission")
        shot("C11-history")
    }

    /// Contradictory metadata offers the standard check window, no replacement action.
    /// Retrying checks the profile only, never sends a mutation.
    func testInconsistentMatchStateOffersNoAction() throws {
        let t = try sessions()
        try reset(t)
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"] ?? ""
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"] ?? ""
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-push", "CaregiverDetails/\(t.caregiverId)", "--qa-corrupt-match-state"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        XCTAssertTrue(app.alerts["Couldn't check this match"].waitForExistence(timeout: 40), "standard failed-check window")
        let retry = app.alerts.buttons["Try Again"].firstMatch
        XCTAssertTrue(retry.exists)
        for id in ["match-request", "match-withdraw", "match-accept", "match-reject", "match-unmatch"] {
            XCTAssertFalse(app.buttons[id].exists, "\(id) offered for an inconsistent state")
        }
        XCTAssertFalse(text("Pending Acceptance").exists, "a state was guessed from the inconsistent fields")
        shot("inconsistent-state")
        retry.tap(); sleep(3)
        XCTAssertTrue(app.alerts["Couldn't check this match"].waitForExistence(timeout: 10), "still inconsistent after read: failed-check window")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertFalse(button("Try Again").exists, "Try Again replaced profile action buttons")
        XCTAssertEqual(try status(of: t.caregiverId, as: t.client), "none", "something was sent")
    }

    /// Pulling an open profile no longer reloads it. The next explicit action checks
    /// server state and reports the relationship change instead of sending stale intent.
    func testProfilePullDoesNotReloadAndActionChecksState() throws {
        let tokens = try sessions()
        let cgId = "\(try CarezaarAPI.me(tokens.caregiver)["id"] ?? "")"
        let clId = "\(try CarezaarAPI.me(tokens.client)["id"] ?? "")"
        try reset(tokens)
        defer { try? reset(tokens) }
        signIn(env["QA_EMAIL"], env["QA_PASSWORD"], push: "CaregiverDetails/\(cgId)")
        XCTAssertTrue(button("Request a Match").waitForExistence(timeout: 40))
        _ = try CarezaarAPI.call("POST", "users/matches", form: ["partner_id": clId], token: tokens.caregiver)
        XCTAssertEqual(try status(of: cgId, as: tokens.client), "received")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
                   withVelocity: .slow, thenHoldForDuration: 0.6)
        sleep(3)
        XCTAssertFalse(button("Accept").exists, "pull unexpectedly reloaded profile")
        XCTAssertTrue(button("Request a Match").exists, "original profile state should remain visible")
        openSheet(button("Request a Match"))
        app.navigationBars.buttons["Match"].tap()
        XCTAssertTrue(text("This match has changed").waitForExistence(timeout: 15), "stale action did not report change")
        XCTAssertTrue(button("Accept").exists && button("Reject").exists, "action check updates relationship")
        XCTAssertEqual(try status(of: cgId, as: tokens.client), "received", "stale intent sent a mutation")
    }

    // MARK: Helpers

    private func sessions() throws -> Run {
        let client = try CarezaarAPI.login(env["QA_EMAIL"] ?? "", env["QA_PASSWORD"] ?? "")
        let caregiver = try CarezaarAPI.login(env["QA_CG_EMAIL"] ?? "", env["QA_CG_PASSWORD"] ?? "")
        let clientUser = try CarezaarAPI.me(client)
        let caregiverUser = try CarezaarAPI.me(caregiver)
        let expectedClientID = env["QA_CLIENT_USER_ID"] ?? ""
        let expectedCaregiverID = env["QA_CG_ID"] ?? ""
        guard !expectedClientID.isEmpty, !expectedCaregiverID.isEmpty,
              expectedClientID != expectedCaregiverID,
              "\(clientUser["id"] ?? "")" == expectedClientID,
              "\(caregiverUser["id"] ?? "")" == expectedCaregiverID,
              clientUser["role"] as? String == "client",
              caregiverUser["role"] as? String == "caregiver",
              clientUser["email"] as? String == env["QA_EMAIL"],
              caregiverUser["email"] as? String == env["QA_CG_EMAIL"] else {
            throw NSError(domain: "CarezaarOwnedFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cross-role mutation requires the exact distinct owned client and caregiver identities"])
        }
        func fullName(_ user: [String: Any]) -> String {
            [user["first_name"] as? String, user["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
        }
        return Run(client: client, caregiver: caregiver,
                   clientId: "\(clientUser["id"] ?? "")", caregiverId: "\(caregiverUser["id"] ?? "")",
                   clientName: fullName(clientUser), caregiverName: fullName(caregiverUser))
    }

    /// Starts from no connection, so the run is repeatable.
    private func reset(_ tokens: Run) throws {
        throw XCTSkip("Quarantined unsafe legacy fixture: Legacy reset withdraws, rejects or deletes an existing relationship without test-created provenance. Use the strict owned-pair MatchActionBoundaryUITests or MatchStateMatrixUITests instead.")
    }

    /// `match_status` of the other person's profile, as the viewer sees it.
    private func status(of partnerId: String, as token: String) throws -> String {
        let viewerRole = "\(try CarezaarAPI.me(token)["role"] ?? "")"
        let profile = CarezaarAPI.result(try CarezaarAPI.call(
            "GET", viewerRole == "client" ? "clients/caregivers/\(partnerId)" : "caregivers/clients/\(partnerId)", token: token))
        return profile["match_status"] as? String ?? "?"
    }

    private func signIn(_ email: String?, _ password: String?, push: String) {
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = email ?? ""
        app.launchEnvironment["QA_PASSWORD"] = password ?? ""
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-push", push]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        _ = busy.waitForNonExistence(timeout: 40)
    }

    private var busy: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch
    }

    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    private func text(_ fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func alert() -> XCUIElement { app.alerts.firstMatch }

    /// Types into the chat field once it has keyboard focus; a tap right after the
    /// screen opens can land before the field accepts focus.
    private func typeInComposer(_ text: String) {
        let field = app.textFields.firstMatch
        var focused = false
        for _ in 0..<5 where !focused {
            field.tap()
            for _ in 0..<10 where !focused { usleep(200_000); focused = field.hasFocusCompat }
        }
        XCTAssertTrue(focused, "chat field never took focus")
        field.typeText(text)
    }

    /// Taps Request a Match once the busy card is gone; a tap while it shows is ignored.
    private func openSheet(_ request: XCUIElement) {
        for _ in 0..<3 where !app.staticTexts["match-request-heading"].exists {
            _ = busy.waitForNonExistence(timeout: 30)
            request.tap()
            _ = app.staticTexts["match-request-heading"].waitForExistence(timeout: 5)
        }
    }

    /// Newest first, so the first match is the latest notification of that kind.
    private func notificationRow(_ fragment: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func assertAbsent(_ labels: [String], line: UInt = #line) {
        for label in labels {
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch.exists
                           || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch.exists,
                           "unexpected \(label)", line: line)
        }
    }

    /// A finger's pull from the top of the content; a short swipe from the middle of a
    /// tall screen doesn't reach the refresh threshold.
    private func pullToRefresh(until element: XCUIElement) {
        for _ in 0..<3 where !element.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
                       withVelocity: .slow, thenHoldForDuration: 0.6)
            _ = element.waitForExistence(timeout: 8)
        }
    }

    private func signal(_ name: String) {
        guard let dir = env["QA_SIGNAL_DIR"], !dir.isEmpty else { return }
        try? Data().write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    }

    private func waitForSignal(_ name: String, timeout: TimeInterval) -> Bool {
        guard let dir = env["QA_SIGNAL_DIR"], !dir.isEmpty else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: "\(dir)/abort") { return false }
            if FileManager.default.fileExists(atPath: "\(dir)/\(name)") { return true }
            sleep(1)
        }
        return false
    }

    private func shot(_ name: String) {
        guard let dir = env["QA_SHOT_DIR"] else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
