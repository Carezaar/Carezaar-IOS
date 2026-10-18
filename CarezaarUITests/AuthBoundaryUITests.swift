import XCTest

/// QA1 phases 2/3/5/6 and QA2 FORM TESTING, using synthetic preauth data only.
/// §6 removes email-format validation on Sign In, not signup/recovery.
/// No registration Confirm, OTP send, reset or account mutation is performed.
final class AuthBoundaryUITests: XCTestCase {
    private var app: XCUIApplication!
    private let validPassword = "Abcdef1!"
    private let rules = ["At least 8 characters", "At least 1 uppercase letter",
                         "At least 1 lowercase letter", "At least 1 number", "At least 1 special symbol"]

    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app?.terminate(); super.tearDown() }

    func testSignupMissingAndMalformedEmailGatesForBothRoles() {
        for role in ["client", "caregiver"] {
            launch("SignUpCredentials/\(role)")
            enterPasswords(validPassword, confirmation: validPassword)
            setTerms(true)
            let email = app.textFields["Enter your email address..."]
            for (index, value) in ["", "   ", "not-an-email", "person@", "@example.com", "someone@example.com"].enumerated() {
                replace(email, with: value)
                assertGate(caseID: "signup-email-\(role)-\(index)", expected: index == 5,
                           manifest: "P06-038 (signup required/format subset)")
                let observed = email.value as? String ?? ""
                XCTAssertTrue(value.isEmpty ? (observed.isEmpty || observed == email.placeholderValue) : observed == value,
                              "Synthetic email input changed unexpectedly")
            }
        }
    }

    func testSignupPasswordBoundaryAndIndividualRulesForBothRoles() {
        // Expected rule vectors come from the requested contract, not production validators.
        let cases: [(String, String, [Bool])] = [
            ("empty", "", [false, false, false, false, false]),
            ("length-seven", "Abcde1!", [false, true, true, true, true]),
            ("length-eight", "Abcdef1!", [true, true, true, true, true]),
            ("no-uppercase", "abcdef1!", [true, false, true, true, true]),
            ("no-lowercase", "ABCDEF1!", [true, true, false, true, true]),
            ("no-number", "Abcdefg!", [true, true, true, false, true]),
            ("no-special", "Abcdef12", [true, true, true, true, false]),
            ("multiple-failures", "abcdefg", [false, false, true, false, false])
        ]
        for role in ["client", "caregiver"] {
            launch("SignUpCredentials/\(role)")
            replace(app.textFields["Enter your email address..."], with: "someone@example.com")
            setTerms(true)
            for (name, password, expected) in cases {
                enterPasswords(password, confirmation: password)
                var observed = [Bool]()
                for (index, rule) in rules.enumerated() {
                    let label = "\(rule), \(expected[index] ? "met" : "not met")"
                    let target = semantic(label)
                    XCTAssertTrue(target.waitForExistence(timeout: 5), "Contract rule state missing: \(name), \(rule)")
                    XCTAssertFalse(semantic("\(rule), \(expected[index] ? "not met" : "met")").exists,
                                   "Contradictory password rule states")
                    observed.append(semantic("\(rule), met").exists)
                }
                assertGate(caseID: "password-\(role)-\(name)", expected: expected.allSatisfy { $0 },
                           manifest: "P06-036", extra: ["ruleStates": observed, "syntheticPasswordLength": password.count])
            }
        }
    }

    func testSignupConfirmationTermsLicenseDismissAndConfirmWithoutRegistration() {
        for role in ["client", "caregiver"] {
            launch("SignUpCredentials/\(role)")
            replace(app.textFields["Enter your email address..."], with: "someone@example.com")
            enterPasswords(validPassword, confirmation: "Abcdef2!")
            setTerms(true)
            assertGate(caseID: "mismatch-\(role)", expected: false, manifest: "P06-037 (confirmation subset)")
            enterPasswords(validPassword, confirmation: "")
            assertGate(caseID: "missing-confirmation-\(role)", expected: false, manifest: "P06-037 (confirmation subset)")
            enterPasswords(validPassword, confirmation: validPassword)
            setTerms(false)
            assertGate(caseID: "missing-terms-\(role)", expected: false, manifest: "P03-002")

            // Parity v3 C2: the Terms of Use opens in an in-app viewer; viewing it
            // never ticks the agreement (the old license sheet is gone).
            openTermsOfUse()
            let bar = app.navigationBars["Terms of Use"]
            XCTAssertTrue(bar.waitForExistence(timeout: 10), "In-app Terms of Use viewer missing")
            XCTAssertTrue(app.webViews["legal-document"].waitForExistence(timeout: 10), "The client's Terms of Use PDF is shown")
            bar.buttons["OK"].tap()
            XCTAssertTrue(bar.waitForNonExistence(timeout: 10), "Viewer did not close")
            XCTAssertFalse(terms.isSelected, "Viewing the Terms of Use must not accept the agreement")
            assertGate(caseID: "terms-viewer-dismiss-\(role)", expected: false, manifest: "P03-002")
            setTerms(true)
            assertGate(caseID: "terms-accepted-\(role)", expected: true, manifest: "P03-002")

            next.tap()
            let confirm = app.buttons["Confirm"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 10) && confirm.isEnabled,
                          "Eligible signup must show its email-review confirmation")
            let edit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit")).firstMatch
            XCTAssertTrue(edit.exists && edit.isHittable, "Email review must support editing/cancellation")
            noSubmission()
            record(["case": "registration-preview-\(role)", "manifest": "P03-002",
                    "confirmAvailable": true, "registrationConfirmTapped": false, "noSubmission": true])
            edit.tap()
            XCTAssertTrue(confirm.waitForNonExistence(timeout: 10), "Edit did not dismiss signup review")
            XCTAssertEqual(app.textFields["Enter your email address..."].value as? String, "someone@example.com")
            XCTAssertTrue(terms.isSelected, "Review cancellation lost accepted license")
            assertGate(caseID: "registration-edit-\(role)", expected: true, manifest: "P03-002")
            next.tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10) && confirm.isEnabled,
                          "Reopening signup review must expose its confirmation again")
            XCTAssertTrue(edit.exists && edit.isHittable, "Reopened signup review must remain cancellable")
            noSubmission()
            record(["case": "registration-review-reopened-\(role)", "manifest": role == "client" ? "P03-002" : "P03-007",
                    "confirmAvailable": true, "registrationConfirmTapped": false, "noSubmission": true])
            edit.tap()
            XCTAssertTrue(confirm.waitForNonExistence(timeout: 10), "Second Edit did not dismiss reopened review")
            XCTAssertEqual(app.textFields["Enter your email address..."].value as? String, "someone@example.com")
            XCTAssertTrue(terms.isSelected, "Second review cancellation lost accepted license")
            assertGate(caseID: "registration-review-reopen-edit-\(role)", expected: true,
                       manifest: role == "client" ? "P03-002" : "P03-007")
        }
    }

    func testForgotPasswordRequiredMalformedGatesAndPreviewEditWithoutSendingOTP() {
        launch("ForgotPassword")
        let email = app.textFields["Enter your email address..."]
        for (index, value) in ["", "   ", "not-an-email", "person@", "@example.com", "someone@example.com"].enumerated() {
            replace(email, with: value)
            let reset = app.buttons["Reset Password"].firstMatch
            XCTAssertTrue(reset.exists && reset.isHittable)
            XCTAssertEqual(reset.isEnabled, index == 5, "Recovery email gate differs from required/format contract")
            if index != 5 {
                reset.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertFalse(app.alerts.firstMatch.exists, "Invalid recovery email opened confirmation")
            }
            noSubmission()
            record(["case": "forgot-email-\(index)", "manifest": "P02-015/P06-038 (pre-send subset)",
                    "resetEnabled": reset.isEnabled, "noSubmission": true])
        }
        app.buttons["Reset Password"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Valid recovery email did not open native confirmation")
        XCTAssertTrue(alert.buttons["Confirm"].exists && alert.buttons["Confirm"].isEnabled)
        noSubmission()
        alert.buttons["Edit"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 10))
        XCTAssertEqual(email.value as? String, "someone@example.com", "Recovery Edit lost the email input")
        noSubmission()
        record(["case": "forgot-preview-edit", "manifest": "P02-015 (dismiss subset)",
                "confirmAvailable": true, "confirmTapped": false, "emailRetained": true, "noSubmission": true])
    }

    func testPasswordAndConfirmationShowHidePreserveSyntheticValuesForBothRoles() throws {
        for role in ["client", "caregiver"] {
            launch("SignUpCredentials/\(role)")
            replace(app.textFields["Enter your email address..."], with: "someone@example.com")
            enterPasswords(validPassword, confirmation: validPassword)
            setTerms(true)
            assertGate(caseID: "show-hide-initial-\(role)", expected: true, manifest: "P06-037")

            for (fieldName, fieldID, otherID) in [
                ("password", "Enter your password...", "Confirm Password"),
                ("confirmation", "Confirm Password", "Enter your password...")
            ] {
                let secure = app.secureTextFields[fieldID]
                let otherSecure = app.secureTextFields[otherID]
                XCTAssertTrue(secure.waitForExistence(timeout: 5), "Target input must default to secure")
                assertEightCharacterMask(secure)
                XCTAssertTrue(otherSecure.exists, "Other password input must remain secure")
                assertEightCharacterMask(otherSecure)

                try tapPasswordEye("Show password", beside: secure)
                let plaintext = app.textFields[fieldID]
                XCTAssertTrue(plaintext.waitForExistence(timeout: 5), "Observed target eye did not reveal its input")
                XCTAssertEqual(plaintext.value as? String, validPassword, "Revealing changed the synthetic target value")
                XCTAssertFalse(app.secureTextFields[fieldID].exists, "Target stayed secure after Show password")
                XCTAssertTrue(otherSecure.exists, "Target eye also revealed the other password input")
                assertEightCharacterMask(otherSecure)
                noSubmission()
                let revealedShot = XCTAttachment(screenshot: plaintext.screenshot())
                revealedShot.name = "P06-037-\(role)-\(fieldName)-synthetic-revealed"
                revealedShot.lifetime = .keepAlways
                add(revealedShot)

                try tapPasswordEye("Hide password", beside: plaintext)
                let hidden = app.secureTextFields[fieldID]
                XCTAssertTrue(hidden.waitForExistence(timeout: 5), "Hide password did not restore the secure input")
                XCTAssertFalse(app.textFields[fieldID].exists, "Plaintext target remains after Hide password")
                assertEightCharacterMask(hidden)
                XCTAssertTrue(otherSecure.exists)
                assertEightCharacterMask(otherSecure)
                XCTAssertEqual(app.textFields["Enter your email address..."].value as? String, "someone@example.com")
                XCTAssertTrue(terms.isSelected, "Eye toggling changed license acceptance")
                assertGate(caseID: "show-hide-\(role)-\(fieldName)", expected: true, manifest: "P06-037",
                           extra: ["plaintextExact": true, "targetSecureMaskLength": 8,
                                   "otherInputRemainedSecure": true, "bothValuesRetained": true])
                // assertGate scrolls to Continue. Re-establish the actual target's
                // viewport before raster capture; AX mask evidence alone does not
                // establish that the mask was painted in a cropped screenshot.
                scrollTo(hidden)
                XCTAssertTrue(hidden.exists && hidden.isHittable, "Hidden input must be visible before capture")
                XCTAssertGreaterThan(hidden.frame.minY, 70, "Hidden input is above the safe capture viewport")
                XCTAssertLessThan(hidden.frame.maxY, app.frame.maxY - 70,
                                  "Hidden input is below the safe capture viewport")
                assertEightCharacterMask(hidden)
                let hiddenShot = XCTAttachment(screenshot: hidden.screenshot())
                hiddenShot.name = "P06-037-\(role)-\(fieldName)-hidden"
                hiddenShot.lifetime = .keepAlways
                add(hiddenShot)
                // This whole screen contains only this test's synthetic email
                // and password; no private QA account is entered or submitted.
                let screenShot = XCTAttachment(screenshot: app.screenshot())
                screenShot.name = "P06-037-\(role)-\(fieldName)-hidden-synthetic-full-screen"
                screenShot.lifetime = .keepAlways
                add(screenShot)
                record(["case": "hidden-mask-capture-\(role)-\(fieldName)", "manifest": "P06-037",
                        "secureAXMaskLength": 8, "targetHittable": hidden.isHittable,
                        "targetFrame": [hidden.frame.minX, hidden.frame.minY, hidden.frame.width, hidden.frame.height],
                        "fullScreenRasterAttachedForIndependentReview": true,
                        "rasterMaskVisibility": "requires actual screenshot review"])
            }
        }
    }

    private func tapPasswordEye(_ label: String, beside field: XCUIElement) throws {
        scrollTo(field)
        XCTAssertTrue(field.exists && field.isHittable, "Eye target input is unavailable")
        field.tap()
        if app.buttons["Close"].waitForExistence(timeout: 1) {
            app.buttons["Close"].tap()
            field.tap()
        }
        dismissKeyboard()
        let visibleEyes = app.buttons.matching(NSPredicate(format: "label == %@", label))
            .allElementsBoundByIndex.filter { $0.isHittable }
        // A decorative source eye is not a native control. In the failed small
        // run the only accessible Show button belonged to confirmation, 164.745pt
        // away from the main password. Never pick that eye as a fallback.
        let alignedEyes = visibleEyes.filter {
            abs($0.frame.midY - field.frame.midY) < 50 && $0.frame.midX > field.frame.midX
        }
        if alignedEyes.isEmpty {
            record(["case": "missing-aligned-password-eye", "manifest": "P06-037",
                    "fieldLabel": field.label, "eyeAction": label, "nativeEyePresent": false,
                    "targetMidY": field.frame.midY,
                    "visibleEyeMidYs": visibleEyes.map { $0.frame.midY }])
        }
        let eye = try XCTUnwrap(alignedEyes.min {
            abs($0.frame.midY - field.frame.midY) < abs($1.frame.midY - field.frame.midY)
        }, "Target input has no native password-eye control within the required alignment; decorative art cannot satisfy Show/Hide")
        XCTAssertLessThan(abs(eye.frame.midY - field.frame.midY), 50, "Selected eye is not aligned with the target input")
        XCTAssertGreaterThan(eye.frame.midX, field.frame.midX, "Selected eye is not beside the target input")
        // A confirmation overlay overlaps the field at its leading edge; use
        // this observed eye's trailing interior, as proven in AuthRuleMatrix.
        eye.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
    }

    private func assertEightCharacterMask(_ field: XCUIElement) {
        let masked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = field.value as? String else { return false }
            return value.count == 8 && value.allSatisfy { $0 == "•" || $0 == "●" }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [masked], timeout: 5), .completed,
                       "Secure input must retain the synthetic eight-character value as a mask")
    }

    private var terms: XCUIElement { app.buttons["signup-consent-checkbox"] }
    private var next: XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Continue")).firstMatch }

    private func launch(_ route: String) {
        app.terminate()
        app.launchArguments = ["--qa-signout", "--qa-request-counts", "--qa-push", route,
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCTAssertTrue(app.textFields["Enter your email address..."].waitForExistence(timeout: 60), "Native preauth field missing")
        XCTAssertTrue(app.staticTexts["qa-request-counts"].waitForExistence(timeout: 10), "Actual request ledger is required")
        noSubmission()
    }

    private func enterPasswords(_ password: String, confirmation: String) {
        replace(app.secureTextFields["Enter your password..."], with: password)
        replace(app.secureTextFields["Confirm Password"], with: confirmation)
    }

    private func setTerms(_ selected: Bool) {
        scrollTo(terms)
        XCTAssertTrue(terms.exists && terms.isHittable)
        if terms.isSelected != selected { terms.tap() }
        XCTAssertEqual(terms.isSelected, selected)
    }

    private func openTermsOfUse() {
        let link = app.links["Terms of Use"]
        scrollTo(link)
        XCTAssertTrue(link.exists && link.isHittable)
        link.tap()
    }

    /// Parity v3 C1: Continue is always active. A valid form opens the email review
    /// (closed again with Edit, never confirmed); an invalid one shows its problems
    /// under the fields and opens nothing.
    private func assertGate(caseID: String, expected: Bool, manifest: String, extra: [String: Any] = [:]) {
        scrollTo(next)
        XCTAssertTrue(next.exists && next.isHittable && next.isEnabled, "Continue must always be active")
        next.tap()
        let confirm = app.buttons["Confirm"].firstMatch
        let opened = confirm.waitForExistence(timeout: expected ? 5 : 2)
        XCTAssertEqual(opened, expected, "Unexpected signup Continue outcome")
        if opened {
            let edit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit")).firstMatch
            edit.tap()
            XCTAssertTrue(confirm.waitForNonExistence(timeout: 10))
        } else {
            let anyError = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "signup-error-")).firstMatch
            XCTAssertTrue(anyError.exists, "An invalid form must show its problem under the field")
        }
        noSubmission()
        var evidence = extra
        evidence["case"] = caseID; evidence["manifest"] = manifest
        evidence["reviewOpened"] = opened; evidence["expectedReview"] = expected
        evidence["noSubmission"] = true
        record(evidence)
        let shot = XCTAttachment(screenshot: next.screenshot())
        shot.name = caseID + "-continue-control"; shot.lifetime = .keepAlways; add(shot)
    }

    private func noSubmission() {
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.exists, "Missing ledger cannot prove no submission")
        for route in ["POST /api/auth/register", "POST /api/auth/login", "POST /api/users/otp/send", "POST /api/users/otp/verify", "POST /api/users/password/reset"] {
            let prefix = route + "="
            let line = ledger.label.split(separator: "\n").first(where: { $0.hasPrefix(prefix) })
            let count = line.map { Int($0.dropFirst(prefix.count)) ?? -1 } ?? 0
            XCTAssertEqual(count, 0, "Unexpected preauth submission: \(route)")
        }
        XCTAssertFalse(app.staticTexts["OTP Confirmation"].exists)
        XCTAssertFalse(app.buttons["Messages"].exists)
    }

    private func semantic(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func replace(_ control: XCUIElement, with value: String) {
        scrollTo(control)
        XCTAssertTrue(control.exists && control.isHittable, "Native input missing")
        control.tap()
        if app.buttons["Close"].waitForExistence(timeout: 1) { app.buttons["Close"].tap(); control.tap() }
        let existing = control.value as? String ?? ""
        // An extra delete is harmless for empty/placeholder fields and removes
        // actual secure masks without revealing a password or using the clipboard.
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        if !existing.isEmpty { control.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 1)) }
        if !value.isEmpty { control.typeText(value) }
        dismissKeyboard()
        let observed = control.value as? String ?? ""
        if value.isEmpty {
            XCTAssertTrue(observed.isEmpty || observed == control.placeholderValue, "Native input did not clear")
        } else if control.elementType == .secureTextField {
            XCTAssertTrue(observed.allSatisfy { $0 == "•" || $0 == "●" } && observed.count == value.count,
                          "Synthetic secure input was not delivered at the required length")
        } else {
            XCTAssertEqual(observed, value, "Native synthetic input delivery changed the case")
        }
    }

    private func scrollTo(_ control: XCUIElement) {
        dismissKeyboard()
        for _ in 0..<6 {
            if control.exists && control.isHittable && control.frame.minY > 70 && control.frame.maxY < app.frame.maxY - 70 { return }
            if control.exists && control.frame.minY < 70 { app.swipeDown(velocity: .slow) }
            else { app.swipeUp(velocity: .slow) }
        }
    }

    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "OK"])).firstMatch
        if done.exists && done.isHittable { done.tap() }
        else if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
        else { app.swipeDown(velocity: .slow) }
    }

    private func record(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) else {
            XCTFail("Anonymous boundary evidence could not be encoded"); return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = value["case"] as? String ?? "preauth-boundary"
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
