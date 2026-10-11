import XCTest

/// End-to-end flows against the live Carezaar backend. Credentials come from the
/// environment (`QA_EMAIL`, `QA_PASSWORD`, passed as `TEST_RUNNER_*`) so nothing
/// secret is committed. Each run uses isolated role fixtures; history may be empty.
final class CarezaarUITests: XCTestCase {
    var app: XCUIApplication!
    var email: String { ProcessInfo.processInfo.environment["QA_EMAIL"] ?? "" }
    var password: String { ProcessInfo.processInfo.environment["QA_PASSWORD"] ?? "" }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        // A quarantined test must not inspect or capture an unrelated live screen.
        guard testRun?.hasBeenSkipped != true else { return }
        if let run = testRun, run.hasSucceeded == false { dump("failure") }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    func dump(_ tag: String) { print("UI-\(tag): buttons=\(app.buttons.count), textFields=\(app.textFields.count), navigationBars=\(app.navigationBars.count)") }

    private func launchSignedIn(_ extra: [String] = []) {
        app.launchArguments = ["--qa-signout", "--qa-login-env"] + extra
        app.launchEnvironment["QA_EMAIL"] = email
        app.launchEnvironment["QA_PASSWORD"] = password
        app.launch()
        allowNotificationsIfAsked()
        // Either Main itself, or the screen pushed on top of it by `--qa-push`.
        let ready = extra.contains("--qa-push") ? app.buttons["BackButton"] : app.buttons["Messages"]
        XCTAssertTrue(ready.waitForExistence(timeout: 40), "Main did not appear")
    }

    private func text(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func textContaining(_ fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// Bottom-bar tab (the avatar in the top bar shares the "Profile" label).
    private func openTab(_ label: String) {
        // While a system sheet is transitioning the hierarchy can list the window
        // twice; only a hittable copy can be tapped.
        var tab: XCUIElement?
        for _ in 0..<25 where tab == nil {
            tab = app.buttons.matching(identifier: label).allElementsBoundByIndex
                .filter { $0.isHittable }.max { $0.frame.minY < $1.frame.minY }
            if tab == nil { usleep(200_000) }
        }
        XCTAssertNotNil(tab); tab?.tap()
    }

    private func scrollTo(_ element: XCUIElement, max: Int = 8) {
        var n = 0
        while !element.isHittable && n < max { app.swipeUp(); n += 1 }
    }

    // MARK: - Flows

    /// Intro → Sign In (real typing) → Main → every tab → Log Out → Intro.
    func testSignInTabsAndLogOut() {
        app.launchArguments = ["--qa-signout"]
        app.launch()
        let signInLink = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(signInLink.waitForExistence(timeout: 40))
        signInLink.tap()

        let emailField = app.textFields["Enter your email address..."]
        XCTAssertTrue(emailField.waitForExistence(timeout: 10))
        let submit = app.buttons["Sign In"].firstMatch
        emailField.tap(); emailField.typeText(email)
        let pw = app.secureTextFields["Enter your password..."]
        pw.tap(); pw.typeText(password)
        submit.tap()
        allowNotificationsIfAsked()

        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 40), "sign in did not reach Main")
        // iOS offers to save the password after a real sign-in.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "mile(s) away")).firstMatch
            .waitForExistence(timeout: 30), "matches did not load after sign in")
        XCTAssertTrue(textContaining("My Matches").waitForExistence(timeout: 20))
        // iOS may offer to save the password a few seconds after a real sign-in; the
        // sheet swallows taps until dismissed.
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 8) { notNow.tap() }
        openTab("Messages")
        XCTAssertTrue(textContaining("All your conversations").waitForExistence(timeout: 10))

        openTab("Profile")
        XCTAssertTrue(textContaining("Manage your personal information").waitForExistence(timeout: 10))
        let logout = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Log Out")).firstMatch
        scrollTo(logout)
        logout.tap()
        let confirm = app.alerts.buttons["Confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["Sign in"].firstMatch.waitForExistence(timeout: 20), "did not return to Intro")
    }

    /// Wrong password shows the server's error toast and stays on Sign In.
    func testSignInWrongPassword() {
        app.launchArguments = ["--qa-signout"]
        app.launch()
        XCTAssertTrue(app.buttons["Sign in"].firstMatch.waitForExistence(timeout: 40))
        app.buttons["Sign in"].firstMatch.tap()
        let emailField = app.textFields["Enter your email address..."]
        XCTAssertTrue(emailField.waitForExistence(timeout: 10))
        emailField.tap(); emailField.typeText(email)
        let pw = app.secureTextFields["Enter your password..."]
        pw.tap(); pw.typeText("Wrong-Password-1!")
        app.buttons["Sign In"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Dismiss"].waitForExistence(timeout: 20), "no error toast")
        XCTAssertFalse(app.buttons["Messages"].exists)
    }

    /// Messages → chat → send a message → it appears in the transcript.
    func testChatSendMessage() throws {
        try XCTSkipIf(true, "Quarantined unsafe legacy fixture: Legacy live chat flow stages and deletes relationships without exact owned-fixture guard. Use the strict owned-fixture ChatNetworkBoundaryUITests or owned role-action tests instead.")

        // Sending needs an active match (the app, like Android, blocks messages to an
        // ended one): stage one with the QA caregiver and open the pair's chat.
        let env = ProcessInfo.processInfo.environment
        let cgToken = try CarezaarAPI.login(env["QA_CG_EMAIL"] ?? "", env["QA_CG_PASSWORD"] ?? "")
        let clToken = try CarezaarAPI.login(email, password)
        // The client's id from the API itself, not from the runner's environment.
        let clientId = "\(try CarezaarAPI.me(clToken)["id"] ?? "")"
        for type in ["matches", "requests"] {
            let list = try CarezaarAPI.call("GET", "users/matches?type=\(type)&page=1&perPage=50", token: cgToken)
            for m in list["result"] as? [[String: Any]] ?? [] {
                let clientUser = ((m["client"] as? [String: Any])?["user"] as? [String: Any])?["id"]
                guard let clientUser, "\(clientUser)" == clientId, let id = m["id"] else { continue }
                _ = try CarezaarAPI.call("DELETE", type == "matches" ? "users/matches/\(id)" : "users/matches/\(id)/withdraw", token: cgToken)
            }
        }
        let request = try CarezaarAPI.call("POST", "users/matches", form: ["partner_id": clientId], token: cgToken)
        let requestId = (request["result"] as? [String: Any])?["id"].map { "\($0)" } ?? ""
        _ = try CarezaarAPI.call("PATCH", "users/matches/\(requestId)/accept", token: clToken)
        let cgId = ((try CarezaarAPI.call("GET", "auth/info", token: cgToken))["result"] as? [String: Any])?["id"].map { "\($0)" } ?? ""
        let chat = try CarezaarAPI.call("POST", "users/chats", form: ["partner_id": cgId], token: clToken)
        let chatId = (chat["result"] as? [String: Any])?["id"].map { "\($0)" } ?? ""
        XCTAssertFalse(chatId.isEmpty, "chat staged")

        launchSignedIn(["--qa-push", "Chat/\(chatId)"])
        let field = app.textFields["Type a message..."]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let body = "iOS UI test \(Int(Date().timeIntervalSince1970))"
        field.tap(); field.typeText(body)
        app.buttons["Send"].tap()
        XCTAssertTrue(text(body).waitForExistence(timeout: 20), "sent message not shown")
        // Reply via the message menu.
        let options = app.buttons.matching(identifier: "Message options")
        options.element(boundBy: options.count - 1).tap()
        XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 5))
        app.buttons["Reply"].tap()
        field.tap(); field.typeText("threaded")
        app.buttons["Send"].tap()
        XCTAssertTrue(text("threaded").waitForExistence(timeout: 20))
        // The partner writes from their own device: the open chat shows it without
        // Refresh (it re-checks every 10 s; there is no push channel for iOS).
        let incoming = "from caregiver \(Int(Date().timeIntervalSince1970))"
        _ = try CarezaarAPI.call("POST", "users/chats/\(chatId)", form: ["message": incoming], token: cgToken)
        XCTAssertTrue(text(incoming).waitForExistence(timeout: 25), "incoming message did not appear without Refresh")
        // End the staged match so other runs start clean.
        _ = try CarezaarAPI.call("DELETE", "users/matches/\(requestId)", token: cgToken)
    }

    /// Matches: favourite a caregiver and undo it; change sort to Pay.
    func testFavoriteAndSort() throws {
        try XCTSkipIf(true, "Quarantined unsafe legacy fixture: Legacy favorite toggles an arbitrary listed user without exact owned-peer identity. Use the strict owned-fixture ChatNetworkBoundaryUITests or owned role-action tests instead.")

        launchSignedIn()
        let add = app.buttons["Add to favorites"].firstMatch
        let remove = app.buttons["Remove from favorites"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20) || remove.waitForExistence(timeout: 1))
        let startedOn = remove.exists
        (startedOn ? remove : add).tap()
        XCTAssertTrue((startedOn ? add : remove).waitForExistence(timeout: 15), "favourite did not toggle")
        (startedOn ? add : remove).tap()
        XCTAssertTrue((startedOn ? remove : add).waitForExistence(timeout: 15), "favourite did not toggle back")

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sort")).firstMatch.tap()
        let pay = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Pay")).firstMatch
        XCTAssertTrue(pay.waitForExistence(timeout: 5))
        pay.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sort (Pay")).firstMatch.waitForExistence(timeout: 15))
    }

    /// Request a Match opens its confirmation without a verification gate.
    /// The October 10 specification hides Message until an active match exists.
    func testNoBackgroundCheck() {
        launchSignedIn()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "mile(s) away")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        let request = app.buttons["Request a Match"]
        XCTAssertTrue(request.waitForExistence(timeout: 20))
        XCTAssertFalse(textContaining("Verified").exists, "verification badge on a profile")
        request.tap()
        XCTAssertTrue(app.navigationBars["Request a Match"].waitForExistence(timeout: 10), "Request a Match confirmation")
        XCTAssertFalse(app.navigationBars["Background Check"].exists)
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["Message"].exists, "Message must be absent before an active match")
        XCTAssertFalse(app.navigationBars["Background Check"].exists, "message gate")
        app.terminate()
        launchSignedIn(["--qa-tab", "profile"])
        XCTAssertTrue(textContaining("Manage your personal information").waitForExistence(timeout: 20))
        for word in ["Unverified", "Pending Verification", "Verified User", "Background Check"] {
            XCTAssertFalse(textContaining(word).exists, "\(word) on the Profile tab")
        }
    }

    /// Profile → Change Language → Français → UI copy switches; then back to English.
    func testChangeLanguage() {
        launchSignedIn(["--qa-push", "ChangeLanguage"])
        XCTAssertTrue(app.buttons["Français"].waitForExistence(timeout: 20))
        app.buttons["Français"].tap()
        app.buttons["Save Changes"].tap()
        XCTAssertTrue(app.buttons["Profil"].waitForExistence(timeout: 20), "French tab label missing")
        app.launchArguments = ["--qa-push", "ChangeLanguage"]
        app.launch()
        XCTAssertTrue(app.buttons["English"].waitForExistence(timeout: 30))
        app.buttons["English"].tap()
        app.buttons.element(matching: NSPredicate(format: "label == %@ OR label == %@", "Save Changes", "Enregistrer les modifications")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Profile"].waitForExistence(timeout: 20))
    }

    /// FAQ answers expand; Report an Issue validates Other → Subject.
    func testFaqAndReportIssueValidation() {
        launchSignedIn(["--qa-push", "FAQ"])
        let q = app.buttons["What is Carezaar?"]
        XCTAssertTrue(q.waitForExistence(timeout: 20))
        q.tap()
        XCTAssertTrue(textContaining("Carezaar is a platform").waitForExistence(timeout: 5), "answer did not expand")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 10))
        openTab("Profile")
        XCTAssertTrue(textContaining("Manage your personal information").waitForExistence(timeout: 10))
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report an Issue")).firstMatch
        scrollTo(report)
        report.tap()
        let fab = app.buttons["Report An Issue"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 20))
        fab.tap()
        XCTAssertTrue(app.buttons["Submit"].waitForExistence(timeout: 5))
        app.buttons["Submit"].tap()
        XCTAssertTrue(textContaining("Subject: ").waitForExistence(timeout: 5), "subject required toast")
    }

    /// Change Password: button disabled until rules pass and confirmation matches.
    func testChangePasswordValidation() {
        launchSignedIn(["--qa-push", "ChangePassword"])
        let button = app.buttons["Change Password"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        XCTAssertFalse(button.isEnabled)
        app.secureTextFields["Enter your current password..."].tap()
        app.secureTextFields["Enter your current password..."].typeText("whatever")
        app.secureTextFields["Enter your new password..."].tap()
        app.secureTextFields["Enter your new password..."].typeText("Abcdef1!")
        app.secureTextFields["Confirm your new password..."].tap()
        app.secureTextFields["Confirm your new password..."].typeText("Abcdef1?")
        XCTAssertTrue(textContaining("do not match").waitForExistence(timeout: 5))
        // The button steps aside while typing; the keyboard's OK brings it back.
        app.toolbars.buttons["OK"].tap()
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertFalse(button.isEnabled)
    }

    /// Profile → Matches history tabs; Help Center; Favorites; Notifications load.
    func testSecondaryScreensLoad() {
        launchSignedIn(["--qa-tab", "profile"])
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Matches")).element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 20))
        app.buttons["History"].tap()
        let historyLoaded = NSPredicate { _, _ in
            self.textContaining("Start:").exists || self.text("History (0)").exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: historyLoaded, object: nil)], timeout: 20), .completed, "History must load records or its explicit empty state")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Report an Issue only on Profile; Delete Account only under Help Center.
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report an Issue")).firstMatch
        scrollTo(report)
        XCTAssertTrue(report.exists, "Report an Issue missing from Profile")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Delete Account")).firstMatch.exists,
                       "Delete Account still on Profile")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Help Center")).firstMatch.tap()
        XCTAssertTrue(textContaining("support@carezaar.com").waitForExistence(timeout: 10))
        XCTAssertFalse(textContaining("Report an Issue").exists, "Report an Issue still in Help Center")
        let delete = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Delete Account")).firstMatch
        XCTAssertTrue(delete.exists, "Delete Account missing from Help Center")
        delete.tap()
        XCTAssertTrue(app.navigationBars["Delete Account"].waitForExistence(timeout: 10), "Help Center opens Delete Account")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let fav = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Favorites")).firstMatch
        scrollTo(fav); fav.tap()
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Notifications")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 10))
    }

    /// Match cards expose no actions; finished records expose no reviews. Backend
    /// history remains intact when review controls are removed.
    func testMatchesListAndHistoryWithoutReview() throws {
        let env = ProcessInfo.processInfo.environment
        let cgToken = try CarezaarAPI.login(env["QA_CG_EMAIL"] ?? "", env["QA_CG_PASSWORD"] ?? "")
        let caregiverUser = try CarezaarAPI.me(cgToken)
        let caregiverName = [caregiverUser["first_name"] as? String, caregiverUser["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
        let clientToken = try CarezaarAPI.login(email, password)
        let clientId = "\(try CarezaarAPI.me(clientToken)["id"] ?? "")"
        try CarezaarAPI.clearRelation(caregiverToken: cgToken, clientUserId: clientId)
        let request = CarezaarAPI.result(try CarezaarAPI.call("POST", "users/matches", form: ["partner_id": clientId], token: cgToken))
        let id = "\(request["id"] ?? "")"

        launchSignedIn(["--qa-push", "ManageMatches"])
        let requests = app.buttons["Requests"].firstMatch
        XCTAssertTrue(requests.waitForExistence(timeout: 20))
        for _ in 0..<5 where !requests.isSelected { requests.tap(); _ = requests.waitForSelected(timeout: 3) }
        XCTAssertTrue(textContaining(caregiverName).waitForExistence(timeout: 20), "request card")
        for label in ["Accept", "Reject", "Withdraw", "Cancel", "Unmatch"] {
            XCTAssertFalse(app.buttons[label].exists, "\(label) on a request card")
        }
        _ = try CarezaarAPI.call("PATCH", "users/matches/\(id)/accept", token: clientToken)
        app.buttons["Matches"].firstMatch.tap()
        XCTAssertTrue(textContaining(caregiverName).waitForExistence(timeout: 20), "match card")
        XCTAssertFalse(app.buttons["Unmatch"].exists, "Unmatch on a match card")
        _ = try CarezaarAPI.call("DELETE", "users/matches/\(id)", token: clientToken)

        app.buttons["History"].tap()
        XCTAssertTrue(textContaining(caregiverName).waitForExistence(timeout: 20), "finished match preserved in history")
        XCTAssertFalse(app.buttons["Review"].exists, "history must not expose reviews")
        XCTAssertFalse(app.buttons["Submit"].exists, "history must not expose review submission")
        XCTAssertFalse(app.textFields.firstMatch.exists, "history must not expose review comment input")
    }

    /// Deletes the signed-in account through the UI. Run only with a disposable
    /// account created by `SignupTests` (never with the shared QA accounts).
    func testDeleteAccount() throws {
        // Only when the run says this account is meant to go: the cross-role accounts are
        // disposable too, but later suites still need them.
        try XCTSkipUnless(email.hasPrefix("carezaarios") && ProcessInfo.processInfo.environment["QA_ALLOW_DELETE"] == "1",
                          "only a disposable account marked for deletion is deleted")
        launchSignedIn(["--qa-push", "DeleteAccount"])
        try deleteThroughUI(email: email, password: password)
    }

    /// Delete Account: the reason and the awareness checkbox are both required, the
    /// reasons are the user's role's own, and success signs out for good.
    func deleteThroughUI(email: String, password: String, clientReason: String = "I found care elsewhere") throws {
        let delete = app.buttons["Delete Account"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 20))
        XCTAssertFalse(delete.isEnabled, "delete must wait for a reason and the checkbox")
        let aware = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "aware")).firstMatch
        aware.tap()
        XCTAssertFalse(delete.isEnabled, "delete must wait for a reason")
        app.buttons["Select a reason"].tap()
        let reason = app.buttons[clientReason]
        XCTAssertTrue(reason.waitForExistence(timeout: 5), "client reasons listed")
        XCTAssertFalse(app.buttons["I found a job"].exists, "caregiver reasons must be filtered out")
        reason.tap()
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        XCTAssertTrue(app.buttons["Sign in"].firstMatch.waitForExistence(timeout: 40), "not signed out after delete")
        XCTAssertTrue(try CarezaarAPI.login(email, password).isEmpty, "deleted account still signs in")
    }

    /// Gallery → square crop → the cropped photo replaces the placeholder.
    /// Preferences step 2 follows the Figma frame (746:11740): services as a grid of
    /// icon tiles, and Preferred Language right after the qualities.
    func testPreferencesNeedsStepLayout() {
        // The wizard has its own header, so wait for its button rather than BackButton.
        app.launchArguments = ["--qa-signout", "--qa-login", email, password, "--qa-push", "ClientPreferences"]
        app.launch()
        allowNotificationsIfAsked()
        let next = app.buttons["Continue"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 40)); next.tap()
        let bathing = app.buttons["Bathing"].firstMatch
        XCTAssertTrue(bathing.waitForExistence(timeout: 10), "service tiles")
        let feeding = app.buttons["Feeding"].firstMatch
        XCTAssertEqual(bathing.frame.minY, feeding.frame.minY, accuracy: 2, "four tiles share the first row")
        if let dir = ProcessInfo.processInfo.environment["QA_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir + "/prefs-needs.png"))
        }
        let language = text("Preferred Language"), experience = text("Minimum Experience")
        scrollTo(experience)
        XCTAssertLessThan(language.frame.minY, experience.frame.minY, "language section precedes experience")
    }

    func testPhotoPickAndCrop() {
        launchSignedIn(["--qa-push", "ProfileEdit"])
        let upload = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Photo")).firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 20))
        upload.tap()
        let gallery = app.buttons["Gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5)); gallery.tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "photo grid")
        let onboarding = app.buttons["Close"]
        if onboarding.exists { onboarding.tap() }
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let confirm = app.buttons["Confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "crop screen")
        app.swipeLeft()                       // reposition inside the square
        if let dir = ProcessInfo.processInfo.environment["QA_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir + "/crop-screen.png"))
        }
        confirm.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Remove Photo")).firstMatch
            .waitForExistence(timeout: 10), "cropped photo not applied")
        if let dir = ProcessInfo.processInfo.environment["QA_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir + "/crop-applied.png"))
        }
    }

    /// The app asks for notification permission after sign-in (Android's poll posts a
    /// system notification); the system alert must be answered before other taps.
    func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        // The request comes right after sign-in, so it can land after the screen shows.
        if allow.waitForExistence(timeout: 8) { allow.tap(); sleep(1) }
    }
}
