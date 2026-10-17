import XCTest

/// October10 native profile/matched regressions. Read-only backend scenarios use
/// existing owned QA credentials from runner environment; no credentials in source
/// or launch arguments. Root executes these on the actual simulators.
final class ClientUpdateUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() { app?.terminate() }

    private func credentials(_ prefix: String = "QA") throws -> (String, String) {
        guard let email = env["\(prefix)_EMAIL"], !email.isEmpty,
              let password = env["\(prefix)_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Owned QA credentials missing from runner environment")
        }
        return (email, password)
    }

    private func caregiverID() throws -> String {
        if let id = env["QA_CG_ID"], !id.isEmpty { return id }
        let (email, password) = try credentials("QA_CG")
        let token = try CarezaarAPI.login(email, password)
        guard let id = try CarezaarAPI.me(token)["id"] as? String, !id.isEmpty else {
            throw XCTSkip("Owned caregiver identity unavailable")
        }
        return id
    }

    private func launch(_ route: String, extra: [String] = []) throws {
        let (email, password) = try credentials()
        app.launchEnvironment["QA_EMAIL"] = email
        app.launchEnvironment["QA_PASSWORD"] = password
        // These scenarios assert English managed controls. Native language
        // persistence is covered separately and may deliberately leave French
        // selected; establish this test's locale rather than depend on suite order.
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", route,
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"] + extra
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    private var counts: XCUIElement { app.staticTexts["qa-request-counts"] }

    private func waitForRequest(_ path: String, count: Int = 1) {
        XCTAssertTrue(counts.waitForExistence(timeout: 40), "Debug transport summary unavailable")
        let expected = "GET /api/\(path)=\(count)"
        let predicate = NSPredicate(format: "label CONTAINS %@", expected)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: counts)], timeout: 40)
        XCTAssertEqual(result, .completed, "Expected actual request count for \(path)")
    }

    /// Observe actual shared transport attempts, rather than treating a timer unit
    /// test as evidence of live navigation/logout behavior.
    /// October13 requires an immediate Main-opening poll, then one30s loop.
    func testNotificationPollingStartsImmediatelyAndUsesSingle30SecondLoopAcrossForegroundAndLogout() throws {
        try launch("")
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 40), "Main must actually open before its polling lifecycle is measured")
        func pollCount() -> Int {
            let prefix = "GET /api/users/notifications/count="
            guard let line = counts.label.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return 0 }
            return Int(line.dropFirst(prefix.count)) ?? -1
        }
        let initial = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in pollCount() == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [initial], timeout: 10), .completed)
        XCTAssertEqual(pollCount(), 1, "Opening Main must issue an immediate count request")
        let second = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in pollCount() == 2 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 40), .completed)
        let tickObserved = Date()
        let third = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in pollCount() >= 3 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [third], timeout: 40), .completed)
        XCTAssertEqual(pollCount(), 3, "Only one loop may advance the count")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(tickObserved), 28, "Consecutive ticks must retain the30s interval")
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in pollCount() == 4 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 10), .completed)
        let foregroundObserved = Date()
        let next = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in pollCount() >= 5 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [next], timeout: 40), .completed)
        XCTAssertEqual(pollCount(), 5, "Foreground must resume one loop")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(foregroundObserved), 28)
        var profile: XCUIElement?
        let profileReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            profile = self.app.buttons.matching(identifier: "Profile").allElementsBoundByIndex
                .filter { $0.isHittable }.max { $0.frame.minY < $1.frame.minY }
            return profile != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [profileReady], timeout: 10), .completed)
        let tab = try XCTUnwrap(profile, "Main's actual bottom Profile tab is required before logout")
        tab.tap()
        let logout = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Log Out")).firstMatch
        for _ in 0..<8 where !logout.isHittable { app.swipeUp() }
        XCTAssertTrue(logout.isHittable); logout.tap()
        XCTAssertTrue(app.alerts.buttons["Confirm"].waitForExistence(timeout: 5))
        app.alerts.buttons["Confirm"].tap()
        XCTAssertTrue(app.buttons["Sign in"].firstMatch.waitForExistence(timeout: 30))
        let stopped = pollCount()
        sleep(35)
        XCTAssertEqual(pollCount(), stopped, "Logout must stop notification requests")
    }

    func testCaregiverAllTypeBannerRotatesEveryFiveSecondsAndReentryHasOneTimer() throws {
        let (email, password) = try credentials()
        let token = try CarezaarAPI.login(email, password)
        XCTAssertEqual(try CarezaarAPI.me(token)["role"] as? String, "caregiver")
        try launch("")
        let state = app.staticTexts["qa-matches-header"]
        let expected = ["header_pregnancy", "header_senior", "header_adult", "header_child"]
        let configured = expected.joined(separator: ",") + ";current="
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in state.exists && state.label.hasPrefix(configured) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 45), .completed,
                       "The owned caregiver must be configured for all four supported client types")
        func current() -> String { state.label.components(separatedBy: ";current=").last ?? "" }
        func transition(after previous: String) throws -> (String, Date) {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in current() != previous }, object: nil)
            let outcome = XCTWaiter.wait(for: [changed], timeout: 7)
            if outcome != .completed {
                let diagnostic = XCTAttachment(string: "header=" + state.label + "\n" + counts.label)
                diagnostic.name = "banner-transition-diagnostic"; diagnostic.lifetime = .keepAlways; add(diagnostic)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "banner-transition-window-ui"; screenshot.lifetime = .keepAlways; add(screenshot)
            }
            XCTAssertEqual(outcome, .completed)
            return (current(), Date())
        }
        var last = current()
        var observed = try transition(after: last)
        var timestamp = observed.1
        last = observed.0
        for _ in 0..<4 {
            let next = try transition(after: last)
            let index = try XCTUnwrap(expected.firstIndex(of: last))
            XCTAssertEqual(next.0, expected[(index + 1) % expected.count])
            XCTAssertGreaterThanOrEqual(next.1.timeIntervalSince(timestamp), 4)
            XCTAssertLessThanOrEqual(next.1.timeIntervalSince(timestamp), 6.2)
            let screenshot = XCTAttachment(screenshot: app.descendants(matching: .any).matching(identifier: "matches-hero").firstMatch.screenshot())
            screenshot.name = "five-second-banner-" + next.0; screenshot.lifetime = .keepAlways; add(screenshot)
            last = next.0; timestamp = next.1
        }
        let messages = app.buttons["Messages"].firstMatch
        XCTAssertTrue(messages.isHittable); messages.tap()
        XCTAssertFalse(state.exists, "Leaving Matches must remove its rotation owner")
        sleep(6)
        let matches = app.buttons["Matches"].firstMatch
        XCTAssertTrue(matches.isHittable); matches.tap()
        XCTAssertTrue(state.waitForExistence(timeout: 15))
        last = current(); observed = try transition(after: last); timestamp = observed.1; last = observed.0
        let next = try transition(after: last)
        XCTAssertGreaterThanOrEqual(next.1.timeIntervalSince(timestamp), 4)
        XCTAssertLessThanOrEqual(next.1.timeIntervalSince(timestamp), 6.2)
        XCTAssertEqual(next.0, expected[(try XCTUnwrap(expected.firstIndex(of: last)) + 1) % expected.count])
    }

    func testProfileLoadsOnceAcrossPullAndForeground() throws {
        let id = try caregiverID()
        try launch("CaregiverDetails/\(id)")
        waitForRequest("clients/caregivers/\(id)")
        let action = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["match-request", "match-withdraw", "match-accept", "match-unmatch"])).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 40), "Actual profile must load before lifecycle checks")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        XCUIDevice.shared.press(.home)
        app.activate()
        sleep(3)
        let key = "GET /api/clients/caregivers/\(id)="
        let line = counts.label.split(separator: "\n").first { $0.hasPrefix(key) }
        XCTAssertEqual(line.map { String($0.dropFirst(key.count)) }, "1", "Profile reloaded on pull/foreground")
    }

    func testMissingProfileReturnsToPreviousScreenWithoutRetryPage() throws {
        let missingID = "qa-missing-profile-20261010"
        try launch("ManageMatches,CaregiverDetails/\(missingID)")
        waitForRequest("clients/caregivers/\(missingID)")
        let history = app.buttons["History"].firstMatch
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: history)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 20), .completed, "Failed profile did not automatically return")
        XCTAssertFalse(app.buttons["match-request"].exists)
        XCTAssertFalse(app.buttons["Try Again"].exists, "Failed profile left a full retry page")
    }

    func testMissingMatchedProfileReturnsWithoutRetryPage() throws {
        let missingID = "qa-missing-profile-20261010"
        try launch("ManageMatches,Matched/caregivers/\(missingID)")
        waitForRequest("clients/caregivers/\(missingID)")
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: app.buttons["History"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 20), .completed, "Failed matched screen did not return")
        XCTAssertFalse(app.buttons["Send a Message"].exists)
        XCTAssertFalse(app.buttons["Try Again"].exists)
    }

    func testInactiveMatchedRoutesToProfileWithoutConnectionGET() throws {
        let id = try caregiverID()
        let (email, password) = try credentials()
        let token = try CarezaarAPI.login(email, password)
        let profile = CarezaarAPI.result(try CarezaarAPI.call("GET", "clients/caregivers/\(id)", token: token))
        guard profile["match_status"] as? String != "active" else {
            throw XCTSkip("This read-only scenario requires the owned QA pair to be inactive")
        }
        try launch("Matched/caregivers/\(id)")
        let action = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["match-request", "match-withdraw", "match-accept", "match-reject"])).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 40), "Inactive success screen should open partner profile")
        XCTAssertFalse(app.buttons["Send a Message"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This match is no longer active")).firstMatch.exists)
        XCTAssertFalse(counts.label.contains("GET /api/users/matches/"), "Redundant connection lookup before matched screen")
    }
}

/// iOS and Android Parity Review v3.0 (16 Oct 2026): one test per finding that can be
/// driven through the UI. Accounts come from the runner environment (`PV3_*`);
/// `QA_SHOT_DIR` receives screenshots without credentials. `PV3_LANG` (1 English,
/// 3 Arabic) and `PV3_SIZE` (a content size category) repeat a run for RTL and
/// Dynamic Type; text assertions then use accessibility identifiers only.
final class ParityV3UITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var language: String { env["PV3_LANG"] ?? "1" }
    private var english: Bool { language == "1" }
    private var variant: String {
        (english ? "" : "-ar") + (env["PV3_SIZE"].map { $0.contains("Accessibility") ? "-axl" : "-\($0)" } ?? "")
    }

    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app?.terminate() }

    private func value(_ key: String) throws -> String {
        guard let v = env[key], !v.isEmpty else { throw XCTSkip("\(key) missing from runner environment") }
        return v
    }

    private func launch(_ extra: [String], email: String? = nil, password: String? = nil) {
        var args = ["--qa-signout", "-carezaar.languageId", language, "-carezaar.languageCode", english ? "en" : "ar"]
        if let size = env["PV3_SIZE"] { args += ["-UIPreferredContentSizeCategoryName", size] }
        if let email, let password {
            app.launchEnvironment["QA_EMAIL"] = email
            app.launchEnvironment["QA_PASSWORD"] = password
            args.append("--qa-login-env")
        }
        app.launchArguments = args + extra
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name + variant; attachment.lifetime = .keepAlways; add(attachment)
        if let dir = env["QA_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name)\(variant).png"))
        }
    }

    private func text(_ english: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", english)).firstMatch
    }

    private func requestCount(_ key: String) -> Int {
        let summary = app.staticTexts["qa-request-counts"].label
        guard let line = summary.split(separator: "\n").first(where: { $0.hasPrefix(key + "=") }) else { return 0 }
        return Int(line.dropFirst(key.count + 1)) ?? -1
    }

    private func waitFor(_ timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)],
                       timeout: timeout) == .completed
    }

    // MARK: A1 — notification permission asked at launch, before sign-in

    /// Run on a fresh install (the system asks only once per install).
    func testA1NotificationPermissionAskedAtLaunchAndAppContinuesWhenRefused() throws {
        guard env["PV3_FRESH_INSTALL"] == "1" else { throw XCTSkip("Needs a freshly installed app") }
        launch([])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Notifications")).firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "The notification prompt must appear at app launch, signed out")
        let shotImage = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shotImage); attachment.name = "A1-prompt-at-launch"; attachment.lifetime = .keepAlways; add(attachment)
        if let dir = env["QA_SHOT_DIR"] { try? shotImage.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/A1-prompt-at-launch.png")) }
        let deny = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
        deny.tap()
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "I need care")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 40), "The app must carry on after the permission is refused")
        shot("A1-welcome-after-refusal")
    }

    // MARK: C1/C2/C3 — sign-up form

    func testC1C2C3SignUpValidationConsentAndConfirmation() throws {
        launch(["--qa-push", "SignUpCredentials/client"])
        let continueButton = app.buttons["Continue"].firstMatch
        XCTAssertTrue(continueButton.waitForExistence(timeout: 60))
        XCTAssertTrue(continueButton.isEnabled, "C1: Continue is always active")
        shot("C1-form-empty")
        continueButton.tap()
        for field in ["email", "password", "confirmation", "agreement"] {
            XCTAssertTrue(app.staticTexts["signup-error-\(field)"].waitForExistence(timeout: 5), "C1: \(field) problem under its field")
        }
        if english {
            XCTAssertEqual(app.staticTexts["signup-error-email"].label, "This field is required.")
            XCTAssertEqual(app.staticTexts["signup-error-password"].label, "This field is required.")
            XCTAssertEqual(app.staticTexts["signup-error-confirmation"].label, "This field is required.")
            XCTAssertEqual(app.staticTexts["signup-error-agreement"].label, "Please accept the license agreement to continue.")
        }
        shot("C1-all-empty-errors")
        let email = app.textFields.firstMatch
        email.tap(); email.typeText("not-an-email")
        let password = app.secureTextFields.element(boundBy: 0)
        password.tap()
        let close = app.buttons["Close"]; if close.waitForExistence(timeout: 2) { close.tap(); password.tap() }
        password.typeText("abcdefgh")
        let confirmation = app.secureTextFields.element(boundBy: 1)
        confirmation.tap(); if close.waitForExistence(timeout: 2) { close.tap(); confirmation.tap() }
        confirmation.typeText("abcdefgX")
        app.staticTexts["signup-consent-text"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.02)).tap()
        continueButton.tap()
        if english {
            XCTAssertEqual(app.staticTexts["signup-error-email"].label, "Please enter a valid email address.")
            XCTAssertEqual(app.staticTexts["signup-error-password"].label, "One uppercase")
            XCTAssertEqual(app.staticTexts["signup-error-confirmation"].label, "Passwords do not match.")
        }
        XCTAssertTrue(app.staticTexts["signup-error-agreement"].exists)
        shot("C1-invalid-email-rule-mismatch")

        // C2: the two names open the in-app viewer; no document is configured yet.
        let consent = app.staticTexts["signup-consent-text"]
        if english {
            let sentence = "I agree to the Terms of Use and acknowledge that I have read the Privacy Policy."
            XCTAssertTrue(consent.label.contains(sentence))
            // VoiceOver: the tick-box speaks the whole managed sentence; the names are links.
            XCTAssertEqual(app.buttons["signup-consent-checkbox"].label, sentence)
            XCTAssertTrue(app.links["Terms of Use"].exists && app.links["Privacy Policy"].exists)
        }
        print("PV3 consent frame \(consent.frame) links: " + consent.links.allElementsBoundByIndex.map { "\($0.label) \($0.frame)" }.joined(separator: " | "))
        print("PV3 app links: " + app.links.allElementsBoundByIndex.map { "\($0.label) \($0.frame)" }.joined(separator: " | "))
        for (index, link) in consent.links.allElementsBoundByIndex.enumerated() {
            // SwiftUI reports an empty accessibility rect for a link on a wrapped
            // line; touch hit-testing is unaffected, so tap where the name is drawn.
            if link.frame.width > 1 { link.tap() }
            else if english { consent.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.75)).tap() }
            else { continue }
            let unavailable = app.staticTexts["legal-document-unavailable"]
            XCTAssertTrue(unavailable.waitForExistence(timeout: 10), "C2: document viewer opens")
            if english { XCTAssertEqual(unavailable.label, "This item is no longer available.") }
            shot("C2-viewer-\(index == 0 ? "terms" : "privacy")")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(unavailable.waitForNonExistence(timeout: 10))
        }
        XCTAssertEqual(consent.links.count, 2, "C2: Terms of Use and Privacy Policy are both links")

        // C3: a valid form opens the confirmation with the managed sentence.
        for _ in 0..<12 { email.tap(); email.typeText(XCUIKeyboardKey.delete.rawValue) }
        email.typeText("parity.v3@example.com")
        password.tap(); for _ in 0..<8 { password.typeText(XCUIKeyboardKey.delete.rawValue) }
        password.typeText("Abcdefg1!")
        confirmation.tap(); for _ in 0..<8 { confirmation.typeText(XCUIKeyboardKey.delete.rawValue) }
        confirmation.typeText("Abcdefg1!")
        app.buttons["signup-consent-checkbox"].tap()
        continueButton.tap()
        let dialogText = english ? text("Please review the details below. The email address will be used to continue.")
                                 : app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "يرجى مراجعة")).firstMatch
        XCTAssertTrue(dialogText.waitForExistence(timeout: 10), "C3: managed confirmation sentence")
        for field in ["email", "password", "confirmation", "agreement"] {
            XCTAssertFalse(app.staticTexts["signup-error-\(field)"].exists)
        }
        shot("C3-confirmation-dialog")
        app.buttons["Edit"].firstMatch.tap()
    }

    // MARK: C4 — account created but the first code cannot be sent

    func testC4CodeScreenOpensWhenFirstCodeCannotBeSentAndResendWorks() throws {
        let accountFile = try value("PV3_C4_ACCOUNT_FILE")
        let inbox = try MailTM.createInbox()
        let password = "Pv3C4" + String(Int.random(in: 1000...9999)) + "a!"
        launch(["--qa-push", "SignUpCredentials/client", "--qa-fail-once", "POST", "users/otp/send"])
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 60))
        email.tap(); email.typeText(inbox.address)
        let pass = app.secureTextFields.element(boundBy: 0)
        pass.tap(); let close = app.buttons["Close"]; if close.waitForExistence(timeout: 2) { close.tap(); pass.tap() }
        pass.typeText(password)
        let confirmation = app.secureTextFields.element(boundBy: 1)
        confirmation.tap(); if close.waitForExistence(timeout: 2) { close.tap(); confirmation.tap() }
        confirmation.typeText(password)
        app.buttons["signup-consent-checkbox"].tap()
        app.buttons["Continue"].firstMatch.tap()
        app.buttons["Confirm"].firstMatch.tap()
        let record = ["email": inbox.address, "password": password, "role": "client", "inbox_token": inbox.token]
        // One file per run, so a later run never overwrites credentials needed for cleanup.
        let runFile = accountFile + ".\(Int(Date().timeIntervalSince1970))"
        try JSONSerialization.data(withJSONObject: record).write(to: URL(fileURLWithPath: runFile), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runFile)
        XCTAssertTrue(app.staticTexts["OTP Confirmation"].waitForExistence(timeout: 60), "C4: the code screen opens even though the code was not sent")
        XCTAssertTrue(text("Cannot communicate with server.").waitForExistence(timeout: 5), "C4: the send failure is reported")
        let resend = app.buttons["Re-send"]
        XCTAssertTrue(resend.waitForExistence(timeout: 5), "C4: the person can ask for the code again at once")
        shot("C4-code-screen-after-send-failure")
        // The error toast sits over the link for a few seconds; close it first.
        let closeToast = app.buttons.matching(NSPredicate(format: "label == %@", "Dismiss")).firstMatch
        if closeToast.exists && closeToast.isHittable { closeToast.tap() } else { sleep(5) }
        sleep(1)
        resend.tap()
        let code = try XCTUnwrap(try MailTM.waitForCode(inbox), "Re-send must deliver a code")
        let boxes = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "One-time code")).firstMatch
        boxes.tap(); app.typeText(code)
        app.buttons["Continue"].firstMatch.tap()
        XCTAssertTrue(app.textFields["Enter your first name"].waitForExistence(timeout: 30), "Verified code continues to the profile step")
        shot("C4-profile-step-after-resend")
    }

    // MARK: F1/F2/F3 — location step (read-only: nothing is saved)

    private func openLocationStep(fixture: String) throws {
        let email = try value("PV3_CLIENT_EMAIL"), password = try value("PV3_CLIENT_PASSWORD")
        app.launchEnvironment["QA_CLIENT_USER_ID"] = try value("PV3_CLIENT_ID")
        app.launchEnvironment["QA_CG_ID"] = try value("PV3_CG_ID")
        launch(["--qa-request-counts", "--qa-push", "ClientPreferences", "--qa-location-fixture", fixture,
                "--qa-owned-profile-no-location", "GET", "clients/profile"], email: email, password: password)
        XCTAssertTrue(app.staticTexts["qa-profile-no-location"].waitForExistence(timeout: 90))
        for _ in 0..<2 {
            let next = app.buttons[english ? "Continue" : "متابعة"].firstMatch
            XCTAssertTrue(next.waitForExistence(timeout: 30)); sleep(2); next.tap(); sleep(1)
        }
    }

    func testF1F3NoAutomaticLocationCountryMapAndRequiredMessage() throws {
        try openLocationStep(fixture: "available")
        let hint = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", english ? "Tap to select location" : "اضغط لاختيار الموقع")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*-?[0-9]+\\.[0-9]{6} , -?[0-9]+\\.[0-9]{6}.*")).count, 0,
                       "F1: an available phone fix must not fill the location by itself")
        shot("F1-location-row-empty")
        app.buttons["Continue"].firstMatch.tap()
        if english { XCTAssertTrue(text("Please select a location to continue.").waitForExistence(timeout: 5), "F3") }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "STEP")).firstMatch.exists || !english)
        shot("F3-location-required")
        sleep(4)
        hint.tap()
        let myLocation = app.buttons["My location"]
        XCTAssertTrue(myLocation.waitForExistence(timeout: 15))
        sleep(3)
        shot("F1-map-opens-on-country")
        if english { XCTAssertTrue(app.buttons["Continue"].firstMatch.exists, "F1: no point is chosen until the person acts") }
        myLocation.tap()
        XCTAssertTrue(app.buttons["Confirm"].firstMatch.waitForExistence(timeout: 15), "F1: My Location uses the phone position")
        shot("F1-after-my-location")
        app.buttons["Back"].firstMatch.tap()
    }

    func testF2RefusedLocationAccessExplainsAfterMyLocation() throws {
        try openLocationStep(fixture: "none")
        let hint = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", english ? "Tap to select location" : "اضغط لاختيار الموقع")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 15)); hint.tap()
        let myLocation = app.buttons["My location"]
        XCTAssertTrue(myLocation.waitForExistence(timeout: 15))
        myLocation.tap()
        let note = app.staticTexts["location-permission-denied"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "F2: refusal must be explained")
        if english { XCTAssertEqual(note.label, "Allow location access to use your current location.") }
        shot("F2-location-permission-denied")
        app.buttons["Back"].firstMatch.tap()
    }

    // MARK: K — messages (client A; chats with caregiver B (active) and C (deleted))

    func testK4EmptySendExplainsAndButtonStaysTappable() throws {
        launch(["--qa-push", "Chat/\(try value("PV3_CHAT_B"))"], email: try value("PV3_CLIENT_EMAIL"), password: try value("PV3_CLIENT_PASSWORD"))
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 60))
        let transcript = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-message-")).firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 60), "conversation loaded")
        sleep(1)
        XCTAssertTrue(send.isEnabled, "K4: send stays tappable with an empty message")
        send.tap()
        if english { XCTAssertTrue(text("Please type a message first.").waitForExistence(timeout: 5), "K4") }
        shot("K4-empty-send")
    }

    func testK1ConversationListRefreshesEveryTenSecondsAndShowsPartnerMessage() throws {
        launch(["--qa-request-counts", "--qa-tab", "messages"], email: try value("PV3_CLIENT_EMAIL"), password: try value("PV3_CLIENT_PASSWORD"))
        XCTAssertTrue(app.staticTexts["qa-request-counts"].waitForExistence(timeout: 60))
        XCTAssertTrue(waitFor(30) { self.requestCount("GET /api/users/chats") >= 1 })
        let start = requestCount("GET /api/users/chats")
        let begin = Date()
        // Cross-role: the caregiver writes while the client's list is open.
        let marker = "PV3 K1 \(Int(Date().timeIntervalSince1970) % 100000)"
        let token = try CarezaarAPI.login(try value("PV3_CG_EMAIL"), try value("PV3_CG_PASSWORD"))
        _ = try CarezaarAPI.call("POST", "users/chats/\(try value("PV3_CHAT_B"))", form: ["message": marker], token: token)
        let row = app.buttons.matching(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "K1: the partner's message appears without any action within ~10 s")
        let seconds = Date().timeIntervalSince(begin)
        print("K1 marker visible after \(Int(seconds)) s")
        shot("K1-list-refreshed-with-partner-message")
        XCTAssertTrue(waitFor(25) { self.requestCount("GET /api/users/chats") >= start + 2 })
        let elapsed = Date().timeIntervalSince(begin)
        let gained = requestCount("GET /api/users/chats") - start
        XCTAssertLessThanOrEqual(gained, Int(elapsed / 10) + 1, "K1: a single 10-second timer (no duplicates)")
        // Hidden: opening Profile stops the timer.
        app.buttons["Profile"].firstMatch.tap()
        sleep(2)
        let hidden = requestCount("GET /api/users/chats")
        sleep(22)
        XCTAssertEqual(requestCount("GET /api/users/chats"), hidden, "K1: no refresh while the list is not visible")
    }

    func testK2UnmatchedConversationIsClosedWithNote() throws {
        launch(["--qa-push", "Chat/\(try value("PV3_CHAT_B"))"], email: try value("PV3_CLIENT_EMAIL"), password: try value("PV3_CLIENT_PASSWORD"))
        let note = app.descendants(matching: .any)["chat-closed-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 60), "K2: closed conversation note")
        if english { XCTAssertTrue(note.label.contains("You can only send messages to your current matches.")) }
        XCTAssertFalse(app.buttons["Send"].isEnabled, "K2: send is grey")
        XCTAssertFalse(app.textFields.firstMatch.isEnabled, "K2: typing box is off")
        shot("K2-unmatched-conversation")
    }

    /// Cross-role: the caregiver's side of the same ended match is closed too.
    func testK2CaregiverSideOfUnmatchedConversationIsClosed() throws {
        launch(["--qa-push", "Chat/\(try value("PV3_CHAT_B"))"], email: try value("PV3_CG_EMAIL"), password: try value("PV3_CG_PASSWORD"))
        let note = app.descendants(matching: .any)["chat-closed-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 60), "K2: closed conversation note (caregiver)")
        if english { XCTAssertTrue(note.label.contains("You can only send messages to your current matches.")) }
        XCTAssertFalse(app.buttons["Send"].isEnabled)
        shot("K2-unmatched-conversation-caregiver")
    }

    func testK3DeletedAccountShownAndConversationClosed() throws {
        launch(["--qa-tab", "messages"], email: try value("PV3_CLIENT_EMAIL"), password: try value("PV3_CLIENT_PASSWORD"))
        let deletedName = english ? "Deleted Account" : "حساب محذوف"
        let row = app.buttons.matching(NSPredicate(format: "label == %@", deletedName)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "K3: deleted account named in the list")
        shot("K3-messages-list")
        row.tap()
        let note = app.descendants(matching: .any)["chat-closed-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        if english { XCTAssertTrue(note.label.contains("This account has been deleted. You can no longer send messages.")) }
        XCTAssertTrue(text(deletedName).exists, "K3: conversation header")
        XCTAssertFalse(app.buttons["Send"].isEnabled)
        XCTAssertFalse(app.textFields.firstMatch.isEnabled)
        shot("K3-conversation-closed")
        app.terminate()
        launch(["--qa-push", "Notifications"], email: try value("PV3_CLIENT_EMAIL"), password: try value("PV3_CLIENT_PASSWORD"))
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 60))
        sleep(5)
        // Older notifications load page by page while scrolling.
        for _ in 0..<12 where !text(deletedName).exists { app.swipeUp(velocity: .slow); sleep(2) }
        XCTAssertTrue(text(deletedName).waitForExistence(timeout: 10), "K3: deleted account named in notifications")
        shot("K3-notifications")
    }

    // MARK: M2 — Change Password subtitle

    func testM2ChangePasswordSubtitle() throws {
        launch(["--qa-tab", "profile"], email: try value("PV3_CLIENT_EMAIL"), password: try value("PV3_CLIENT_PASSWORD"))
        let subtitle = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", english ? "Change your current password" : "غيّر كلمة المرور الحالية")).firstMatch
        XCTAssertTrue(subtitle.waitForExistence(timeout: 30), "M2")
        sleep(2)
        // Scroll the personal card (with the email address) out of the evidence.
        let logOut = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", english ? "Sign out from your account" : "تسجيل الخروج من حسابك")).firstMatch
        for _ in 0..<8 where !(logOut.exists && logOut.isHittable) { app.swipeUp(velocity: .slow); sleep(1) }
        app.swipeUp(velocity: .slow); sleep(1)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Update your account password")).firstMatch.exists)
        shot("M2-profile-menu")
    }

    // MARK: Q1/Q2 — session renewal

    func testQ1RenewalHTTPErrorSignsOutWithoutConnectionWindow() throws {
        launch(["--qa-request-counts", "--qa-tab", "profile", "--qa-break-access-later", "--qa-refresh-http-error"],
               email: try value("PV3_CLIENT_EMAIL"), password: try value("PV3_CLIENT_PASSWORD"))
        try openNotificationsAfterTokenBreak()
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "I need care")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 90), "Q1: an HTTP error answer to renewal signs the person out")
        XCTAssertEqual(app.alerts.count, 0, "Q1: no Connection Problem window for a server answer")
        let presence = app.staticTexts["qa-token-presence"]
        XCTAssertTrue(waitFor(5) { presence.label == "accessPresent=false;refreshPresent=false" })
        XCTAssertGreaterThanOrEqual(requestCount("PUT /api/auth/qa-renewal-http-error"), 1)
        shot("Q1-signed-out-after-renewal-error")
    }

    func testQ2RetryClosesWindowAndDoesNotRepeatFailedRequest() throws {
        launch(["--qa-request-counts", "--qa-tab", "profile", "--qa-break-access-later", "--qa-refresh-failures", "1"],
               email: try value("PV3_CLIENT_EMAIL"), password: try value("PV3_CLIENT_PASSWORD"))
        try openNotificationsAfterTokenBreak()
        let dialog = app.alerts["Connection Problem"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 90))
        let reads = requestCount("GET /api/users/notifications")
        XCTAssertGreaterThanOrEqual(reads, 1)
        shot("Q2-connection-problem")
        dialog.buttons["Retry"].tap()
        XCTAssertTrue(waitFor(30) { self.requestCount("PUT /api/auth/refresh") == 5 && !dialog.exists },
                      "Q2: one renewal on Retry, then the window closes")
        sleep(3)
        XCTAssertEqual(requestCount("GET /api/users/notifications"), reads, "Q2: the failed request is not repeated")
        let presence = app.staticTexts["qa-token-presence"]
        XCTAssertTrue(waitFor(5) { presence.label == "accessPresent=true;refreshPresent=true" }, "Still signed in")
        XCTAssertTrue(text("Cannot communicate with server.").exists, "Q2: the failed request shows its own error")
        shot("Q2-after-retry")
    }

    /// `--qa-break-access-later` makes the stored access token invalid ~8 s after
    /// sign-in; opening Notifications then sends a request the server refuses (403).
    private func openNotificationsAfterTokenBreak() throws {
        let bell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Notifications")).firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 90))
        XCTAssertTrue(app.staticTexts["qa-request-counts"].waitForExistence(timeout: 10))
        sleep(14)
        bell.tap()
    }
}
