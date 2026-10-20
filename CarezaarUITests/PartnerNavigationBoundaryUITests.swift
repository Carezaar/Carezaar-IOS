import XCTest

/// Read-only native boundary coverage. No relation changes, account deletion,
/// message creation, or personal media. The runner supplies owned fixture secrets.
final class PartnerNavigationBoundaryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private struct Fixture {
        let token: String
        let partnerID: String
        let kind: String
        let profileRoute: String
        let endpoint: String
    }

    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app?.terminate() }

    private func fixture() throws -> Fixture {
        guard let email = env["QA_EMAIL"], !email.isEmpty,
              let password = env["QA_PASSWORD"], !password.isEmpty,
              let clientID = env["QA_CLIENT_USER_ID"], !clientID.isEmpty,
              let caregiverID = env["QA_CG_ID"], !caregiverID.isEmpty else {
            throw XCTSkip("Both owned fixture IDs and primary credentials are required")
        }
        let token = try CarezaarAPI.login(email, password)
        XCTAssertFalse(token.isEmpty, "Primary owned fixture must authenticate")
        let me = try CarezaarAPI.me(token)
        let id = me["id"].map { String(describing: $0) } ?? ""
        let role = me["role"] as? String
        if role == "client", id == clientID {
            return Fixture(token: token, partnerID: caregiverID, kind: "caregivers",
                           profileRoute: "CaregiverDetails", endpoint: "clients/caregivers")
        }
        if role == "caregiver", id == caregiverID {
            return Fixture(token: token, partnerID: clientID, kind: "clients",
                           profileRoute: "ClientDetails", endpoint: "caregivers/clients")
        }
        XCTFail("Primary identity/role does not match either retained owned fixture")
        throw URLError(.userAuthenticationRequired)
    }

    private func launch(_ routes: String, extra: [String] = []) {
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", routes,
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"] + extra
        app.launch()
    }

    private func requestCount(_ endpoint: String) -> Int {
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 5), "Native transport ledger is required")
        let prefix = "GET /api/\(endpoint)="
        let line = ledger.label.split(separator: "\n").first { $0.hasPrefix(prefix) }
        return line.flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
    }

    private func record(_ caseID: String, _ values: [String: Any]) throws {
        // Only structural outcomes: no fixture identity, hierarchy, tokens or bodies.
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = caseID + "-native-boundary-ledger"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func missingIDFailure(endpoint: String, token: String) throws -> String {
        // Independent runner read proves the real missing-ID validation response
        // outside the app ledger. Brief §17.4 requires a general managed error
        // here: a route reference is not an input the user can correct on screen.
        let response = try CarezaarAPI.callWithHTTPStatus("GET", endpoint, token: token)
        XCTAssertEqual(response.status, 422, "Missing fixture ID must produce actual field validation")
        let fields = try XCTUnwrap(response.body["errors"] as? [String: Any])
        let message = try XCTUnwrap((fields["id"] as? [String])?.first,
                                   "Missing-ID response must identify its exact validation error")
        XCTAssertFalse(message.isEmpty)
        return try managedFailure(token: token, slug: "general_error_general")
    }

    private func managedFailure(token: String, slug: String) throws -> String {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: token)
        XCTAssertEqual(response.status, 200)
        let rows = try XCTUnwrap(response.body["result"] as? [[String: Any]])
        let row = rows.first { ($0["slug"] as? String) == slug }
        let translation = (row?["translations"] as? [[String: Any]])?.first {
            ($0["language_id"] as? NSNumber)?.intValue == 1 || ($0["language_id"] as? String) == "1"
        }
        if let message = translation?["name"] as? String, !message.isEmpty { return message }
        // Localization.t intentionally supports absent/empty CMS keys. These
        // exact English fallback strings are independently documented in
        // Feedback.message; missing reference content is not a service failure.
        switch slug {
        case "general_error_general": return "Something went wrong. Please try again."
        default:
            XCTFail("No independently specified native error fallback for this slug")
            throw URLError(.cannotParseResponse)
        }
    }

    private func leaveFailureBeforeTimer(route: String, endpoint: String, caseID: String, expectedFailure: String) throws {
        // The immediate Main poll may post the app's native notification banner.
        // Observe that poll and let its banner finish before the two-second
        // navigation window begins; keep the actual timer assertions unchanged.
        launch("HelpCenter")
        XCTAssertTrue(app.buttons["Delete Account"].firstMatch.waitForExistence(timeout: 45))
        let ledger = app.staticTexts["qa-request-counts"]
        let polled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "GET /api/users/notifications/count=1"), object: ledger)
        XCTAssertEqual(XCTWaiter.wait(for: [polled], timeout: 15), .completed)
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard").descendants(matching: .any)
            .matching(identifier: "NotificationShortLookView").firstMatch
        let clear = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !banner.exists || !banner.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [clear], timeout: 10), .completed)
        app.terminate()
        launch("HelpCenter,\(route)", extra: ["--qa-push-delay", "10"])
        let failure = app.staticTexts.matching(NSPredicate(format: "label == %@", expectedFailure)).firstMatch
        let observed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in failure.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: 45), .completed, "Actual failed destination must be observed")
        let observedAt = Date()
        // Auto-back on these pushed scenes is the real UINavigationBar control.
        // Help Center itself uses BackButton, so it cannot satisfy this selector.
        let back = app.navigationBars.buttons["Help Center"]
        XCTAssertTrue(back.exists && back.isHittable, "Failure must still be open before its delayed return")
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try record(caseID + "-departure-timing", ["secondsFromObservedFailureThroughBackTap": Date().timeIntervalSince(observedAt)])
        let deletionEntry = app.buttons["Delete Account"].firstMatch
        XCTAssertTrue(deletionEntry.waitForExistence(timeout: 5) && deletionEntry.isHittable)
        deletionEntry.tap() // Opens a screen only; never presses its deletion action.
        let destination = app.staticTexts["Delete Your Account?"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 5), "A newer native destination must open")
        let departed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !destination.exists || !destination.isHittable
        }, object: nil)
        departed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [departed], timeout: 3), .completed,
                       "A stale failed-screen timer popped the newer destination")
        let count = requestCount(endpoint)
        XCTAssertEqual(count, 1, "Failed destination must not silently retry")
        try record(caseID, ["failureObserved": true, "manualBackObserved": true,
                            "newDestinationRetainedBeyondTimer": destination.isHittable, "profileGETs": count])
    }

    func testFailedProfileShowsOneShortMessageAndReturnsWithoutRetry() throws {
        let f = try fixture()
        let endpoint = "\(f.endpoint)/qa-missing-profile-20261010"
        let expected = try missingIDFailure(endpoint: endpoint, token: f.token)
        launch("HelpCenter,\(f.profileRoute)/qa-missing-profile-20261010")
        let messages = app.staticTexts.matching(NSPredicate(format: "label == %@", expected))
        XCTAssertTrue(messages.firstMatch.waitForExistence(timeout: 45))
        XCTAssertEqual(messages.count, 1, "R9: toast only, no redundant page-level error")
        XCTAssertFalse(app.buttons["Try Again"].exists)
        let entry = app.buttons["Delete Account"].firstMatch
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: entry)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        XCTAssertEqual(requestCount(endpoint), 1)
        try record("R9-profile-short-return", ["singleMessage": true, "returnedWithoutRetry": true, "profileGETs": 1])
    }

    func testLeavingFailedProfileCancelsDelayedReturn() throws {
        let f = try fixture()
        let missing = "qa-missing-profile-20261010"
        let endpoint = "\(f.endpoint)/\(missing)"
        try leaveFailureBeforeTimer(route: "\(f.profileRoute)/\(missing)",
                                   endpoint: endpoint, caseID: "P05-004",
                                   expectedFailure: missingIDFailure(endpoint: endpoint, token: f.token))
    }

    func testLeavingFailedMatchedCancelsDelayedReturn() throws {
        let f = try fixture()
        let missing = "qa-missing-profile-20261010"
        let endpoint = "\(f.endpoint)/\(missing)"
        try leaveFailureBeforeTimer(route: "Matched/\(f.kind)/\(missing)",
                                   endpoint: endpoint, caseID: "P05-005",
                                   expectedFailure: missingIDFailure(endpoint: endpoint, token: f.token))
    }

    func testPartnerProfileReopensWithOneRequestPerOpening() throws {
        let f = try fixture()
        let partnerKey = f.kind == "caregivers" ? "caregiver" : "client"
        var sourceTab: String?
        var partnerName = ""
        // Search bounded first pages of existing relation records only. Do not
        // stage a relationship merely to manufacture a native navigation source.
        for (type, label) in [("matches", "Matches"), ("requests", "Requests"), ("histories", "History")] {
            let response = try CarezaarAPI.call("GET", "users/matches?type=\(type)&page=1&perPage=50", token: f.token)
            let records = response["result"] as? [[String: Any]] ?? []
            if let partner = records.compactMap({ $0[partnerKey] as? [String: Any] }).first(where: {
                $0["id"].map { String(describing: $0) } == f.partnerID
            }), let user = partner["user"] as? [String: Any] {
                sourceTab = label
                partnerName = [user["first_name"] as? String, user["last_name"] as? String]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                break
            }
        }
        guard let sourceTab, !partnerName.isEmpty else {
            throw XCTSkip("Owned counterpart needs an existing first-page relation card for native reopen; no mutation permitted")
        }
        launch("ManageMatches")
        let tab = app.buttons[sourceTab].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 45)); waitForBannerToClear(); tab.tap()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", partnerName)).firstMatch
        for _ in 0..<8 where !card.isHittable { app.swipeUp() }
        XCTAssertTrue(card.exists && card.isHittable, "Existing owned relation card must expose its native profile entry")
        let endpoint = "\(f.endpoint)/\(f.partnerID)"
        XCTAssertEqual(requestCount(endpoint), 0)
        for opening in 1...2 {
            card.tap()
            let favorite = app.buttons.matching(NSPredicate(format: "label IN %@", ["Add to favorites", "Remove from favorites"])).firstMatch
            XCTAssertTrue(favorite.waitForExistence(timeout: 40), "Real profile must finish loading")
            XCTAssertEqual(requestCount(endpoint), opening, "Each distinct opening must make exactly one profile GET")
            let back = app.navigationBars.buttons["Matches"]
            XCTAssertTrue(back.exists && back.isHittable); back.tap()
            let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: card)
            XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
            XCTAssertFalse(favorite.exists, "Profile must close fully before the next opening")
            XCTAssertEqual(requestCount(endpoint), opening, "Closing a profile must not reload it")
        }
        try record("P05-008", ["distinctNativeOpenings": 2, "profileGETs": requestCount(endpoint), "fullyClosedBetweenOpenings": true])
    }

    func testAbsentPartnerIDReturnsSafelyWithoutShowingPartnerData() throws {
        let f = try fixture()
        launch("HelpCenter,\(f.profileRoute)")
        let entry = app.buttons["Delete Account"].firstMatch
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: entry)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 45), .completed,
                       "Supported empty-ID profile route must fail safely and return")
        XCTAssertFalse(app.buttons["Add to favorites"].exists)
        XCTAssertFalse(app.buttons["Remove from favorites"].exists)
        XCTAssertFalse(app.buttons["match-request"].exists)
        XCTAssertFalse(app.buttons["Send a Message"].exists)
        let count = requestCount(f.endpoint + "/") + requestCount(f.endpoint)
        XCTAssertEqual(count, 1, "Empty-ID failure must not repeat collection requests")
        try record("P05-011", ["supportedEmptyProfileID": true, "returnedToHelpCenter": entry.isHittable,
                              "partnerActionsAbsent": true, "emptyIDGETs": count])
    }

    /// The app's own "New Notification(s)" system banner follows the sign-in poll and
    /// makes XCTest hit-testing unreliable while it is shown; let it finish first.
    private func waitForBannerToClear() {
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard").descendants(matching: .any)
            .matching(identifier: "NotificationShortLookView").firstMatch
        let clear = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !banner.exists || !banner.isHittable }, object: nil)
        _ = XCTWaiter.wait(for: [clear], timeout: 12)
    }

    func testInactiveMatchedThenUnavailableProfileReturnsOnceWithoutLoop() throws {
        let f = try fixture()
        let endpoint = "\(f.endpoint)/\(f.partnerID)"
        let expectedFailure = try managedFailure(token: f.token, slug: "general_error_general")
        launch("HelpCenter,Matched/\(f.kind)/\(f.partnerID)",
               extra: ["--qa-profile-inactive-then-unavailable", endpoint])
        // First real transport response is controlled inactive success, so
        // Matched redirects to profile. The second response is a null-result
        // envelope, so that profile must return once to the preceding Help Center.
        let failure = app.staticTexts.matching(NSPredicate(format: "label == %@", expectedFailure)).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 45), "Second controlled profile must show the managed failure")
        waitForBannerToClear()
        let entry = app.buttons["Delete Account"].firstMatch
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: entry)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 45), .completed)
        XCTAssertEqual(requestCount(endpoint), 2, "Inactive redirect must make one second profile GET")
        let departed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !entry.exists || !entry.isHittable
        }, object: nil)
        departed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [departed], timeout: 3), .completed,
                       "Unavailable redirected profile must not loop or pop Help Center")
        XCTAssertEqual(requestCount(endpoint), 2, "No retry or redirect loop after return")
        XCTAssertFalse(app.buttons["Add to favorites"].exists)
        XCTAssertFalse(app.buttons["Remove from favorites"].exists)
        XCTAssertFalse(app.buttons["match-request"].exists)
        XCTAssertFalse(app.buttons["Send a Message"].exists)
        try record("P05-006", ["responseSource": "debug_controlled_real_GET_responses",
                              "firstProfileInactive": true, "secondProfileResultNull": true,
                              "profileGETs": requestCount(endpoint), "returnedToHelpCenter": entry.isHittable,
                              "noLoopBeyondDelayedReturn": true])
    }
}
