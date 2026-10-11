import XCTest

/// P02-012: actual public Sign In controls, not automated QALaunch login.
/// Root supplies one strictly owned primary fixture per role/device allocation.
/// No profile, account, media, preference or relationship writes are performed.
final class NativeLoginRoleUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app?.terminate(); super.tearDown() }

    func testTypedOwnedSignInLoadsCorrectRoleWithoutHiddenLoginOrRefresh() throws {
        let fixture = try ownedFixture()
        app.launchArguments = ["--qa-signout", "--qa-request-counts", "--qa-push", "SignIn",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        // Credentials remain in the test runner only. No --qa-login[-env] flag,
        // credential launch argument or credential attachment is used.
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        let emailField = app.textFields["Enter your email address..."]
        let passwordField = app.secureTextFields["Enter your password..."]
        XCTAssertTrue(emailField.waitForExistence(timeout: 60), "Public Sign In email field missing")
        XCTAssertTrue(passwordField.exists, "Public Sign In secure password field missing")
        XCTAssertTrue(app.staticTexts["qa-request-counts"].waitForExistence(timeout: 10), "Actual native request ledger required")
        let submit = app.buttons.matching(NSPredicate(format: "label == %@", "Sign In")).firstMatch
        scrollTo(submit)
        XCTAssertTrue(submit.exists && submit.isHittable)
        XCTAssertFalse(submit.isEnabled, "Empty public Sign In must remain disabled")
        XCTAssertFalse(app.buttons["Messages"].exists, "Signed-out setup unexpectedly retained Main")
        assertNoNativeAuthSubmission()

        scrollTo(emailField)
        emailField.tap()
        emailField.typeText(fixture.email)
        // Boolean comparison avoids exposing a private address in assertion text.
        XCTAssertTrue((emailField.value as? String) == fixture.email, "Public input changed the exact owned email")
        scrollTo(passwordField)
        passwordField.tap()
        if app.buttons["Close"].waitForExistence(timeout: 1) {
            app.buttons["Close"].tap()
            passwordField.tap()
        }
        passwordField.typeText(fixture.password)
        dismissKeyboard()
        let masked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = passwordField.value as? String else { return false }
            return !value.isEmpty && value.allSatisfy { $0 == "•" || $0 == "●" }
                && (value.count == fixture.password.count || value.count == fixture.password.utf16.count)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [masked], timeout: 5), .completed,
                       "Owned password was not delivered to the actual secure field at its exact length")
        scrollTo(submit)
        XCTAssertTrue(submit.isEnabled && submit.isHittable, "Valid owned input did not enable public Sign In")
        assertNoNativeAuthSubmission()
        record(stage: "public-sign-in-ready", role: fixture.role)
        let ready = XCTAttachment(screenshot: submit.screenshot())
        ready.name = "P02-012-public-sign-in-control-only"
        ready.lifetime = .keepAlways
        add(ready)
        submit.tap()

        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60), "Actual public login did not enter Main")
        let emptyLabel = fixture.matchesTitle + " (0)"
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let empty = self.app.staticTexts.matching(NSPredicate(format: "label == %@", emptyLabel))
            // A duplicated header + completed empty body proves a loaded zero
            // result. The header by itself cannot establish successful loading.
            let emptyState = empty.count >= 2 && empty.allElementsBoundByIndex.contains { $0.isHittable }
            let card = self.app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fixture.distanceLabel)).firstMatch
            let retry = self.app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Try again")).firstMatch
            return self.count("POST /api/auth/login") == 1 && self.count("GET /api/auth/info") >= 1
                && self.count(fixture.matchesRequest) >= 1 && (card.exists || emptyState) && !retry.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 40), .completed,
                       "Correct role's authenticated Matches must load data or its managed empty state")
        XCTAssertEqual(count("POST /api/auth/login"), 1, "One user tap must make exactly one login attempt")
        XCTAssertGreaterThanOrEqual(count("GET /api/auth/info"), 1, "Typed login must verify authenticated user info")
        XCTAssertGreaterThanOrEqual(count(fixture.matchesRequest), 1)
        XCTAssertEqual(count(fixture.oppositeMatchesRequest), 0, "Typed login loaded the opposite role's list")
        XCTAssertEqual(count("PUT /api/auth/refresh"), 0, "Fresh typed login must not hide a refresh/recovery transaction")
        XCTAssertEqual(count("POST /api/auth/register"), 0)
        XCTAssertEqual(count("POST /api/users/otp/send"), 0)
        XCTAssertFalse(app.buttons["Sign in"].exists)
        XCTAssertFalse(submit.exists, "Authenticated Main retained public Sign In submit")
        let matchesTabs = app.buttons.matching(identifier: "Matches").allElementsBoundByIndex
        XCTAssertTrue(matchesTabs.contains { $0.isSelected }, "Successful typed login did not select Matches")
        record(stage: "typed-login-role-list-loaded", role: fixture.role)
        // Full app screens/hierarchies could expose private fixture information;
        // only anonymous counts and the public submit control are attached.
    }

    private struct Fixture {
        let email: String
        let password: String
        let role: String
        let matchesTitle: String
        let distanceLabel: String
        var matchesRequest: String { "GET /api/\(role == "client" ? "clients" : "caregivers")/matches" }
        var oppositeMatchesRequest: String { "GET /api/\(role == "client" ? "caregivers" : "clients")/matches" }
    }

    private func ownedFixture() throws -> Fixture {
        guard let email = env["QA_EMAIL"], !email.isEmpty,
              let password = env["QA_PASSWORD"], !password.isEmpty,
              let clientID = env["QA_CLIENT_USER_ID"], !clientID.isEmpty,
              let caregiverID = env["QA_CG_ID"], !caregiverID.isEmpty else {
            throw XCTSkip("Owned primary credentials and both exact retained role identities are required")
        }
        let token = try CarezaarAPI.login(email, password)
        let user = try CarezaarAPI.me(token)
        let role = user["role"] as? String ?? ""
        let id = user["id"].map { String(describing: $0) } ?? ""
        guard !token.isEmpty, (role == "client" && id == clientID) || (role == "caregiver" && id == caregiverID) else {
            XCTFail("Refusing a primary fixture outside the authorized exact role/identity pair")
            throw URLError(.userAuthenticationRequired)
        }
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: token)
        XCTAssertEqual(response.status, 200, "Managed reference text read failed")
        let rows = try XCTUnwrap(response.body["result"] as? [[String: Any]])
        var labels = [String: String]()
        for row in rows {
            guard let slug = row["slug"] as? String,
                  let translation = (row["translations"] as? [[String: Any]])?.first(where: {
                      ($0["language_id"] as? NSNumber)?.intValue == 1 || ($0["language_id"] as? String) == "1"
                  }), let label = translation["name"] as? String else { continue }
            labels[slug] = label
        }
        let title = try XCTUnwrap(labels["\(role)_matches_all_matches"], "Managed role list title missing")
        let distance = try XCTUnwrap(labels["general_miles_away"], "Managed match-card distance label missing")
        XCTAssertFalse(title.isEmpty || distance.isEmpty, "Managed native loaded-state labels are empty")
        return Fixture(email: email, password: password, role: role, matchesTitle: title, distanceLabel: distance)
    }

    private func assertNoNativeAuthSubmission() {
        XCTAssertTrue(app.staticTexts["qa-request-counts"].exists)
        for path in ["POST /api/auth/login", "GET /api/auth/info", "PUT /api/auth/refresh",
                     "POST /api/auth/register", "POST /api/users/otp/send",
                     "GET /api/clients/matches", "GET /api/caregivers/matches"] {
            XCTAssertEqual(count(path), 0, "Private setup must not automate a native auth transaction before Sign In is tapped")
        }
    }

    private func count(_ route: String) -> Int {
        let prefix = route + "="
        let summary = app.staticTexts["qa-request-counts"].label
        guard let line = summary.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return 0 }
        return Int(line.dropFirst(prefix.count)) ?? -1
    }

    private func scrollTo(_ control: XCUIElement) {
        dismissKeyboard()
        for _ in 0..<6 {
            if control.exists && control.isHittable { return }
            if control.exists && control.frame.minY < 70 { app.swipeDown(velocity: .slow) }
            else { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(control.exists && control.isHittable, "Required public Sign In control unavailable")
    }

    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "OK"])).firstMatch
        if done.exists && done.isHittable { done.tap() }
        else if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
        else { app.swipeDown(velocity: .slow) }
    }

    private func record(stage: String, role: String) {
        let data: [String: Any] = ["case": "P02-012", "stage": stage, "role": role,
            "inputMethod": "public-native-fields", "automatedQALoginUsed": false,
            "loginAttempts": count("POST /api/auth/login"), "authInfoAttempts": count("GET /api/auth/info"),
            "refreshAttempts": count("PUT /api/auth/refresh"),
            "clientListAttempts": count("GET /api/clients/matches"),
            "caregiverListAttempts": count("GET /api/caregivers/matches")]
        guard let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) else {
            XCTFail("Anonymous typed-login evidence could not be encoded"); return
        }
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "P02-012-\(stage)-\(role)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
