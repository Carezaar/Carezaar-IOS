import XCTest

/// Opens every screen directly and saves its top and bottom (`QA_SHOT_DIR`), for
/// visual review at whatever text size and language the simulator is set to (the
/// largest accessibility size in the final pass). Client account; the caregiver
/// account stages a request with an Introduction, then accepts it for "It's a Match!".
final class ScreenSweepTests: XCTestCase {
    var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var prefix: String { env["QA_PREFIX"] ?? "sweep" }

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    func testSignedOutScreens() {
        for (name, args) in [("intro", [String]()), ("create-account", ["--qa-push", "SignUpCredentials/client"]),
                             ("forgot-password", ["--qa-push", "ForgotPassword"]), ("faq-signed-out", ["--qa-push", "FAQ"])] {
            open(["--qa-signout"] + args)
            capture(name)
        }
        open(["--qa-signout"])
        let signIn = app.buttons["Sign in"].firstMatch
        if signIn.waitForExistence(timeout: 30) { signIn.tap(); sleep(2) }
        capture("sign-in")
    }

    func testSignedInScreens() throws {
        let email = env["QA_EMAIL"] ?? "", password = env["QA_PASSWORD"] ?? ""
        let clientToken = try CarezaarAPI.login(email, password)
        let clientId = "\(try CarezaarAPI.me(clientToken)["id"] ?? "")"
        let cgToken = try CarezaarAPI.login(env["QA_CG_EMAIL"] ?? "", env["QA_CG_PASSWORD"] ?? "")
        let cgId = "\(try CarezaarAPI.me(cgToken)["id"] ?? "")"
        try CarezaarAPI.clearRelation(caregiverToken: cgToken, clientUserId: clientId)
        defer { try? CarezaarAPI.clearRelation(caregiverToken: cgToken, clientUserId: clientId) }
        // An open request with an Introduction, so the received profile has content.
        let request = CarezaarAPI.result(try CarezaarAPI.call("POST", "users/matches", form: [
            "partner_id": clientId,
            "introduction": "Hello! I'm an experienced caregiver, available on weekday mornings — happy to talk. 你好 مرحبا 👋🏽"],
            token: cgToken))

        let login = ["--qa-signout", "--qa-login-env"]
        var screens: [(String, [String])] = [
            ("tab-matches", []), ("tab-messages", ["--qa-tab", "messages"]), ("tab-profile", ["--qa-tab", "profile"]),
            ("partner-profile-received", ["--qa-push", "CaregiverDetails/\(cgId)"]),
            ("manage-matches", ["--qa-push", "ManageMatches"]),
            ("edit-profile", ["--qa-push", "ProfileEdit"]),
            ("preferences", ["--qa-push", "ClientPreferences"]),
            ("notifications", ["--qa-push", "Notifications"]),
            ("favorites", ["--qa-push", "Favorites"]),
            ("help-center", ["--qa-push", "HelpCenter"]),
            ("faq", ["--qa-push", "FAQ"]),
            ("report-issue", ["--qa-push", "ReportAnIssue"]),
            ("change-language", ["--qa-push", "ChangeLanguage"]),
            ("change-password", ["--qa-push", "ChangePassword"]),
            ("delete-account", ["--qa-push", "DeleteAccount"]),
        ]
        for (i, (name, args)) in screens.enumerated() {
            open((i == 0 ? login : []) + args)
            capture(name)
        }
        // The confirmations, found by identifier so this works in any language.
        open(["--qa-push", "CaregiverDetails/\(cgId)"])
        for (id, name) in [("match-accept", "confirm-accept"), ("match-reject", "confirm-reject")] {
            let action = app.buttons[id]
            if action.waitForExistence(timeout: 20) {
                action.tap(); sleep(1); save(name)
                app.alerts.buttons.element(boundBy: 0).tap(); sleep(1)
            }
        }
        // Accepted: "It's a Match!", the active profile and the chat.
        _ = try CarezaarAPI.call("PATCH", "users/matches/\(request["id"] ?? "")/accept", token: clientToken)
        let chat = CarezaarAPI.result(try CarezaarAPI.call("POST", "users/chats", form: ["partner_id": cgId], token: clientToken))
        screens = [
            ("its-a-match", ["--qa-push", "Matched/caregivers/\(cgId)"]),
            ("partner-profile-active", ["--qa-push", "CaregiverDetails/\(cgId)"]),
            ("chat", ["--qa-push", "Chat/\(chat["id"] ?? "")"]),
        ]
        for (i, (name, args)) in screens.enumerated() {
            open((i == 0 ? login : []) + args)
            capture(name)
        }
        open(["--qa-push", "CaregiverDetails/\(cgId)"])
        if app.buttons["match-unmatch"].waitForExistence(timeout: 20) {
            app.buttons["match-unmatch"].tap(); sleep(1); save("confirm-unmatch")
            app.alerts.buttons.element(boundBy: 0).tap(); sleep(1)
        }
        // Back to no connection: the request sheet with its Introduction field.
        try CarezaarAPI.clearRelation(caregiverToken: cgToken, clientUserId: clientId)
        open(["--qa-push", "CaregiverDetails/\(cgId)"])
        if app.buttons["match-request"].waitForExistence(timeout: 20) {
            app.buttons["match-request"].tap(); sleep(2); save("request-sheet")
        }
    }

    /// "It's a Match!" scrolls when its content is taller than the screen (a small phone
    /// at the largest text size), so the info rows above the buttons can be reached.
    func testMatchedScrolls() throws {
        let email = env["QA_EMAIL"] ?? "", password = env["QA_PASSWORD"] ?? ""
        let clientToken = try CarezaarAPI.login(email, password)
        let clientId = "\(try CarezaarAPI.me(clientToken)["id"] ?? "")"
        let cgToken = try CarezaarAPI.login(env["QA_CG_EMAIL"] ?? "", env["QA_CG_PASSWORD"] ?? "")
        let cgId = "\(try CarezaarAPI.me(cgToken)["id"] ?? "")"
        try CarezaarAPI.clearRelation(caregiverToken: cgToken, clientUserId: clientId)
        defer { try? CarezaarAPI.clearRelation(caregiverToken: cgToken, clientUserId: clientId) }
        let request = CarezaarAPI.result(try CarezaarAPI.call("POST", "users/matches", form: ["partner_id": clientId], token: cgToken))
        _ = try CarezaarAPI.call("PATCH", "users/matches/\(request["id"] ?? "")/accept", token: clientToken)
        open(["--qa-signout", "--qa-login-env", "--qa-push", "Matched/caregivers/\(cgId)"])
        let heading = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "have matched")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 40))
        let before = heading.frame.minY
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        sleep(1)
        save("matched-scrolled")
        let fits = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Better Care")).firstMatch.isHittable && before > 0
        XCTAssertTrue(heading.frame.minY < before || fits, "It's a Match! did not scroll (heading at \(before) → \(heading.frame.minY))")
    }

    /// Report an Issue, submitted from Profile through the form. The app's reaction must
    /// match the server: a stored issue returns to the list; a refusal shows an error and
    /// stores nothing. The outcome is logged (QA-NOTE).
    func testReportIssueSubmit() throws {
        try XCTSkipIf(true, "Quarantined unsafe legacy fixture: Legacy report submission creates a live support issue without an owned disposable issue contract. Keep read-only support navigation checks; live support submission needs a separately authorized disposable issue fixture.")

        let email = env["QA_EMAIL"] ?? "", password = env["QA_PASSWORD"] ?? ""
        let token = try CarezaarAPI.login(email, password)
        let before = (try CarezaarAPI.call("GET", "users/issues", token: token)["result"] as? [Any])?.count ?? 0
        open(["--qa-signout", "--qa-login-env", "--qa-push", "ReportAnIssue"])
        let add = app.buttons["Report An Issue"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 30), "new-report button")
        add.tap()
        let subject = app.textFields["Enter your issue subject..."]
        XCTAssertTrue(subject.waitForExistence(timeout: 15), "report form")
        subject.tap(); subject.typeText("iOS QA test report")
        let body = app.textFields["Write your issue here..."].exists ? app.textFields["Write your issue here..."] : app.textViews.firstMatch
        body.tap(); body.typeText("Submitted by the iOS QA run on 2026-10-09 to check the Report an Issue endpoint. Please ignore.")
        let ok = app.toolbars.buttons["OK"]; if ok.exists { ok.tap() }
        app.buttons["Submit"].firstMatch.tap()
        sleep(8)
        save("report-submit-result")
        let after = (try CarezaarAPI.call("GET", "users/issues", token: token)["result"] as? [Any])?.count ?? 0
        let stored = after > before
        let errorShown = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "support@carezaar.com", "not available")).firstMatch.exists
        print("QA-NOTE report submit: stored=\(stored) (issues \(before)→\(after)), error shown=\(errorShown)")
        if stored {
            XCTAssertFalse(app.buttons["Submit"].exists, "stored, but the form is still open")
        } else {
            XCTAssertTrue(errorShown, "the server refused the report, but the app showed no error")
        }
    }

    /// The Figma-drawn screens (Intro, Sign In, Create Account) stay on screen after
    /// fast swipes; they used to scroll entirely out of view and leave a white screen.
    func testFigmaScreensSurviveSwipes() {
        let screens: [(String, [String], XCUIElement)] = [
            ("intro", [], app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "I need care")).firstMatch),
            ("create-account", ["--qa-push", "SignUpCredentials/client"], app.textFields["Enter your email address..."]),
        ]
        for (name, args, anchor) in screens {
            open(["--qa-signout"] + args)
            XCTAssertTrue(anchor.waitForExistence(timeout: 30), "\(name) did not open")
            swipeBothWays(name, anchor)
        }
        open(["--qa-signout"])
        app.buttons["Sign in"].firstMatch.tap()
        let password = app.secureTextFields["Enter your password..."]
        XCTAssertTrue(password.waitForExistence(timeout: 20))
        swipeBothWays("sign-in", password)
    }

    private func swipeBothWays(_ name: String, _ anchor: XCUIElement) {
        let screen = app.windows.firstMatch.frame
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        sleep(2)
        save("\(name)-after-swipes")
        if name == "intro" {
            // Below the fold even on a 6.9" phone: a returning user must be able to swipe to it.
            let signIn = app.buttons["Sign in"].firstMatch
            XCTAssertTrue(signIn.exists && screen.contains(signIn.frame), "intro: Sign in not reachable by swiping (\(signIn.frame))")
        }
        let visible = app.scrollViews.firstMatch.descendants(matching: .any).allElementsBoundByIndex
            .contains { $0.frame.height > 10 && $0.frame.maxY > screen.minY + 120 && $0.frame.minY < screen.maxY }
        XCTAssertTrue(visible, "\(name): the design scrolled out of view")
        app.swipeDown(velocity: .fast); sleep(1)
        XCTAssertTrue(anchor.exists && screen.intersects(anchor.frame), "\(name): not back on screen (\(anchor.frame))")
    }

    /// Xcode's accessibility audit (contrast, hit regions, Dynamic Type, labels, text
    /// clipping) on the main screens. Every issue is written to `a11y-audit.txt` for review
    /// instead of failing on the first.
    func testAccessibilityAudit() throws {
        var report: [String] = []
        var completedScreens: [String] = []
        defer {
            let summary = "Completed screens: " + completedScreens.joined(separator: ", ") + "\nFindings: \(report.count)\n" + report.joined(separator: "\n")
            let attachment = XCTAttachment(string: summary)
            attachment.name = "\(prefix)-a11y-audit.txt"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let dir = env["QA_SHOT_DIR"] {
                do { try summary.write(toFile: "\(dir)/\(prefix)-a11y-audit.txt", atomically: true, encoding: .utf8) }
                catch { XCTFail("Could not save accessibility report: \(error.localizedDescription)") }
            }
            XCTAssertTrue(report.isEmpty, "Accessibility audit found \(report.count) issue(s); see saved XCTest attachment")
        }
        let screens: [(String, [String])] = [
            ("intro", ["--qa-signout"]),
            ("matches", ["--qa-signout", "--qa-login-env"]),
            ("messages", ["--qa-tab", "messages"]), ("profile", ["--qa-tab", "profile"]),
            ("manage-matches", ["--qa-push", "ManageMatches"]), ("notifications", ["--qa-push", "Notifications"]),
            ("delete-account", ["--qa-push", "DeleteAccount"]),
            ("change-password", ["--qa-push", "ChangePassword"]), ("help-center", ["--qa-push", "HelpCenter"]),
        ]
        for (name, args) in screens {
            open(args)
            guard waitForAuditScreen(name) else {
                report.append("\(name)\tReadiness FAILED: expected screen did not load within 60 seconds; audit skipped to avoid attributing another page's issues to this screen.")
                continue
            }
            do {
                try app.performAccessibilityAudit { issue in
                    let el = issue.element.map {
                        "\($0.elementType.rawValue) '\($0.label)' enabled=\($0.isEnabled) hittable=\($0.isHittable) frame=\(String(describing: $0.frame))"
                    } ?? "-"
                    report.append("\(name)\t\(issue.auditType.rawValue)\t\(issue.compactDescription)\t\(el)")
                    // Collect every issue rather than terminate on the first; the
                    // final assertion below still treats every finding as a failure.
                    return true
                }
                completedScreens.append(name)
            } catch {
                report.append("\(name)\tAudit execution failed: \(error.localizedDescription)")
            }
        }
        print("A11Y-ISSUES \(report.count)")
    }

    /// Root configures the simulator to accessibility-extra-extra-extra-large.
    /// Reachability and screenshots verify real native layouts; no font numbers
    /// or requirement to fit the whole page into one viewport are imposed.
    func testLargestDynamicTypeScreensRemainReachable() throws {
        guard env["QA_SHOT_DIR"] != nil else { throw XCTSkip("Requires a private QA_SHOT_DIR for screenshots and hierarchies.") }
        try verifyDisabledGuardOwnedIdentity()
        let caregiver = env["QA_EMAIL"] == env["QA_CG_EMAIL"]
        let english = ["-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        let screens: [(String, [String], [String], [String])] = [
            ("intro", ["--qa-signout"], ["Language", "Sign in"], []),
            ("matches", ["--qa-signout", "--qa-login-env"], [caregiver ? "Edit skills" : "Edit preferences"], ["My Matches"]),
            ("messages", ["--qa-tab", "messages"], [], ["All your conversations in one place"]),
            ("profile", ["--qa-tab", "profile"], ["Edit"], ["Manage your personal information and account settings."]),
            ("notifications", ["--qa-push", "Notifications"], [], []),
            ("help-center", ["--qa-push", "HelpCenter"], [], ["We are here to help"]),
        ]
        for (name, args, controls, texts) in screens {
            open(args + english)
            XCTAssertTrue(waitForAuditScreen(name), "Largest-type destination failed readiness: \(name)")
            saveReadabilityEvidence("\(name)-largest-top")
            for label in controls {
                let control = app.buttons[label].firstMatch
                makeReachable(control)
                XCTAssertTrue(control.exists && control.isHittable, "Largest-type control is not scroll-reachable: \(name)/\(label)")
                if name == "intro" && label == "Language" {
                    XCTAssertEqual(control.value as? String, "English", "Intro language picker did not load English")
                }
            }
            for label in texts {
                let text = app.staticTexts[label].firstMatch
                makeReachable(text)
                XCTAssertTrue(text.exists && text.isHittable, "Largest-type important text is not scroll-reachable: \(name)")
                XCTAssertEqual(text.label, label, "Important text lost its complete accessibility label")
            }
            app.swipeUp(velocity: .slow); app.swipeUp(velocity: .slow)
            saveReadabilityEvidence("\(name)-largest-bottom")
        }
    }

    /// Diagnose reported contrast only with the exact text fully above the fixed
    /// action footer. Root must inspect these bounded rasters; this does not turn
    /// the retained initial-position nine-screen audit into a passing audit.
    func testA5ReportedContrastTextRenderedAboveFooter() throws {
        guard env["QA_SHOT_DIR"] != nil, env["QA_CHROME_TEXT_SIZE_PHASE"] == "a5" else {
            throw XCTSkip("Private raster evidence and externally verified actual A5 setting are required")
        }
        try verifyDisabledGuardOwnedIdentity()
        let english = ["-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        func expose(_ element: XCUIElement, above footer: XCUIElement) throws {
            for _ in 0..<16 {
                let navigation = app.navigationBars.firstMatch
                let brand = app.staticTexts["Carezaar"].firstMatch
                let top = navigation.exists ? navigation.frame.maxY + 4
                    : (brand.exists ? brand.frame.maxY + 12 : app.frame.minY + 70)
                let keyboard = app.keyboards.firstMatch
                let bottom = min(footer.exists ? footer.frame.minY - 12 : app.frame.maxY,
                                 keyboard.exists ? keyboard.frame.minY - 4 : app.frame.maxY)
                if element.exists && element.isHittable && footer.exists
                    && element.frame.minY >= top && element.frame.maxY <= bottom { return }
                let scroll = app.scrollViews.firstMatch
                guard scroll.exists else {
                    XCTFail("Actual diagnostic ScrollView required for bounded native drag")
                    throw NSError(domain: "A5Readability", code: 2)
                }
                // Re-observe every gesture. Stay inside the visible ScrollView,
                // below the header and above both fixed footer and keyboard.
                let visible = scroll.frame.intersection(app.frame)
                let upper = max(visible.minY, top) + 8
                let lower = min(visible.maxY, bottom) - 8
                guard !visible.isNull, visible.width > 16, lower - upper >= 16 else {
                    XCTFail("No observed visible ScrollView area for diagnostic drag")
                    throw NSError(domain: "A5Readability", code: 3)
                }
                let down = element.exists && element.frame.minY < top
                let needed = element.exists
                    ? (down ? top - element.frame.minY + 4 : element.frame.maxY - bottom + 4) : 150
                // Small displacement avoids whole-screen swipe oscillation
                // around the exact rule while preserving all exposure gates.
                let distance = min(150, lower - upper, max(40, needed))
                let center = (upper + lower) / 2
                let x = visible.minX + visible.width * 0.9
                let startY = center + (down ? -distance / 2 : distance / 2)
                let endY = center + (down ? distance / 2 : -distance / 2)
                let origin = scroll.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: x - scroll.frame.minX, dy: startY - scroll.frame.minY))
                let end = origin.withOffset(CGVector(dx: x - scroll.frame.minX, dy: endY - scroll.frame.minY))
                start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            }
            XCTFail("Exact diagnostic text could not be fully exposed between header and action footer")
            throw NSError(domain: "A5Readability", code: 1)
        }
        func raster(_ element: XCUIElement, _ name: String) {
            let attachment = XCTAttachment(screenshot: element.screenshot())
            attachment.name = "A5-fully-exposed-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        open(["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", "DeleteAccount"] + english)
        XCTAssertTrue(waitForAuditScreen("delete-account"))
        let warning = app.staticTexts["This action cannot be undone"].firstMatch
        let delete = app.buttons["Delete Account"].firstMatch
        try expose(warning, above: app.buttons["Cancel"].firstMatch)
        XCTAssertFalse(delete.isEnabled)
        raster(warning, "delete-warning-black-on-pink")
        XCTAssertEqual(try disabledGuardTransportCount("DELETE /api/users"), 0)
        open(["--qa-request-counts", "--qa-push", "ChangePassword"] + english)
        XCTAssertTrue(waitForAuditScreen("change-password"))
        let rule = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "At least 1 uppercase letter, not met")).firstMatch
        let change = app.buttons["Change Password"].firstMatch
        try expose(rule, above: change)
        raster(rule, "empty-password-rule-gray-on-gray")
        let updated = app.secureTextFields["Enter your new password..."].firstMatch
        try expose(updated, above: change)
        XCTAssertTrue(updated.exists && updated.isHittable)
        updated.tap(); updated.typeText("Aa1@2345") // Local synthetic draft; never submitted.
        // Observed native software-keyboard Return dismisses this secure field.
        // Current and confirmation stay empty; no change can be submitted.
        let nativeReturn = app.keyboards.buttons["Return"].firstMatch
        XCTAssertTrue(nativeReturn.exists && nativeReturn.isHittable,
                      "Observed native keyboard Return is required for this diagnostic")
        if nativeReturn.exists && nativeReturn.isHittable { nativeReturn.tap() }
        let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !self.app.keyboards.firstMatch.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardGone], timeout: 5), .completed)
        let satisfiedRule = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "At least 1 uppercase letter, met")).firstMatch
        try expose(satisfiedRule, above: change)
        XCTAssertEqual(satisfiedRule.label, "At least 1 uppercase letter, met")
        raster(satisfiedRule, "satisfied-password-rule-dark-green-on-green")
        XCTAssertFalse(change.isEnabled, "Current and confirmation remain empty")
        XCTAssertEqual(try disabledGuardTransportCount("PATCH /api/users/password/change"), 0)
        open(["--qa-push", "HelpCenter"] + english)
        XCTAssertTrue(waitForAuditScreen("help-center"))
        let support = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "support@carezaar.com")).firstMatch
        try expose(support, above: app.buttons["Delete Account"].firstMatch)
        raster(support, "help-description-gray-on-white")
        open(["--qa-tab", "matches"] + english)
        XCTAssertTrue(waitForAuditScreen("matches"))
        let preferences = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Update your")).firstMatch
        try expose(preferences, above: app.buttons["Matches"].firstMatch)
        raster(preferences, "matches-preferences-gray-on-role-panel")
    }

    /// Root records simulator video at the largest accessibility text size and
    /// reviews the popup while each touch is held. A passing test proves only
    /// native target size, complete labels and execution of the hold gestures;
    /// a screenshot after release does not establish viewer presentation.
    func testCaptureNativeTabLargeContentViewerHolds() throws {
        guard let email = env["QA_EMAIL"], !email.isEmpty,
              let password = env["QA_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Requires the owned client fixture; root must record and review simulator video of the held touches.")
        }
        open(["--qa-signout", "--qa-login-env", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"])
        XCTAssertTrue(waitForAuditScreen("matches"), "Actual Matches page did not open before viewer capture")
        let timestamp = ISO8601DateFormatter()
        for label in ["Matches", "Messages", "Profile"] {
            // The top avatar also has Profile's label. Only the actual bottom
            // navigation button should receive the recorded long press.
            let candidates = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            let tab = try XCTUnwrap(candidates.filter { $0.isHittable }.max(by: { $0.frame.minY < $1.frame.minY }),
                                    "Native bottom tab target is missing")
            XCTAssertEqual(tab.label, label, "Native tab must retain its complete label")
            XCTAssertGreaterThanOrEqual(tab.frame.width, 44, "Native tab target width is below 44 points")
            XCTAssertGreaterThanOrEqual(tab.frame.height, 44, "Native tab target height is below 44 points")
            print("LCV HOLD START \(label) \(timestamp.string(from: Date()))")
            tab.press(forDuration: 5)
            print("LCV HOLD END \(label) \(timestamp.string(from: Date()))")
            if env["QA_SHOT_DIR"] != nil { saveReadabilityEvidence("tab-lcv-\(label.lowercased())-after-release") }
        }
        let scope = XCTAttachment(string: "Captured five-second native holds for Matches, Messages and Profile. XCTest verifies labels, 44-point targets and performed gestures only. Large Content Viewer presentation requires root's rendered-video review while each touch is held; post-release images are not viewer proof.")
        scope.name = "large-content-viewer-capture-scope"
        scope.lifetime = .keepAlways
        add(scope)
    }

    func testLargestDynamicTypeSeenNotificationPreservesTextAndOpensDetails() throws {
        guard env["QA_SHOT_DIR"] != nil, let email = env["QA_EMAIL"], let password = env["QA_PASSWORD"] else {
            throw XCTSkip("Requires owned-fixture credentials and a private QA_SHOT_DIR.")
        }
        let token = try CarezaarAPI.login(email, password)
        XCTAssertFalse(token.isEmpty, "Owned fixture sign-in failed")
        let subjects = try CarezaarAPI.call("GET", "base/subjects?ts_cache=0", token: token)["result"] as? [[String: Any]] ?? []
        let notifications = try CarezaarAPI.call("GET", "users/notifications?page=1&perPage=50", token: token)["result"] as? [[String: Any]] ?? []
        let candidates = notifications.compactMap { notification -> (String, String, String)? in
            // Only already-seen profile destinations: tapping must not PATCH /see
            // or navigate to a chat that could mark messages as seen.
            guard let seen = notification["seen_at"], !(seen is NSNull),
                  let partner = notification["partner"] as? [String: Any],
                  let first = partner["first_name"] as? String,
                  let last = partner["last_name"] as? String,
                  let timestamp = notification["created_at"] as? String, !timestamp.isEmpty,
                  let subject = subjects.first(where: { String(describing: $0["id"] ?? "") == String(describing: notification["subject_id"] ?? "") }),
                  let code = subject["code"] as? String, !code.hasPrefix("chat"), code != "match_accept",
                  let translation = (subject["translations"] as? [[String: Any]])?.first(where: { ($0["language_id"] as? NSNumber)?.intValue == 1 }),
                  let event = translation["name"] as? String, !event.isEmpty else { return nil }
            return ("\(first) \(last)".trimmingCharacters(in: .whitespaces), event, timestamp)
        }
        guard let expected = candidates.max(by: { $0.0.count + $0.1.count + $0.2.count < $1.0.count + $1.1.count + $1.2.count }) else {
            throw XCTSkip("Requires an existing already-seen owned-fixture profile notification; this test will not mutate unread state or create data.")
        }
        open(["--qa-signout", "--qa-login-env", "--qa-push", "Notifications", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"])
        XCTAssertTrue(waitForAuditScreen("notifications"), "Notifications destination failed readiness")
        saveReadabilityEvidence("notifications-largest-row-top")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@", expected.0, expected.1, expected.2)).firstMatch
        makeReachable(row)
        XCTAssertTrue(row.exists && row.isHittable, "The longest eligible existing notification row is not scroll-reachable")
        XCTAssertTrue(row.label.contains(expected.0) && row.label.contains(expected.1) && row.label.contains(expected.2),
                      "Notification accessibility must preserve full name, full event and exact raw server timestamp")
        saveReadabilityEvidence("notifications-largest-row-reached")
        row.tap()
        let detail = app.descendants(matching: .any).matching(identifier: "notification-detail").firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 15), "Notification tap must open its detail sheet")
        saveReadabilityEvidence("notifications-largest-detail-top")
        for fullText in [expected.0, expected.1, expected.2] {
            let text = detail.staticTexts[fullText].firstMatch
            makeReachable(text)
            XCTAssertTrue(text.exists && text.isHittable, "Notification detail must expose the complete server text")
            XCTAssertTrue(text.label == fullText, "Notification detail changed the server text")
        }
        let show = app.buttons["notification-show"]
        makeReachable(show)
        XCTAssertTrue(show.exists && show.isHittable, "Show must remain scroll-reachable at largest text size")
        saveReadabilityEvidence("notifications-largest-detail-bottom")
        show.tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 15), "Show did not dismiss the detail sheet")
        let destinationBack = app.buttons["BackButton"]
        XCTAssertTrue(destinationBack.waitForExistence(timeout: 20), "Show destination did not expose its actual native BackButton")
        let destinationPartner = app.staticTexts[expected.0].firstMatch
        makeReachable(destinationPartner)
        XCTAssertTrue(destinationPartner.exists && destinationPartner.isHittable,
                      "Show did not open the expected notification partner's actual profile heading")
        saveReadabilityEvidence("notifications-largest-show-destination")
    }

    private func makeReachable(_ element: XCUIElement) {
        for _ in 0..<24 {
            if element.exists && element.isHittable { return }
            if element.exists && element.frame.maxY < app.frame.minY + 70 { app.swipeDown(velocity: .slow) }
            else { app.swipeUp(velocity: .slow) }
        }
    }

    private func saveReadabilityEvidence(_ name: String) {
        save(name)
        guard let dir = env["QA_SHOT_DIR"] else { return }
        // Private raw evidence only. Root redacts identifiers/email before sharing.
        do { try app.debugDescription.write(toFile: "\(dir)/\(prefix)-\(name).txt", atomically: true, encoding: .utf8) }
        catch { XCTFail("Could not save readability hierarchy") }
    }

    /// Labels verified against current CMS English, French and Arabic contents.
    /// Readiness uses the actual destination, rather than elapsed launch time.
    private func waitForAuditScreen(_ name: String) -> Bool {
        let matches = ["Matches", "Correspondances", "المطابقات"]
        let messages = ["Messages", "الرسائل"]
        let profile = ["Profile", "Profil", "الملف الشخصي"]
        func text(_ labels: [String]) -> Bool {
            app.staticTexts.matching(NSPredicate(format: "label IN %@", labels)).firstMatch.exists
        }
        func buttons(_ labels: [String]) -> [XCUIElement] {
            app.buttons.matching(NSPredicate(format: "label IN %@", labels)).allElementsBoundByIndex
        }
        func mainTabs(selected labels: [String]) -> Bool {
            !buttons(matches).isEmpty && !buttons(messages).isEmpty && !buttons(profile).isEmpty
                && buttons(labels).contains { $0.isSelected }
        }
        func navigation(_ titles: [String]) -> Bool {
            app.navigationBars.matching(NSPredicate(format: "identifier IN %@ OR label IN %@", titles, titles)).firstMatch.exists
        }
        let ready = NSPredicate { _, _ in
            switch name {
            case "intro":
                return !buttons(["Sign in", "Se connecter", "تسجيل الدخول"]).isEmpty
            case "matches":
                return mainTabs(selected: matches) && text(["My Matches", "Mes correspondances", "مطابقاتي"])
            case "messages":
                return mainTabs(selected: messages) && text(["All your conversations in one place", "Toutes vos conversations au même endroit", "جميع محادثاتك في مكان واحد"])
            case "profile":
                return mainTabs(selected: profile) && text(["Manage your personal information and account settings.", "Gérez vos informations personnelles et les paramètres de votre compte.", "إدارة معلوماتك الشخصية وإعدادات حسابك."])
            case "manage-matches":
                return navigation(matches) && !buttons(["History", "Historique", "السجل"]).isEmpty && !buttons(["Requests", "Demandes", "الطلبات"]).isEmpty
            case "notifications":
                return navigation(["Notifications", "الإشعارات"])
            case "delete-account":
                return navigation(["Delete Account", "Supprimer le compte", "حذف الحساب"])
            case "change-password":
                return navigation(["Change Password", "Changer le mot de passe", "تغيير كلمة المرور"]) && self.app.secureTextFields.count == 3
            case "help-center":
                return navigation(["Help Center", "Centre d'aide", "مركز المساعدة"])
            default:
                return false
            }
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 60) == .completed
    }

    /// Profile photo edge cases on the kept QA account, without changing it: cancel
    /// the crop; a 24-megapixel HEIC (added to the library by the runner, the only photo
    /// dated today); and Save during a network failure. Nothing is saved.
    func testPhotoCancelLargeHeicAndUploadFailure() throws {
        let email = env["QA_EMAIL"] ?? "", password = env["QA_PASSWORD"] ?? ""
        let token = try CarezaarAPI.login(email, password)
        let photoBefore = "\(try CarezaarAPI.me(token)["photo"] ?? "nil")"
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = email
        app.launchEnvironment["QA_PASSWORD"] = password
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-push", "ProfileEdit", "--qa-offline", "75", "400"]
        let launched = Date()
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        let upload = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Upload Photo")).firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 30))
        let removePhoto = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Remove Photo")).firstMatch
        let hadPhoto = removePhoto.exists

        func pickNewest() {
            upload.tap()
            let gallery = app.buttons["Gallery"]
            XCTAssertTrue(gallery.waitForExistence(timeout: 5)); gallery.tap()
            let cells = app.images.matching(identifier: "PXGGridLayout-Info")
            XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 15), "photo grid")
            if app.buttons["Close"].exists { app.buttons["Close"].tap() }
            // The runner's file is the only photo dated today (the samples are 2009–2018).
            let today = Date().formatted(.dateTime.month(.wide).day(.twoDigits).locale(Locale(identifier: "en_US")))
            let added = cells.matching(NSPredicate(format: "label CONTAINS %@", today)).firstMatch
            XCTAssertTrue(added.exists, "the added 24 MP HEIC is not in the library (\(today))")
            added.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        // 1. Cancel the crop: nothing changes.
        pickNewest()
        let confirm = app.buttons["Confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 30), "crop screen (large HEIC)")
        save("photo-crop-large-heic")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(upload.waitForExistence(timeout: 10), "Cancel did not return to the form")
        XCTAssertEqual(removePhoto.exists, hadPhoto, "Cancel changed the photo")
        // 2. The large HEIC crops and applies.
        pickNewest()
        XCTAssertTrue(confirm.waitForExistence(timeout: 30)); confirm.tap()
        XCTAssertTrue(removePhoto.waitForExistence(timeout: 15), "large HEIC not applied")
        save("photo-applied-large-heic")
        // 3. Save while the connection is down: an error, the form stays, nothing saved.
        let wait = launched.addingTimeInterval(78).timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        let saveButton = app.buttons["Save"].firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5)); saveButton.tap()
        let error = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Cannot communicate")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 30), "no error for a failed upload")
        save("photo-upload-failed")
        XCTAssertTrue(saveButton.exists, "left the form after a failed save")
        app.terminate()
        XCTAssertEqual("\(try CarezaarAPI.me(token)["photo"] ?? "nil")", photoBefore, "the kept account's photo changed")
    }

    /// Guards the shared native button style without authorizing account deletion.
    func testEmptyDeleteAccountNativeDisabledButtonCannotSubmit() throws {
        try verifyDisabledGuardOwnedIdentity()
        open(["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", "DeleteAccount"])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Select a reason"].waitForExistence(timeout: 30))
        let awareness = app.buttons["I am aware of the consequences of this decision."]
        XCTAssertTrue(awareness.exists)
        XCTAssertFalse(awareness.isSelected)
        try verifyDisabledNativeAction("Delete Account", routeTitle: "Delete Account",
                                       mutation: "DELETE /api/users", evidenceName: "empty-delete-native-disabled-guard")
        XCTAssertTrue(app.buttons["Select a reason"].exists)
        XCTAssertFalse(awareness.isSelected)
    }

    /// Empty current/new/confirmation fields must never reach password mutation.
    func testEmptyChangePasswordNativeDisabledButtonCannotSubmit() throws {
        try verifyDisabledGuardOwnedIdentity()
        open(["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", "ChangePassword"])
        defer { app.terminate() }
        let placeholders = ["Enter your current password...", "Enter your new password...", "Confirm your new password..."]
        for placeholder in placeholders {
            let field = app.secureTextFields[placeholder]
            XCTAssertTrue(field.waitForExistence(timeout: 30))
            let value = field.value as? String
            XCTAssertTrue(value == "" || value == placeholder, "Untouched secure field must expose an empty string or its exact placeholder")
        }
        try verifyDisabledNativeAction("Change Password", routeTitle: "Change Password",
                                       mutation: "PATCH /api/users/password/change", evidenceName: "empty-password-native-disabled-guard")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Disabled action must not open password confirmation")
        for placeholder in placeholders {
            let field = app.secureTextFields[placeholder]
            XCTAssertTrue(field.exists, "Untouched secure field must remain on the same form")
            let value = field.value as? String
            XCTAssertTrue(value == "" || value == placeholder, "Disabled attempt must retain an empty secure field or its exact placeholder")
        }
    }

    private func verifyDisabledGuardOwnedIdentity() throws {
        guard let email = env["QA_EMAIL"], !email.isEmpty,
              let password = env["QA_PASSWORD"], !password.isEmpty,
              let clientID = env["QA_CLIENT_USER_ID"], !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let caregiverID = env["QA_CG_ID"], !caregiverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              clientID != caregiverID else {
            throw XCTSkip("Retained owned primary credentials and distinct nonempty opaque fixture IDs required")
        }
        let token = try CarezaarAPI.login(email, password)
        guard !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let me = try CarezaarAPI.me(token)
        let id = me["id"].map { String(describing: $0) } ?? ""
        let role = me["role"] as? String
        let owned = (id == clientID && role == "client") || (id == caregiverID && role == "caregiver")
        XCTAssertTrue(owned, "Exact retained primary identity and role required")
        guard owned else { throw URLError(.userAuthenticationRequired) }
    }

    private func disabledGuardTransportCount(_ key: String) throws -> Int {
        let ledger = app.staticTexts["qa-request-counts"]
        guard ledger.waitForExistence(timeout: 10), !ledger.label.isEmpty else {
            XCTFail("Actual native transport ledger required")
            throw URLError(.cannotParseResponse)
        }
        let prefix = key + "="
        guard let line = ledger.label.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return 0 }
        guard let count = Int(line.dropFirst(prefix.count)), count >= 0 else {
            XCTFail("Transport count must decode exactly")
            throw URLError(.cannotParseResponse)
        }
        return count
    }

    private func verifyDisabledNativeAction(_ label: String, routeTitle: String,
                                            mutation: String, evidenceName: String) throws {
        let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        let navigation = app.navigationBars.matching(NSPredicate(format: "identifier == %@ OR label == %@", routeTitle, routeTitle)).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            navigation.exists && button.exists && button.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        guard navigation.exists, button.exists, button.isHittable else { throw URLError(.cannotParseResponse) }
        XCTAssertFalse(button.isEnabled, "Real native action must expose disabled semantics")
        // Never attempt a destructive action if the disabled precondition failed.
        guard !button.isEnabled else { throw URLError(.cannotParseResponse) }
        XCTAssertTrue(app.frame.contains(button.frame), "Observed disabled action must be entirely on screen")
        guard app.frame.contains(button.frame) else { throw URLError(.cannotParseResponse) }
        XCTAssertGreaterThan(try disabledGuardTransportCount("GET /api/auth/info"), 0,
                             "App-owned native login must reach actual identity transport")
        let before = try disabledGuardTransportCount(mutation)
        XCTAssertEqual(before, 0)
        guard before == 0 else { throw URLError(.cannotParseResponse) }
        let crop = XCTAttachment(screenshot: button.screenshot())
        crop.name = evidenceName + "-button-only"; crop.lifetime = .keepAlways; add(crop)
        // XCTest's disabled element tap may refuse. Use only the observed genuine
        // button center so native disabled handling itself receives the attempt.
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let unchanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            navigation.exists && button.exists && button.isHittable && !button.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unchanged], timeout: 5), .completed)
        Thread.sleep(forTimeInterval: 2)
        let after = try disabledGuardTransportCount(mutation)
        XCTAssertTrue(navigation.exists && button.exists && button.isHittable)
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(after, 0, "Disabled native attempt must make no mutation request")
        let record: [String: Any] = ["controlLabel": label, "expectedEnabled": false,
            "observedEnabledAfterAttempt": button.isEnabled, "pageUnchanged": navigation.exists,
            "mutationPath": mutation, "requestCountBefore": before, "requestCountAfter": after,
            "observedCenterTapAttempted": true, "fieldsNeverFilled": true]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = evidenceName; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func open(_ args: [String]) {
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"] ?? ""
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"] ?? ""
        // QA_LAUNCH_EXTRA, e.g. "-carezaar.languageCode ar -carezaar.languageId 3", runs
        // the sweep in another language.
        app.launchArguments = args + (env["QA_LAUNCH_EXTRA"] ?? "").split(separator: " ").map(String.init)
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        let busy = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch
        sleep(4)
        _ = busy.waitForNonExistence(timeout: 40)
        let notNow = app.buttons["Not Now"]
        if notNow.exists { notNow.tap() }
        sleep(1)
    }

    private func capture(_ name: String) {
        save("\(name)-top")
        app.swipeUp(velocity: .fast); app.swipeUp(velocity: .fast); sleep(1)
        save("\(name)-bottom")
    }

    private func save(_ name: String) {
        guard let dir = env["QA_SHOT_DIR"] else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(prefix)-\(name).png"))
    }
}
