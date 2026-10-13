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
