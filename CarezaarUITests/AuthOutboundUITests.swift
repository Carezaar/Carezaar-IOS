import XCTest

/// Signed-out native controls enforce required fields, then forward filled
/// credentials without an added local email-format validator.
/// Transport counts prove attempts, not request-body bytes; SessionTests separately
/// assert raw email/password preservation through the real service transport seam.
final class AuthOutboundUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testBlankCredentialsStayBlockedByNativeRequiredFieldGate() {
        verifyOutbound(caseID: "blank", emailInput: "", passwordInput: "")
    }

    func testWhitespaceEmailStaysBlockedByNativeRequiredFieldGate() {
        verifyOutbound(caseID: "whitespace", emailInput: "   ", passwordInput: "   ")
    }

    func testMissingEmailWithFilledPasswordMakesNoLoginAttempt() {
        verifyOutbound(caseID: "missing-email", emailInput: "", passwordInput: "Synthetic invalid password!")
    }

    func testMissingPasswordWithFilledEmailMakesNoLoginAttempt() {
        verifyOutbound(caseID: "missing-password", emailInput: "someone@example.com", passwordInput: "")
    }

    func testMalformedCredentialsReachBackendAndRetryWithoutLosingInputs() {
        verifyOutbound(caseID: "malformed", emailInput: " malformed example email ",
                       passwordInput: " Synthetic invalid password! ", retry: true)
    }

    private func verifyOutbound(caseID: String, emailInput: String, passwordInput: String, retry: Bool = false) {
        app.launchArguments = ["--qa-signout", "--qa-request-counts", "--qa-push", "SignIn",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        let email = app.textFields["Enter your email address..."]
        let password = app.secureTextFields["Enter your password..."]
        XCTAssertTrue(email.waitForExistence(timeout: 60), "Native Sign In email field missing")
        XCTAssertTrue(password.exists, "Native Sign In password field missing")
        attach(["case": caseID, "result": "STARTED"], name: caseID + "-attempt")
        if !emailInput.isEmpty {
            scrollTo(email); email.tap(); email.typeText(emailInput)
            XCTAssertTrue((email.value as? String) == emailInput, "Native email typing changed the requested synthetic input")
        }
        if !passwordInput.isEmpty {
            scrollTo(password); password.tap()
            if app.buttons["Close"].waitForExistence(timeout: 1) { app.buttons["Close"].tap(); password.tap() }
            password.typeText(passwordInput)
        }
        dismissKeyboard()
        // Secure fields expose masked values. Compare their actual before/after
        // values without printing them; body equality is separate unit evidence.
        let enteredEmail = email.value as? String
        let enteredPasswordMask = password.value as? String
        let signIn = app.buttons["Sign In"].firstMatch
        scrollTo(signIn)
        XCTAssertTrue(signIn.exists && signIn.isHittable, "Native Sign In submit control missing")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Sign In")).count, 1,
                       "The native submit button must not acquire a second accessible wrapper")
        if caseID != "malformed" {
            XCTAssertFalse(signIn.isEnabled, "Required-field gate must block missing credentials")
            signIn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.staticTexts["qa-request-counts"].exists, "Actual transport ledger required for no-submission proof")
            XCTAssertEqual(requestCount("POST /api/auth/login"), 0, "Required-field gate must make no login attempt")
            XCTAssertTrue((email.value as? String) == enteredEmail && (password.value as? String) == enteredPasswordMask,
                          "Required-field gating must preserve entered inputs")
            XCTAssertTrue(email.exists && password.exists, "Required-field case must remain on native Sign In")
            XCTAssertFalse(app.alerts.firstMatch.exists)
            XCTAssertFalse(app.buttons["Messages"].exists)
            assertNoRegistrationOrOTP()
            attach(["case": caseID, "loginCount": requestCount("POST /api/auth/login"),
                    "submitEnabled": signIn.isEnabled, "inputsRetained": true,
                    "remainsSignIn": email.exists && password.exists, "result": "REQUIRED_GATE_OBSERVED"], name: caseID + "-required-gate")
            return
        }
        XCTAssertTrue(signIn.isEnabled, "Filled malformed input must not acquire a local email-format gate")
        XCTAssertEqual(requestCount("POST /api/auth/login"), 0, "No login request before the user tap")
        signIn.tap()
        waitForLoginCount(1)
        let error = expectedError()
        XCTAssertTrue(error.waitForExistence(timeout: 25), "A useful managed/common or field-validation error must be presented")
        let firstErrorCategory = errorCategory(error.label)
        let retainedEmail = (email.value as? String) == enteredEmail
        let retainedPassword = (password.value as? String) == enteredPasswordMask
        XCTAssertTrue(retainedEmail && retainedPassword, "A rejected login must retain both entered inputs")
        XCTAssertTrue(email.exists && password.exists && signIn.exists, "Rejected login must remain on native Sign In")
        XCTAssertFalse(app.buttons["Messages"].exists, "Synthetic invalid credentials must never enter authenticated Main")
        XCTAssertEqual(requestCount("POST /api/auth/login"), 1, "One tap must make exactly one actual login attempt")
        assertNoRegistrationOrOTP()
        attach(["case": caseID, "attempt": 1, "loginCount": requestCount("POST /api/auth/login"),
                "errorCategory": firstErrorCategory, "emailRetained": retainedEmail,
                "passwordMaskRetained": retainedPassword, "remainsSignIn": email.exists && password.exists,
                "result": "OBSERVED"], name: caseID + "-first-response")
        if retry {
            let dismiss = app.buttons["Dismiss"].firstMatch
            if dismiss.exists && dismiss.isHittable { dismiss.tap() }
            XCTAssertTrue(error.waitForNonExistence(timeout: 8), "First error must clear before verifying a distinct retry response")
            scrollTo(signIn)
            XCTAssertTrue(signIn.isEnabled && signIn.isHittable, "Rejected login must remain retryable")
            signIn.tap()
            waitForLoginCount(2)
            let retryError = expectedError()
            XCTAssertTrue(retryError.waitForExistence(timeout: 25), "Retry must show its own error response")
            XCTAssertEqual(requestCount("POST /api/auth/login"), 2, "Retry must add one attempt without automatic duplicates")
            XCTAssertTrue((email.value as? String) == enteredEmail && (password.value as? String) == enteredPasswordMask,
                          "Retry must preserve the same entered values")
            XCTAssertFalse(app.buttons["Messages"].exists)
            assertNoRegistrationOrOTP()
            attach(["case": caseID, "attempt": 2, "loginCount": requestCount("POST /api/auth/login"),
                    "errorCategory": errorCategory(retryError.label), "inputsRetained": true,
                    "remainsSignIn": email.exists && password.exists, "result": "OBSERVED"], name: caseID + "-retry-response")
        }
    }

    private func expectedError() -> XCUIElement {
        // Current common managed copy, plus permitted useful server field errors.
        // No arbitrary toast, SQL/stack trace or echoed credential qualifies.
        app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "This isn't working right now", "Something went wrong", "Your session has expired",
            "email field", "password field", "Email is required", "valid email address")).firstMatch
    }

    private func errorCategory(_ label: String) -> String {
        if label.localizedCaseInsensitiveContains("This isn't working right now") { return "managed_unavailable" }
        if label.localizedCaseInsensitiveContains("Something went wrong") { return "managed_unexpected" }
        if label.localizedCaseInsensitiveContains("Your session has expired") { return "managed_session_expired" }
        return "server_field_validation"
    }

    private func requestCount(_ route: String) -> Int {
        let counts = app.staticTexts["qa-request-counts"]
        let prefix = route + "="
        guard let line = counts.label.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return 0 }
        return Int(line.dropFirst(prefix.count)) ?? -1
    }

    private func waitForLoginCount(_ expected: Int) {
        XCTAssertTrue(app.staticTexts["qa-request-counts"].exists, "Actual Debug transport ledger is required")
        let count = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.requestCount("POST /api/auth/login") == expected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [count], timeout: 25), .completed, "Expected actual native login transport attempt")
    }

    private func assertNoRegistrationOrOTP() {
        XCTAssertEqual(requestCount("POST /api/auth/register"), 0)
        XCTAssertEqual(requestCount("POST /api/users/otp/send"), 0)
    }

    private func scrollTo(_ element: XCUIElement) {
        if element.exists && element.isHittable { return }
        dismissKeyboard()
        for _ in 0..<3 where !element.isHittable { app.swipeUp(velocity: .slow) }
        for _ in 0..<3 where !element.isHittable { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(element.exists && element.isHittable, "Required native Sign In control unavailable")
    }

    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "OK"])).firstMatch
        if done.exists && done.isHittable { done.tap() }
        else if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
        else { app.swipeDown(velocity: .slow) }
    }

    private func attach(_ record: [String: Any], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else {
            XCTFail("Could not preserve anonymous outbound evidence")
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
