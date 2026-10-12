import XCTest

/// Forced session and network conditions, using the Debug launch hooks in `QALaunch`:
/// a rejected access token (the server answers 403, as for an expired one), a dead
/// refresh token, a connection-refused window (`--qa-offline`), and a slow network
/// (`--qa-latency`). Client account; the caregiver account stages an active match.
final class SessionNetworkTests: XCTestCase {
    var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var email: String { env["QA_EMAIL"] ?? "" }
    private var password: String { env["QA_PASSWORD"] ?? "" }
    private let run = "n\(Int(Date().timeIntervalSince1970) % 1_000_000)"
    private var anonymousLogoutEvidenceOnly = false

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        guard testRun?.hasBeenSkipped != true else { return }
        if anonymousLogoutEvidenceOnly { app?.terminate() }
        else { shot("\(name)-end") }
    }

    // MARK: Session

    /// Backgrounding is an interruption, not an explicit cancellation. A valid
    /// pending login may finish, but must not be duplicated or restore another role.
    func testPendingNativeSignInSurvivesBackgroundWithoutDuplicateRequests() throws {
        anonymousLogoutEvidenceOnly = true
        let fixture = try ownedPrimaryFixture()
        launchPrimarySession(["--qa-signout", "--qa-push", "SignIn", "--qa-latency", "12"])
        let emailField = app.textFields["Enter your email address..."]
        let passwordField = app.secureTextFields["Enter your password..."]
        XCTAssertTrue(emailField.waitForExistence(timeout: 60))
        XCTAssertTrue(passwordField.exists)
        emailField.tap(); emailField.typeText(email)
        passwordField.tap()
        if app.buttons["Close"].waitForExistence(timeout: 1) {
            app.buttons["Close"].tap(); passwordField.tap()
        }
        passwordField.typeText(password)
        if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
        let submit = app.buttons["Sign In"].firstMatch
        for _ in 0..<5 where !submit.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(submit.isEnabled && submit.isHittable)
        XCTAssertEqual(requestCount("POST /api/auth/login"), 0)
        submit.tap()
        let dispatched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.requestCount("POST /api/auth/login") == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dispatched], timeout: 30), .completed)
        XCTAssertTrue(busy.exists, "Sign In must still be pending at the lifecycle transition")
        XCTAssertFalse(app.buttons["Messages"].exists)
        recordSessionEvidence("native-login-pending-before-background", fixture: fixture)
        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.state == .runningBackground
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 5), .completed)
        XCTAssertEqual(app.state, .runningBackground, "The app must actually leave the foreground")
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 40), "Valid pending login must finish after returning")
        waitForMatchesLoaded(fixture, timeout: 45)
        XCTAssertFalse(emailField.exists || passwordField.exists)
        assertNativeStoredTokenPresence(access: true, refresh: true)
        XCTAssertEqual(requestCount("POST /api/auth/login"), 1, "Background/return must not duplicate login")
        XCTAssertEqual(requestCount("GET /api/auth/info"), 1)
        XCTAssertEqual(requestCount("PUT /api/auth/refresh"), 0)
        XCTAssertEqual(requestCount(fixture.role == "client" ? "GET /api/caregivers/matches" : "GET /api/clients/matches"), 0)
        XCTAssertEqual(requestCount("POST /api/auth/register"), 0)
        XCTAssertEqual(requestCount("POST /api/users/otp/send"), 0)
        recordSessionEvidence("native-login-completed-once-after-background", fixture: fixture)
        launchPrimarySession([])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        waitForMatchesLoaded(fixture)
        assertNativeStoredTokenPresence(access: true, refresh: true)
        XCTAssertEqual(requestCount("POST /api/auth/login"), 0, "Ordinary relaunch must restore, not sign in again")
        XCTAssertEqual(requestCount("GET /api/auth/info"), 1)
        XCTAssertEqual(requestCount("PUT /api/auth/refresh"), 0)
        recordSessionEvidence("native-login-background-ordinary-relaunch", fixture: fixture)
    }

    /// Real owned saved tokens, an actual persisted reference cache, and a
    /// connection-refused startup. Host witnesses separately inspect cache bytes.
    func testOfflineSavedSessionClearsAuthenticationAndKeepsCachedWelcomeUsable() throws {
        anonymousLogoutEvidenceOnly = true
        let fixture = try ownedPrimaryFixture()
        launchPrimarySession(["--qa-signout", "--qa-login-env"])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        waitForMatchesLoaded(fixture)
        assertNativeStoredTokenPresence(access: true, refresh: true)
        recordSessionEvidence("offline-cache-warm-owned-session", fixture: fixture)
        // Give the independent host witness a bounded observation window while
        // asserting that the real authenticated UI remains stable.
        let warmLost = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.app.buttons["Messages"].exists
        }, object: nil)
        warmLost.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [warmLost], timeout: 4), .completed)

        launchPrimarySession(["--qa-offline", "0", "120"])
        XCTAssertFalse(app.launchArguments.contains("--qa-signout"))
        XCTAssertFalse(app.launchArguments.contains("--qa-login-env"))
        let signIn = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 60))
        XCTAssertTrue(signIn.isEnabled, "A valid reference cache must keep Welcome usable offline")
        XCTAssertFalse(app.buttons["Messages"].exists)
        assertNativeStoredTokenPresence(access: false, refresh: false)
        // One logical GET has an initial attempt plus three bounded retries
        // for cannotConnectToHost in APIClient.transfer.
        XCTAssertEqual(requestCount("GET /api/auth/info"), 4)
        for route in ["POST /api/auth/login", "PUT /api/auth/refresh", "DELETE /api/auth/logout",
                      "GET /api/clients/matches", "GET /api/caregivers/matches"] {
            XCTAssertEqual(requestCount(route), 0)
        }
        let mainReturned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.buttons["Messages"].exists || !signIn.exists || !signIn.isEnabled
        }, object: nil)
        mainReturned.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [mainReturned], timeout: 4), .completed)
        XCTAssertEqual(requestCount("GET /api/base/info"), 4)
        let ledger = app.staticTexts["qa-request-counts"].label
        XCTAssertFalse(ledger.split(separator: "\n").contains {
            $0.hasPrefix("GET /api/base/") && !$0.hasPrefix("GET /api/base/info=")
        }, "Offline cache use must not dispatch dataset downloads")
        let counts = XCTAttachment(string: ledger)
        counts.name = "offline-cache-complete-native-transport-ledger"
        counts.lifetime = .keepAlways; add(counts)
        recordSessionEvidence("offline-cache-welcome-tokens-cleared", fixture: fixture)
        for _ in 0..<8 {
            if signIn.isHittable { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(signIn.isHittable)
        signIn.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields.firstMatch.exists)
        XCTAssertEqual(requestCount("POST /api/auth/login"), 0)
        let emptySubmit = app.buttons["Sign In"].firstMatch
        XCTAssertTrue(emptySubmit.exists && !emptySubmit.isEnabled)
        for _ in 0..<8 {
            if emptySubmit.frame.width >= 44 && emptySubmit.frame.height >= 44
                && app.frame.contains(emptySubmit.frame) { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertGreaterThanOrEqual(emptySubmit.frame.width, 44)
        XCTAssertGreaterThanOrEqual(emptySubmit.frame.height, 44)
        XCTAssertTrue(app.frame.contains(emptySubmit.frame), "Public empty Sign In control must be fully exposed before capture")
        let crop = XCTAttachment(screenshot: emptySubmit.screenshot())
        crop.name = "offline-cache-empty-sign-in-control-only"; crop.lifetime = .keepAlways; add(crop)

        // A fresh process has no signout/login/offline or seeded-token flags.
        launchPrimarySession([])
        XCTAssertTrue(signIn.waitForExistence(timeout: 60))
        XCTAssertTrue(signIn.isEnabled)
        assertNativeStoredTokenPresence(access: false, refresh: false)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.buttons["Messages"].exists || !signIn.exists
        }, object: nil)
        restored.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        for route in ["GET /api/auth/info", "POST /api/auth/login", "PUT /api/auth/refresh",
                      "GET /api/clients/matches", "GET /api/caregivers/matches"] {
            XCTAssertEqual(requestCount(route), 0)
        }
        recordSessionEvidence("offline-cache-ordinary-online-relaunch-signed-out", fixture: fixture)
        let signedOutLost = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.buttons["Messages"].exists || !signIn.exists
        }, object: nil)
        signedOutLost.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [signedOutLost], timeout: 4), .completed)

        launchPrimarySession(["--qa-login-env"])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        waitForMatchesLoaded(fixture)
        assertNativeStoredTokenPresence(access: true, refresh: true)
        XCTAssertEqual(requestCount("POST /api/auth/login"), 1)
        recordSessionEvidence("offline-cache-fresh-owned-login-restored", fixture: fixture)
    }

    /// P08-002 native logout persistence and Cancel/Confirm branch. Authentication
    /// setup/recovery uses the private QA login hook, not typed Sign In coverage.
    /// Debug evidence reads only Keychain-backed token presence booleans, never
    /// credential values; signed-out persistence is checked in a new process.
    func testNativeLogoutCancelThenConfirmPersistsSignedOutAcrossOrdinaryRelaunch() throws {
        anonymousLogoutEvidenceOnly = true
        let fixture = try ownedPrimaryFixture()
        launchPrimarySession(["--qa-signout", "--qa-login-env"])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        waitForMatchesLoaded(fixture)
        assertNativeStoredTokenPresence(access: true, refresh: true)
        try openNativeLogoutConfirmation(fixture)
        let cancelLabel = fixture.labels["navigation_drawer_log_out_dialog_deny"] ?? "Cancel"
        let confirmLabel = fixture.labels["navigation_drawer_log_out_dialog_confirm"] ?? "Confirm"
        let cancel = app.alerts.firstMatch.buttons[cancelLabel]
        XCTAssertTrue(cancel.exists && cancel.isHittable)
        cancel.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(app.buttons["Messages"].exists)
        XCTAssertEqual(requestCount("DELETE /api/auth/logout"), 0, "Cancel must not revoke the session")
        recordSessionEvidence("logout-cancel-main-retained", fixture: fixture)

        // An ordinary launch proves Cancel retained a restorable saved session,
        // rather than just keeping an authenticated-looking screen in memory.
        launchPrimarySession([])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        waitForMatchesLoaded(fixture)
        XCTAssertGreaterThanOrEqual(requestCount("GET /api/auth/info"), 1)
        XCTAssertEqual(requestCount("POST /api/auth/login"), 0)
        XCTAssertEqual(requestCount("PUT /api/auth/refresh"), 0)
        XCTAssertEqual(requestCount("DELETE /api/auth/logout"), 0)
        assertNativeStoredTokenPresence(access: true, refresh: true)
        recordSessionEvidence("logout-cancel-ordinary-relaunch-restored", fixture: fixture)

        try openNativeLogoutConfirmation(fixture)
        let confirm = app.alerts.firstMatch.buttons[confirmLabel]
        XCTAssertTrue(confirm.exists && confirm.isHittable)
        let actionProof = XCTAttachment(screenshot: confirm.screenshot())
        actionProof.name = "native-logout-confirm-control-only"; actionProof.lifetime = .keepAlways; add(actionProof)
        confirm.tap()
        // P23-025: attempt a second real Confirm only if the native alert still
        // exposes a hittable control. Never reuse its old coordinates after the
        // alert dismisses: that would tap an unrelated underlying screen.
        let repeatedConfirm = app.alerts.firstMatch.buttons[confirmLabel]
        let secondConfirmAvailable = repeatedConfirm.exists && repeatedConfirm.isHittable
        if secondConfirmAvailable { repeatedConfirm.tap() }
        let signIn = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 40), "Confirmed native logout must reach Welcome")
        let revoked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.requestCount("DELETE /api/auth/logout") == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [revoked], timeout: 10), .completed,
                       "One native Confirm must initiate exactly one logout request")
        XCTAssertFalse(app.buttons["Messages"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let duplicateLogoutOrNavigation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.requestCount("DELETE /api/auth/logout") != 1
                || self.app.buttons["Messages"].exists
                || self.app.alerts.firstMatch.exists
                || !signIn.exists
        }, object: nil)
        duplicateLogoutOrNavigation.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [duplicateLogoutOrNavigation], timeout: 3), .completed,
                       "Logout must remain at Welcome with exactly one revocation and no reopened confirmation")
        recordSessionEvidence("logout-confirm-welcome", fixture: fixture)

        // launch() really terminates the process. No signout/login/broken-token
        // launch flag can manufacture the signed-out verdict on this relaunch.
        launchPrimarySession([])
        XCTAssertFalse(app.launchArguments.contains("--qa-signout"))
        XCTAssertFalse(app.launchArguments.contains("--qa-login-env"))
        XCTAssertTrue(signIn.waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["qa-request-counts"].exists)
        assertNativeStoredTokenPresence(access: false, refresh: false)
        let mainReturned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.buttons["Messages"].exists || !signIn.exists
        }, object: nil)
        mainReturned.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [mainReturned], timeout: 5), .completed,
                       "Ordinary relaunch must remain on Welcome without restoring Main")
        for route in ["GET /api/auth/info", "PUT /api/auth/refresh", "POST /api/auth/login",
                      "DELETE /api/auth/logout", "GET /api/clients/matches", "GET /api/caregivers/matches"] {
            XCTAssertEqual(requestCount(route), 0, "Ordinary signed-out relaunch must not use saved authentication")
        }
        recordSessionEvidence("logout-confirm-ordinary-relaunch-signed-out", fixture: fixture)
        let limits: [String: Any] = ["case": "P08-002", "role": fixture.role,
            "nativeCancelAndConfirmObserved": true, "ordinaryRelaunchRemainedSignedOut": true,
            "savedSessionNotUsedAfterLogout": true, "nativeKeychainBackedStorePresenceInspected": true,
            "storedAccessPresentAfterOrdinaryRelaunch": false, "storedRefreshPresentAfterOrdinaryRelaunch": false,
            "credentialValuesInspectedOrAttached": false,
            "setupAndRecoveryAuthentication": "private-QA-login-env-not-typed-Sign-In",
            "repeatedConfirmAvailabilityCheckedAfterFirstTap": true,
            "secondRealConfirmTapPerformed": secondConfirmAvailable,
            "repeatedConfirmTapsCovered": secondConfirmAvailable,
            "secondConfirmUnavailableReason": secondConfirmAvailable ? "not-applicable" : "native-alert-confirm-not-hittable-after-first-tap",
            "postConfirmWelcomeAndSingleLogoutRequestStableSeconds": 3]
        let data = try JSONSerialization.data(withJSONObject: limits, options: [.sortedKeys])
        let proof = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        proof.name = "P08-002-native-logout-scope-and-limits"; proof.lifetime = .keepAlways; add(proof)

        // Restore the owned account to a usable authenticated native session.
        launchPrimarySession(["--qa-login-env"])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        waitForMatchesLoaded(fixture)
        assertNativeStoredTokenPresence(access: true, refresh: true)
        XCTAssertEqual(requestCount("POST /api/auth/login"), 1)
        XCTAssertGreaterThanOrEqual(requestCount("GET /api/auth/info"), 1)
        recordSessionEvidence("logout-fresh-owned-login-restored-role-data", fixture: fixture)
    }

    private func assertNativeStoredTokenPresence(access: Bool, refresh: Bool) {
        let presence = app.staticTexts["qa-token-presence"]
        XCTAssertTrue(presence.waitForExistence(timeout: 5), "Supported native Debug storage-presence hook required")
        let expected = "accessPresent=\(access);refreshPresent=\(refresh)"
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            presence.label == expected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed,
                       "Keychain-backed storage presence differs from required native session state")
    }

    private func openNativeLogoutConfirmation(_ fixture: PrimaryFixture) throws {
        let profile = app.buttons.matching(identifier: "Profile").allElementsBoundByIndex
            .filter { $0.frame.minY > app.frame.midY }.max { $0.frame.minY < $1.frame.minY }
        let tab = try XCTUnwrap(profile, "Native bottom Profile tab required")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            tab.isHittable && !self.busy.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tab.isSelected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
        let logoutLabel = fixture.labels["profile_log_out_title"] ?? "Log Out"
        let logout = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", logoutLabel)).firstMatch
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        for _ in 0..<12 {
            if logout.exists && logout.isHittable && app.frame.contains(logout.frame) && !busy.exists { break }
            scroll.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(logout.exists && logout.isHittable && app.frame.contains(logout.frame),
                      "Actual native Log Out menu row must be reached")
        XCTAssertFalse(busy.exists, "Profile loading must finish before opening logout")
        logout.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Native logout confirmation missing")
        let message = fixture.labels["navigation_drawer_log_out_dialog_message"]
            ?? "You have selected to sign out from your account."
        XCTAssertTrue(app.alerts.firstMatch.staticTexts[message].exists, "Exact managed logout confirmation message missing")
    }

    /// A prerequisite for trustworthy fixture isolation: an explicit QA signout
    /// must authenticate the requested fixture even when the prior process saved
    /// a valid session. It must not reuse that cached user after clearing tokens.
    func testExplicitQASignoutWithSavedSessionPerformsRequestedLogin() throws {
        let fixture = try ownedPrimaryFixture()
        launchPrimarySession(["--qa-signout", "--qa-login-env"])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        XCTAssertEqual(requestCount("POST /api/auth/login"), 1)
        XCTAssertGreaterThanOrEqual(requestCount("GET /api/auth/info"), 1)
        launchPrimarySession(["--qa-signout", "--qa-login-env"])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        XCTAssertEqual(requestCount("POST /api/auth/login"), 1,
                       "Explicit fixture signout must run the requested login rather than retain a restored cached user")
        XCTAssertGreaterThanOrEqual(requestCount("GET /api/auth/info"), 1)
        recordSessionEvidence("explicit-qa-signout-saved-session", fixture: fixture)
    }

    /// The stored access token is rejected at launch: the app refreshes it and opens
    /// Main, without signing the user out.
    func testRejectedAccessTokenRefreshesOnLaunch() throws {
        let fixture = try ownedPrimaryFixture()
        launchPrimarySession(["--qa-signout", "--qa-login-env"])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        waitForMatchesLoaded(fixture)
        launchPrimarySession(["--qa-break-access"])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60), "signed out instead of refreshing")
        waitForMatchesLoaded(fixture)
        openTab("Messages")
        try waitForMessagesLoaded(fixture)
        assertRefreshedSession()
        XCTAssertEqual(requestCount("POST /api/auth/login"), 0, "Saved-session refresh must not silently perform login")
        recordSessionEvidence("rejected-access-launch", fixture: fixture)
    }

    /// The token goes bad while the app is open: the next requests refresh it.
    func testRejectedAccessTokenRefreshesMidSession() throws {
        let fixture = try ownedPrimaryFixture()
        launchPrimarySession(["--qa-signout", "--qa-login-env", "--qa-break-access-later"])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        waitForMatchesLoaded(fixture)
        let before = requestCount(fixture.matchesRequest)
        sleep(12)   // let the token go bad, then make requests that must refresh it
        openTab("Messages")
        try waitForMessagesLoaded(fixture)
        openTab("Matches")
        app.swipeDown(velocity: .fast)   // pull to refresh fires a fresh request
        waitForMatchesLoaded(fixture, minimumRequests: before + 1)
        assertRefreshedSession()
        XCTAssertFalse(text("Cannot communicate").exists, "error instead of a refresh")
        XCTAssertEqual(requestCount("POST /api/auth/login"), 1, "Recovery must not add a hidden login")
        recordSessionEvidence("rejected-access-mid-session", fixture: fixture)
    }

    /// Both tokens are dead: the user lands on Intro once, without an error loop,
    /// and can sign in again.
    func testDeadSessionReturnsToIntro() throws {
        let fixture = try ownedPrimaryFixture()
        launchPrimarySession(["--qa-signout", "--qa-login-env"])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        waitForMatchesLoaded(fixture)
        launchPrimarySession(["--qa-break-both"])
        let signIn = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 60), "a dead session did not return to Intro")
        sleep(5)
        XCTAssertTrue(signIn.exists, "Intro did not stay put")
        XCTAssertFalse(app.buttons["Messages"].exists, "Revoked session retained authenticated Main")
        XCTAssertTrue(app.staticTexts["qa-request-counts"].exists)
        XCTAssertGreaterThanOrEqual(requestCount("GET /api/auth/info"), 1)
        XCTAssertEqual(requestCount("PUT /api/auth/refresh"), 1, "Revoked token must make one bounded refresh attempt")
        recordSessionEvidence("dead-session-cleared", fixture: fixture)
        launchPrimarySession([])
        XCTAssertTrue(signIn.waitForExistence(timeout: 60), "Next ordinary launch restored a cleared session")
        XCTAssertFalse(app.buttons["Messages"].exists)
        XCTAssertEqual(requestCount("GET /api/auth/info"), 0, "Cleared saved credentials must not be retried next launch")
        XCTAssertEqual(requestCount("PUT /api/auth/refresh"), 0)
        recordSessionEvidence("dead-session-next-launch", fixture: fixture)
        launchPrimarySession(["--qa-login-env"])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60), "could not sign in again")
        waitForMatchesLoaded(fixture)
        XCTAssertEqual(requestCount("POST /api/auth/login"), 1)
        XCTAssertGreaterThanOrEqual(requestCount("GET /api/auth/info"), 1)
        recordSessionEvidence("dead-session-fresh-login", fixture: fixture)
    }

    /// Force quit and relaunch, and background/foreground, keep the session and screen.
    func testLifecycleKeepsSessionAndScreen() throws {
        let fixture = try ownedPrimaryFixture()
        launchPrimarySession(["--qa-signout", "--qa-login-env", "--qa-push", "Notifications"])
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 60))
        XCUIDevice.shared.press(.home)
        sleep(20)
        app.activate()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 10), "screen lost after background")
        launchPrimarySession([])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60), "session lost after force quit")
        waitForMatchesLoaded(fixture)
        XCTAssertGreaterThanOrEqual(requestCount("GET /api/auth/info"), 1, "Ordinary relaunch must verify saved credentials")
        XCTAssertEqual(requestCount("POST /api/auth/login"), 0, "Ordinary relaunch must restore instead of re-login")
        recordSessionEvidence("lifecycle-restored", fixture: fixture)
    }

    // MARK: Network

    /// Lists offline: a plain message with Try Again, which works once reconnected.
    func testOfflineListRecovers() throws {
        let fixture = try ownedPrimaryFixture()
        launchPrimarySession(["--qa-signout", "--qa-login-env", "--qa-offline", "25", "55"])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 24), "sign-in before the offline window")
        waitForMatchesLoaded(fixture, timeout: 20)
        waitUntilLaunchPlus(27)
        openTab("Messages")
        let retry = listRetry
        let failed = retry.waitForExistence(timeout: 20) || text("Cannot communicate").waitForExistence(timeout: 5)
        XCTAssertTrue(failed, "no error shown while offline")
        XCTAssertTrue(retry.exists && retry.isHittable, "Offline list must offer a real retry control")
        XCTAssertTrue(text("Cannot communicate").waitForExistence(timeout: 5), "Offline retry must accompany useful network feedback")
        XCTAssertFalse(text("Exception").exists || text("SQLSTATE").exists, "raw server text shown")
        recordSessionEvidence("offline-list-error-with-retry", fixture: fixture)
        let retryProof = XCTAttachment(screenshot: retry.screenshot())
        retryProof.name = "offline-list-real-retry-control"
        retryProof.lifetime = .keepAlways
        add(retryProof)
        shot("offline-messages")
        waitUntilLaunchPlus(57)
        let before = requestCount("GET /api/users/chats")
        retry.tap()
        try waitForMessagesLoaded(fixture, minimumRequests: before + 1)
        XCTAssertTrue(retry.waitForNonExistence(timeout: 10), "Recovery retained the failed-list retry state")
        XCTAssertFalse(app.buttons["Sign in"].exists)
        recordSessionEvidence("offline-list-recovered", fixture: fixture)
    }

    /// Chat offline keeps the draft and sends nothing; once back, it sends exactly once.
    func testChatOfflineKeepsDraftAndSendsOnce() throws {
        let (chatId, clientToken, cleanup) = try stageActiveChat()
        defer { cleanup() }
        launch(["--qa-signout", "--qa-login", email, password, "--qa-push", "Chat/\(chatId)", "--qa-offline", "30", "60", "--qa-request-counts"])
        XCTAssertTrue(app.textFields["Type a message..."].waitForExistence(timeout: 28), "chat did not open before the offline window")
        let field = app.textFields.firstMatch
        waitUntilLaunchPlus(32)
        let message = "offline draft \(run)"
        field.tap(); field.typeText(message)
        app.buttons["Send"].tap()
        XCTAssertTrue(text("Cannot communicate").waitForExistence(timeout: 30), "no connection message")
        XCTAssertEqual(field.value as? String, message, "draft lost after a failed send")
        XCTAssertEqual(requestCount("POST /api/users/chats/\(chatId)"), 0, "Offline preflight must not attempt a message POST")
        XCTAssertFalse(text("Couldn't confirm whether your message was sent").exists, "A failed preflight must not imply uncertain delivery")
        shot("chat-offline-draft-kept")
        // The app's offline window counts from its own start, a few seconds after the
        // test launches it; resend well clear of the window's end.
        waitUntilLaunchPlus(72)
        app.buttons["Send"].tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (field.value as? String) != message }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 40), .completed, "Acknowledged send must clear the original draft")
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 10), "Sent message bubble missing after reconnecting")
        app.buttons["Send"].doubleTap()   // an empty draft must not send anything
        sleep(3)
        let stored = try messages(chatId: chatId, token: clientToken).filter { $0 == message }
        XCTAssertEqual(stored.count, 1, "sent \(stored.count) times")
        XCTAssertEqual(requestCount("POST /api/users/chats/\(chatId)"), 1, "Empty-draft taps must not repeat the POST")
    }

    /// Slow network: the busy card shows; text typed while a message is sending is kept.
    func testSlowSendShowsProgressAndKeepsNewTyping() throws {
        let (chatId, clientToken, cleanup) = try stageActiveChat()
        defer { cleanup() }
        launch(["--qa-signout", "--qa-login", email, password, "--qa-push", "Chat/\(chatId)", "--qa-latency", "4", "--qa-request-counts"])
        XCTAssertTrue(app.textFields["Type a message..."].waitForExistence(timeout: 90))
        let field = app.textFields.firstMatch
        _ = busy.waitForNonExistence(timeout: 30)
        let first = "slow first \(run)", second = "slow second \(run)"
        field.tap(); field.typeText(first)
        app.buttons["Send"].tap()
        XCTAssertFalse(app.buttons["Send"].isEnabled, "Repeated send must be disabled during the fresh-chat preflight")
        field.typeText(second)          // keep typing during the delayed preflight
        XCTAssertTrue(busy.waitForExistence(timeout: 12), "no progress card during the delayed message POST")
        XCTAssertTrue(busy.waitForNonExistence(timeout: 30), "send did not finish")
        XCTAssertTrue(app.staticTexts[first].waitForExistence(timeout: 10))
        shot("slow-send-kept-typing")
        XCTAssertEqual(field.value as? String, second, "text typed during the send was lost")
        let stored = try messages(chatId: chatId, token: clientToken)
        XCTAssertEqual(stored.filter { $0 == first }.count, 1)
        XCTAssertEqual(requestCount("POST /api/users/chats/\(chatId)"), 1)
        XCTAssertFalse(stored.contains { $0.contains(second) }, "the new text was sent with the first message")
    }

    /// A one-line visual preview may truncate, while VoiceOver must retain the
    /// complete backend last_message together with its partner and timestamp.
    func testMessagesPreviewAccessibilityPreservesFullBackendMessage() throws {
        try XCTSkipIf(true, "Quarantined unsafe legacy fixture: Legacy preview test can send synthetic messages to an unverified chat or peer. Use the strict owned-fixture ChatNetworkBoundaryUITests instead.")

        let clientToken = try CarezaarAPI.login(email, password)
        let caregiverToken = try CarezaarAPI.login(env["QA_CG_EMAIL"] ?? "", env["QA_CG_PASSWORD"] ?? "")
        let caregiver = try CarezaarAPI.me(caregiverToken)
        let caregiverID = "\(caregiver["id"] ?? "")"
        let partnerName = [caregiver["first_name"] as? String, caregiver["last_name"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertFalse(partnerName.isEmpty, "Owned caregiver fixture needs a visible name")

        func ownedBrief() throws -> [String: Any] {
            let response = try CarezaarAPI.call("GET", "users/chats?page=1&perPage=50", token: clientToken)
            let rows = response["result"] as? [[String: Any]] ?? []
            let owned = rows.first { row in
                let partner = (row["caregiver"] as? [String: Any])?["user"] as? [String: Any]
                return "\(partner?["id"] ?? "")" == caregiverID
            }
            return try XCTUnwrap(owned, "Retained owned QA pair must have an existing conversation")
        }
        var brief = try ownedBrief()
        let chatID = try XCTUnwrap(brief["id"] as? Int, "Existing owned chat ID required")
        if (brief["last_message"] as? String ?? "").count < 200 {
            // Existing scroll fixtures use short lines. One bounded synthetic
            // message is necessary to exercise an actually truncated preview.
            let full = CarezaarAPI.result(try CarezaarAPI.call("GET", "users/chats/\(chatID)", token: caregiverToken))
            XCTAssertEqual((full["client"] as? [String: Any])?["is_match"] as? Bool, true,
                           "Synthetic preview injection requires the owned pair's active match")
            let long = "Accessibility preview \(run): " + Array(repeating: "This synthetic QA message must remain complete when the visible preview fits one line.", count: 4).joined(separator: " ")
            _ = try injectIncoming(long, chatId: chatID, caregiverToken: caregiverToken, clientToken: clientToken)
            brief = try ownedBrief()
        }
        let lastMessage = try XCTUnwrap(brief["last_message"] as? String)
        let timestamp = try XCTUnwrap(brief["updated_at"] as? String)
        XCTAssertGreaterThanOrEqual(lastMessage.count, 200, "Fixture must exceed a single-line visual preview")
        XCTAssertFalse(timestamp.isEmpty)
        app.launchEnvironment["QA_EMAIL"] = email
        app.launchEnvironment["QA_PASSWORD"] = password
        launch(["-carezaar.languageId", "1", "-carezaar.languageCode", "en", "--qa-signout", "--qa-login-env", "--qa-request-counts"])
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        openTab("Messages")
        let row = app.buttons.matching(NSPredicate(format: "label == %@", partnerName)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "Conversation must expose the backend partner name")
        let populated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (row.value as? String)?.contains(lastMessage) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [populated], timeout: 30), .completed,
                       "Actual accessibility value must expose every character of backend last_message")
        XCTAssertTrue((row.value as? String)?.contains(timestamp) == true,
                      "Accessibility must preserve the backend server-local timestamp")
        XCTAssertGreaterThanOrEqual(requestCount("GET /api/users/chats"), 1, "Messages must load through the real transport")
        shot("messages-full-accessible-preview")
        row.tap()
        XCTAssertTrue(app.textFields["Type a message..."].waitForExistence(timeout: 30), "Accessible row must open its conversation")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", lastMessage)).firstMatch.waitForExistence(timeout: 30), "Transcript must expose the same full message")
    }

    /// Actual native transcript behavior: incoming messages follow the bottom,
    /// but must preserve the reader's older-message position while scrolled up.
    func testIncomingChatFollowsBottomAndPreservesOlderReadingPosition() throws {
        let (chatId, clientToken, cleanup) = try stageActiveChat()
        defer { cleanup() }
        let caregiverToken = try CarezaarAPI.login(env["QA_CG_EMAIL"] ?? "", env["QA_CG_PASSWORD"] ?? "")
        let seeded = (1...20).map { "scroll fixture \(run) line \($0)" }
        for message in seeded {
            _ = try CarezaarAPI.call("POST", "users/chats/\(chatId)", form: ["message": message], token: caregiverToken)
        }
        let initial = try messages(chatId: chatId, token: clientToken)
        for message in seeded { XCTAssertEqual(initial.filter { $0 == message }.count, 1, "Synthetic transcript must be stored once") }

        app.launchEnvironment["QA_EMAIL"] = email
        app.launchEnvironment["QA_PASSWORD"] = password
        launch(["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", "Chat/\(chatId)"])
        XCTAssertTrue(app.textFields["Type a message..."].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts[seeded.last!].waitForExistence(timeout: 30))
        let bottomIncoming = "incoming at bottom \(run)"
        let bottomTimestamp = try injectIncoming(bottomIncoming, chatId: chatId, caregiverToken: caregiverToken, clientToken: clientToken)
        let bottomBubble = app.staticTexts[bottomIncoming]
        XCTAssertTrue(bottomBubble.waitForExistence(timeout: 30), "Quiet polling must append the partner message")
        XCTAssertTrue(bottomBubble.isHittable, "At the bottom, the incoming bubble must automatically become visible")
        XCTAssertTrue(app.staticTexts[bottomTimestamp].firstMatch.exists, "Bubble must show the exact backend timestamp")

        // Swipe the actual transcript, deriving the gesture from a visible bubble
        // instead of using guessed screen coordinates or navigating away.
        let transcript = app.scrollViews.firstMatch
        XCTAssertTrue(transcript.exists, "Native transcript scroll view missing")
        transcript.swipeDown(velocity: .slow)
        let older = seeded.dropLast(3).compactMap { message -> XCUIElement? in
            let bubble = app.staticTexts[message]
            return bubble.exists && bubble.isHittable
                && bubble.frame.minY > transcript.frame.minY + 12
                && bubble.frame.maxY < transcript.frame.maxY - 12 ? bubble : nil
        }.first
        XCTAssertNotNil(older, "Fixture must expose an older bubble after scrolling up")
        guard let older else { return }
        XCTAssertFalse(bottomBubble.isHittable, "Reader must be away from the bottom before testing preservation")
        let originalY = older.frame.midY
        let beforePoll = requestCount("GET /api/users/chats/\(chatId)")
        let scrolledIncoming = "incoming while reading \(run)"
        _ = try injectIncoming(scrolledIncoming, chatId: chatId, caregiverToken: caregiverToken, clientToken: clientToken)
        // Two ten-second polls leave time for the first response to finish. The
        // final visible bubble check below also proves the response reached the UI.
        let polled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.requestCount("GET /api/users/chats/\(chatId)") >= beforePoll + 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [polled], timeout: 35), .completed, "Quiet polling must continue while reading older messages")
        XCTAssertTrue(older.isHittable, "Incoming message must not jump the reader to the bottom")
        XCTAssertEqual(older.frame.midY, originalY, accuracy: 3, "Older bubble moved after an incoming message")
        XCTAssertFalse(app.staticTexts[scrolledIncoming].isHittable, "New bubble must remain below the scrolled-up viewport")
        for _ in 0..<8 where !app.staticTexts[scrolledIncoming].isHittable {
            transcript.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(app.staticTexts[scrolledIncoming].isHittable, "The incoming message must be available when the reader returns to the bottom")
        shot("chat-incoming-scroll-position")
    }

    /// Validate each injected message against the actual persisted transcript.
    /// These are synthetic text messages between the owned QA pair, with no media.
    private func injectIncoming(_ message: String, chatId: Int, caregiverToken: String, clientToken: String) throws -> String {
        throw XCTSkip("Quarantined unsafe legacy fixture: Legacy peer message POST lacks strict owned-principal and owned-chat verification. Use the strict owned-fixture ChatNetworkBoundaryUITests instead.")
    }

    // MARK: Helpers

    private struct PrimaryFixture {
        let token: String
        let role: String
        let labels: [String: String]
        var matchesRequest: String { "GET /api/\(role == "client" ? "clients" : "caregivers")/matches" }
        func label(_ slug: String) -> String { labels[slug] ?? slug }
    }

    /// P02 session cases require the intended owned identity; a visible tab alone
    /// must not certify a different cached account. API reads run only in XCTest.
    private func ownedPrimaryFixture() throws -> PrimaryFixture {
        guard !email.isEmpty, !password.isEmpty,
              let clientID = env["QA_CLIENT_USER_ID"], !clientID.isEmpty,
              let caregiverID = env["QA_CG_ID"], !caregiverID.isEmpty else {
            throw XCTSkip("Primary credentials and both exact retained owned user IDs are required")
        }
        let token = try CarezaarAPI.login(email, password)
        let user = try CarezaarAPI.me(token)
        let role = user["role"] as? String ?? ""
        let id = user["id"].map { String(describing: $0) } ?? ""
        guard !token.isEmpty, (role == "client" && id == clientID) || (role == "caregiver" && id == caregiverID) else {
            XCTFail("Primary credentials do not match an authorized retained role and identity")
            throw URLError(.userAuthenticationRequired)
        }
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: token)
        XCTAssertEqual(response.status, 200, "Managed reference labels could not be read")
        let rows = try XCTUnwrap(response.body["result"] as? [[String: Any]])
        var labels = [String: String]()
        for row in rows {
            guard let slug = row["slug"] as? String,
                  let translation = (row["translations"] as? [[String: Any]])?.first(where: {
                      ($0["language_id"] as? NSNumber)?.intValue == 1 || ($0["language_id"] as? String) == "1"
                  }), let name = translation["name"] as? String else { continue }
            labels[slug] = name
        }
        for slug in ["\(role)_matches_all_matches", "chat_screen_no_messages_yet", "chat_screen_empty_description", "chat_screen_messages_title"] {
            XCTAssertFalse(labels[slug]?.isEmpty ?? true, "Required managed loaded-list label missing: \(slug)")
        }
        return PrimaryFixture(token: token, role: role, labels: labels)
    }

    private func launchPrimarySession(_ arguments: [String]) {
        app.launchEnvironment["QA_EMAIL"] = email
        app.launchEnvironment["QA_PASSWORD"] = password
        launch(arguments + ["--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"])
    }

    private func waitForMatchesLoaded(_ fixture: PrimaryFixture, minimumRequests: Int = 1, timeout: TimeInterval = 40) {
        let emptyLabel = fixture.label("\(fixture.role)_matches_all_matches") + " (0)"
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let empty = self.app.staticTexts.matching(NSPredicate(format: "label == %@", emptyLabel))
            // The header alone is not an empty-state verdict: the second label
            // comes from PagedContent only after a completed empty response.
            let emptyState = empty.count >= 2 && empty.allElementsBoundByIndex.contains { $0.isHittable }
            return self.requestCount(fixture.matchesRequest) >= minimumRequests
                && (self.matchCard.exists || emptyState)
                && !self.busy.exists && !self.listRetry.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: timeout), .completed,
                       "Role-specific Matches must actually load cards or its managed empty state")
        XCTAssertTrue(app.buttons["Messages"].exists)
        XCTAssertFalse(app.buttons["Sign in"].exists)
        XCTAssertTrue(app.staticTexts["qa-request-counts"].exists)
        XCTAssertGreaterThanOrEqual(requestCount(fixture.matchesRequest), minimumRequests)
    }

    private func waitForMessagesLoaded(_ fixture: PrimaryFixture, minimumRequests: Int = 1) throws {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/chats?page=1&perPage=50", token: fixture.token)
        XCTAssertEqual(response.status, 200, "Owned conversation fixture read failed")
        let rows = try XCTUnwrap(response.body["result"] as? [[String: Any]], "Conversation list response is malformed")
        let partnerRole = fixture.role == "client" ? "caregiver" : "client"
        let expectedNames = rows.map { row -> String in
            let partner = (row[partnerRole] as? [String: Any])?["user"] as? [String: Any] ?? [:]
            let fullName = [partner["first_name"] as? String, partner["last_name"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            return fullName.isEmpty ? fixture.label("chat_screen_messages_title") : fullName
        }
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let emptyState = rows.isEmpty
                && self.app.staticTexts[fixture.label("chat_screen_no_messages_yet")].exists
                && self.app.staticTexts[fixture.label("chat_screen_empty_description")].exists
            let populatedState = !rows.isEmpty && expectedNames.contains { name in
                self.app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch.exists
            }
            return self.requestCount("GET /api/users/chats") >= minimumRequests
                && (emptyState || populatedState) && !self.busy.exists
                && !self.listRetry.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 40), .completed,
                       "Messages header alone is insufficient: actual conversation row or managed empty state must load")
        XCTAssertTrue(app.buttons["Messages"].exists)
        XCTAssertFalse(app.buttons["Sign in"].exists)
    }

    private func recordSessionEvidence(_ stage: String, fixture: PrimaryFixture) {
        let record: [String: Any] = ["stage": stage, "role": fixture.role,
            "loginAttempts": requestCount("POST /api/auth/login"),
            "authInfoAttempts": requestCount("GET /api/auth/info"),
            "refreshAttempts": requestCount("PUT /api/auth/refresh"),
            "matchListAttempts": requestCount(fixture.matchesRequest),
            "chatListAttempts": requestCount("GET /api/users/chats"),
            "welcomeVisible": app.buttons["Sign in"].exists,
            "authenticatedMainVisible": app.buttons["Messages"].exists]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted]) else {
            XCTFail("Could not preserve anonymous session evidence"); return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = stage; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Transport counts prove the real refresh route was used. The unit suite
    /// separately verifies its exact version/platform body; this overlay exposes no body.
    private func assertRefreshedSession() {
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.requestCount("PUT /api/auth/refresh") == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 30), .completed, "Expected one actual refresh transport request")
        openTab("Profile")
        XCTAssertTrue(text("Manage your personal information").waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Messages"].exists, "Authenticated Main must remain available")
        XCTAssertGreaterThanOrEqual(requestCount("GET /api/auth/info"), 1, "Restored session must load its authenticated user")
        XCTAssertEqual(requestCount("PUT /api/auth/refresh"), 1, "Concurrent protected requests must share the refresh")
    }

    private func requestCount(_ key: String) -> Int {
        let prefix = key + "="
        let summary = app.staticTexts["qa-request-counts"].label
        guard let line = summary.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return 0 }
        return Int(line.dropFirst(prefix.count)) ?? -1
    }

    private var matchCard: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "mile(s) away")).firstMatch
    }

    /// Completed failed-run native hierarchies show initial ErrorState's genuine
    /// button labelled "Try again"; pagination uses "Try Again". Match only this
    /// exact button text case-insensitively, preserving real control assertions.
    private var listRetry: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Try again")).firstMatch
    }

    private var busy: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch
    }

    private var launchedAt = Date()

    private func launch(_ args: [String]) {
        app.terminate()
        var arguments = args
        if let index = arguments.firstIndex(of: "--qa-login"), index + 2 < arguments.count {
            app.launchEnvironment["QA_EMAIL"] = arguments[index + 1]
            app.launchEnvironment["QA_PASSWORD"] = arguments[index + 2]
            arguments.replaceSubrange(index...(index + 2), with: ["--qa-login-env"])
        }
        app.launchArguments = arguments
        launchedAt = Date()
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    private func waitUntilLaunchPlus(_ seconds: TimeInterval) {
        let wait = launchedAt.addingTimeInterval(seconds).timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }

    private func text(_ fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func openTab(_ label: String) {
        var tab: XCUIElement?
        for _ in 0..<25 where tab == nil {
            tab = app.buttons.matching(identifier: label).allElementsBoundByIndex
                .filter { $0.isHittable }.max { $0.frame.minY < $1.frame.minY }
            if tab == nil { usleep(200_000) }
        }
        XCTAssertNotNil(tab, "tab \(label)"); tab?.tap()
    }

    /// An active match between the QA caregiver and this client, and its chat.
    private func stageActiveChat() throws -> (Int, String, () -> Void) {
        throw XCTSkip("Quarantined unsafe legacy fixture: Legacy chat staging creates and accepts relationships after destructive cleanup without strict owned-fixture verification. Use the strict owned-fixture ChatNetworkBoundaryUITests instead.")
    }

    private func messages(chatId: Int, token: String) throws -> [String] {
        let chat = CarezaarAPI.result(try CarezaarAPI.call("GET", "users/chats/\(chatId)", token: token))
        return (chat["messages"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
    }

    private func shot(_ label: String) {
        if let dir = env["QA_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(label).png"))
        }
    }
}

/// XCTest's own measurements: launch time, memory while scrolling, scroll hitches.
/// `QA_CHAT_ID` names a long chat for the transcript scroll.
final class PerformanceTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func configureLogin(_ app: XCUIApplication, extra: [String] = []) {
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"] ?? ""
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"] ?? ""
        app.launchArguments = ["--qa-signout", "--qa-login-env"] + extra
    }

    /// Signed-in launch to a responsive My Matches (the session is restored from the Keychain).
    func testLaunchSignedIn() {
        let app = XCUIApplication()
        configureLogin(app)
        app.launch()
        _ = app.buttons["Messages"].waitForExistence(timeout: 60)
        app.terminate()
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launchArguments = []
            app.launch()
        }
    }

    func testScrollMatches() {
        let app = XCUIApplication()
        configureLogin(app)
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "mile(s) away")).firstMatch.waitForExistence(timeout: 60))
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTMemoryMetric(application: app), XCTCPUMetric(application: app)],
                options: options) {
            app.swipeUp(velocity: .fast); app.swipeUp(velocity: .fast); app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
        }
    }

    func testScrollLongChat() {
        let app = XCUIApplication()
        configureLogin(app, extra: ["--qa-push", "Chat/\(env["QA_CHAT_ID"] ?? "")"])
        app.launch()
        XCTAssertTrue(app.textFields["Type a message..."].waitForExistence(timeout: 60))
        sleep(3)
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTMemoryMetric(application: app)], options: options) {
            app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
            app.swipeUp(velocity: .fast); app.swipeUp(velocity: .fast); app.swipeUp(velocity: .fast)
        }
    }
}
