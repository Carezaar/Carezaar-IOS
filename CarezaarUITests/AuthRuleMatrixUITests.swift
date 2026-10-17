import XCTest
import UIKit

/// P06-001–035 exercise rendered signup semantics, never account creation.
/// Every password is synthetic and the example address is never submitted.
final class AuthRuleMatrixUITests: XCTestCase {
    private var app: XCUIApplication!
    private let otherRules = ["At least 8 characters", "At least 1 uppercase letter",
                              "At least 1 lowercase letter", "At least 1 number"]
    private let specialRule = "At least 1 special symbol"

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testP06_001Through035CreateAccountSpecialSymbolMatrix() {
        // Contract fixtures, independent of PasswordValidator's implementation.
        let allowed = Array("!@#$%^&*()_+[]{}|-;:,.<>?").map(String.init)
        let unsupported = ["=", "/", "\\", "`", "~", "€", "🙂", "'", "\"", " "]
        XCTAssertEqual(allowed.count, 25)
        XCTAssertEqual(unsupported.count, 10)
        let cases = (allowed + unsupported).enumerated().map {
            (number: $0.offset + 1, symbol: $0.element, allowed: $0.offset < allowed.count)
        }
        runCases(cases, attachmentName: "P06-001-035-native-rule-matrix")
    }

    /// Run alone across Simulator devices: native paste may share clipboard sync.
    /// Restoring another concurrent test's clipboard can race input delivery.
    func testP06_032EmojiSecurePasteDelivery() {
        runCases([(number: 32, symbol: "🙂", allowed: false)],
                 attachmentName: "P06-032-native-emoji-rule-evidence")
    }

    private func runCases(_ cases: [(number: Int, symbol: String, allowed: Bool)], attachmentName: String) {
        app.launchArguments = ["--qa-signout", "--qa-request-counts", "--qa-push", "SignUpCredentials/client",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let systemAllow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if systemAllow.waitForExistence(timeout: 5) { systemAllow.tap() }
        let email = app.textFields["Enter your email address..."]
        XCTAssertTrue(email.waitForExistence(timeout: 60), "Create Account email field missing")
        guard email.exists else { return }
        scrollTo(email)
        email.tap(); email.typeText("someone@example.com")
        XCTAssertEqual(email.value as? String, "someone@example.com")
        dismissKeyboard()

        // Reveal only the synthetic confirmation input, so Unicode/quotes/space
        // delivery can be read back exactly rather than inferred from validation.
        let secureConfirmation = app.secureTextFields["Confirm Password"]
        XCTAssertTrue(secureConfirmation.waitForExistence(timeout: 5), "Secure confirmation field missing")
        scrollTo(secureConfirmation)
        secureConfirmation.tap()
        if app.buttons["Close"].waitForExistence(timeout: 1) {
            app.buttons["Close"].tap()
            secureConfirmation.tap()
        }
        dismissKeyboard()
        // The frame may expose another password-eye control. Anchor this action
        // to the observed confirmation field, rather than selecting the first eye.
        let reveal = app.buttons.matching(NSPredicate(format: "label == %@", "Show password"))
            .allElementsBoundByIndex.filter { $0.isHittable }
            .min { abs($0.frame.midY - secureConfirmation.frame.midY) < abs($1.frame.midY - secureConfirmation.frame.midY) }
        XCTAssertNotNil(reveal, "Confirmation reveal control missing")
        guard let reveal else { return }
        XCTAssertLessThan(abs(reveal.frame.midY - secureConfirmation.frame.midY), 50,
                          "Password reveal control is not aligned with confirmation")
        XCTAssertGreaterThan(reveal.frame.midX, secureConfirmation.frame.midX,
                             "Confirmation reveal must be beside the confirmation field")
        // Its left edge overlaps the field in the captured native hierarchy;
        // use the control's own trailing interior, avoiding a tap into the field.
        reveal.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        let confirmation = app.textFields["Confirm Password"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), "Confirmation-specific reveal did not produce a native plaintext field")
        guard confirmation.exists else {
            let structure = XCTAttachment(string: app.debugDescription)
            structure.name = "synthetic-only-confirmation-reveal-hierarchy"
            structure.lifetime = .keepAlways
            add(structure)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "synthetic-only-confirmation-reveal-screen"
            image.lifetime = .keepAlways
            add(image)
            return
        }
        XCTAssertFalse(app.secureTextFields["Confirm Password"].exists, "Confirmation remained secure after its reveal action")
        let terms = app.buttons["signup-consent-checkbox"]
        scrollTo(terms)
        XCTAssertTrue(terms.exists && terms.isHittable, "Terms checkbox missing")
        guard terms.exists && terms.isHittable else { return }
        terms.tap()
        XCTAssertTrue(terms.isSelected, "Terms checkbox must expose selected semantics")

        var ledger = [[String: Any]]()
        for testCase in cases {
            let symbol = testCase.symbol
            let caseID = String(format: "P06-%03d", testCase.number)
            let expectedAllowed = testCase.allowed
            XCTContext.runActivity(named: caseID) { activity in
                attach(["case": caseID, "symbol": symbol, "result": "STARTED",
                        "expectedSpecialMet": expectedAllowed], name: caseID + "-attempt", activity: activity)
                let input = "Abcdef1" + symbol
                let password = app.secureTextFields["Enter your password..."]
                let inputMethod = symbol == "🙂" ? "native_paste" : "xctest_typeText"
                let passwordActionCompleted = replace(password, with: input, paste: symbol == "🙂")
                _ = replace(confirmation, with: input)
                let confirmationExact = (confirmation.value as? String) == input
                XCTAssertTrue(confirmationExact, "\(caseID): XCTest did not deliver the requested symbol exactly; do not infer a PASS")
                dismissKeyboard()
                let maskedValue = password.value as? String ?? ""
                let maskedCount = maskedValue.count
                let maskOnly = !maskedValue.isEmpty && maskedValue.allSatisfy { $0 == "•" || $0 == "●" }
                let expectedMaskedCount = maskedCount == input.count || maskedCount == input.utf16.count
                let deliveryVerified = passwordActionCompleted && confirmationExact && maskOnly && expectedMaskedCount
                XCTAssertTrue(deliveryVerified, "\(caseID): secure-field input delivery failed; this is not a password-policy verdict")
                let next = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Continue")).firstMatch
                XCTAssertTrue(next.exists, "\(caseID): Continue control missing")
                let expectedChip = semantic("\(specialRule), \(expectedAllowed ? "met" : "not met")")
                let updated = deliveryVerified ? expectedChip.waitForExistence(timeout: 5) : expectedChip.exists
                var reviewOpened = false
                if deliveryVerified { XCTAssertTrue(updated, "\(caseID): required special-symbol chip semantics missing") }
                var observedChips = [String]()
                for rule in otherRules + [specialRule] {
                    let met = semantic("\(rule), met")
                    let notMet = semantic("\(rule), not met")
                    let label = met.exists ? met.label : (notMet.exists ? notMet.label : "MISSING: \(rule)")
                    observedChips.append(label)
                    if deliveryVerified && rule != specialRule {
                        XCTAssertTrue(met.exists, "\(caseID): unrelated rule changed: \(rule)")
                        XCTAssertFalse(notMet.exists, "\(caseID): contradictory rule states")
                    }
                }
                if deliveryVerified {
                    XCTAssertFalse(semantic("\(specialRule), \(expectedAllowed ? "not met" : "met")").exists,
                                   "\(caseID): opposite special-symbol state must be absent")
                    // Parity v3 C1: Continue is always active; a valid password opens
                    // the email review (closed with Edit), an invalid one names the rule.
                    XCTAssertTrue(next.isEnabled, "\(caseID): Continue must always be active")
                    next.tap()
                    reviewOpened = app.buttons["Confirm"].firstMatch.waitForExistence(timeout: expectedAllowed ? 5 : 2)
                    XCTAssertEqual(reviewOpened, expectedAllowed, "\(caseID): Continue outcome differs from the requested contract")
                    if reviewOpened {
                        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit")).firstMatch.tap()
                        XCTAssertTrue(app.buttons["Confirm"].firstMatch.waitForNonExistence(timeout: 10))
                    } else {
                        XCTAssertEqual(app.staticTexts["signup-error-password"].label, "One special symbol",
                                       "\(caseID): the first unmet rule is named under Password")
                    }
                }
                XCTAssertEqual(email.value as? String, "someone@example.com", "Email changed during password replacement")
                XCTAssertTrue(terms.isSelected, "Terms selection changed during password replacement")
                XCTAssertFalse(app.alerts.firstMatch.exists, "Registration confirmation must never be opened")
                let noSubmission = assertNoRegistrationTransport(caseID)
                let oppositeAbsent = !semantic("\(specialRule), \(expectedAllowed ? "not met" : "met")").exists
                let otherChipsCorrect = otherRules.allSatisfy {
                    semantic("\($0), met").exists && !semantic("\($0), not met").exists
                }
                let emailUnchanged = (email.value as? String) == "someone@example.com"
                let noAlert = !app.alerts.firstMatch.exists
                let record: [String: Any] = ["case": caseID, "symbol": symbol,
                    "codePoints": symbol.unicodeScalars.map { String(format: "U+%04X", $0.value) },
                    "expectedSpecialMet": expectedAllowed, "observedChips": observedChips,
                    "continueExists": next.exists, "continueEnabled": next.isEnabled, "reviewOpened": reviewOpened,
                    "confirmationExact": confirmationExact, "termsSelected": terms.isSelected,
                    "secureInputMethod": inputMethod, "secureMaskCount": maskedCount,
                    "expectedGraphemeCount": input.count, "expectedUTF16Count": input.utf16.count,
                    "secureInputDeliveryVerified": deliveryVerified,
                    "emailUnchanged": emailUnchanged, "noConfirmationAlert": noAlert,
                    "noRegistrationOrOTPTransport": noSubmission,
                    "result": !deliveryVerified ? "INPUT_DELIVERY_FAILURE" : (confirmationExact && updated && oppositeAbsent && otherChipsCorrect
                        && next.exists && reviewOpened == expectedAllowed && terms.isSelected
                        && emailUnchanged && noAlert && noSubmission ? "PASS" : "POLICY_OR_UI_FAILURE")]
                ledger.append(record)
                attach(record, name: caseID, activity: activity)
                if let directory = ProcessInfo.processInfo.environment["QA_SHOT_DIR"] {
                    try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(directory)/\(caseID)-rule-matrix.png"))
                }
                // Intentionally never tap Continue, registration Confirm, or a
                // license-sheet Confirm. Only checkbox/input controls are used.
            }
        }
        XCTAssertEqual(ledger.count, cases.count, "All requested symbol cases must produce structural evidence")
        if let data = try? JSONSerialization.data(withJSONObject: ledger, options: [.prettyPrinted, .sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = attachmentName
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func semantic(_ exactLabel: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", exactLabel)).firstMatch
    }

    private func scrollTo(_ element: XCUIElement) {
        if element.exists && element.isHittable { return }
        dismissKeyboard()
        for _ in 0..<4 where !element.isHittable { app.swipeUp(velocity: .slow) }
        for _ in 0..<4 where !element.isHittable { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(element.exists && element.isHittable, "Required native form control is unavailable")
    }

    @discardableResult private func replace(_ field: XCUIElement, with input: String, paste: Bool = false) -> Bool {
        scrollTo(field)
        guard field.exists && field.isHittable else { return false }
        field.tap()
        if app.buttons["Close"].waitForExistence(timeout: 1) {
            app.buttons["Close"].tap(); field.tap()
        }
        // Each fixture is eight graphemes. Use the field's observed trailing edge
        // and over-delete, avoiding secure-field bullet counts/select-word menus.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        if paste { return pasteSyntheticInput(input, into: field) }
        field.typeText(input)
        return true
    }

    private func pasteSyntheticInput(_ input: String, into field: XCUIElement) -> Bool {
        // Simulator-local UIKit pasteboard only. Preserve arbitrary prior items
        // privately; never print, serialize or attach their values.
        let pasteboard = UIPasteboard.general
        let originalItems = pasteboard.items
        defer { pasteboard.items = originalItems }
        pasteboard.string = input
        field.press(forDuration: 1)
        let menuPaste = app.menuItems["Paste"].firstMatch
        let buttonPaste = app.buttons["Paste"].firstMatch
        let pasteControl: XCUIElement
        if menuPaste.waitForExistence(timeout: 3) { pasteControl = menuPaste }
        else if buttonPaste.waitForExistence(timeout: 3) { pasteControl = buttonPaste }
        else {
            XCTFail("Native Paste action unavailable: emoji secure-field delivery remains unverified")
            return false
        }
        pasteControl.tap()
        let allowPaste = app.buttons["Allow Paste"].firstMatch
        if allowPaste.waitForExistence(timeout: 2) { allowPaste.tap() }
        else {
            let systemAllow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"].firstMatch
            if systemAllow.exists { systemAllow.tap() }
        }
        let delivered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = field.value as? String else { return false }
            return value.allSatisfy { $0 == "•" || $0 == "●" }
                && (value.count == input.count || value.count == input.utf16.count)
        }, object: nil)
        let result = XCTWaiter.wait(for: [delivered], timeout: 5)
        XCTAssertEqual(result, .completed, "Native paste did not deliver the full synthetic emoji password")
        return result == .completed
    }

    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "OK"])).firstMatch
        if done.exists && done.isHittable { done.tap() }
        else if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
        else { app.swipeDown(velocity: .slow) }
    }

    @discardableResult private func assertNoRegistrationTransport(_ caseID: String) -> Bool {
        let counts = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(counts.exists, "\(caseID): transport ledger is required for non-submission proof")
        let forbidden = ["POST /api/auth/register=", "POST /api/users/otp/send="]
        for route in forbidden {
            XCTAssertFalse(counts.label.contains(route), "\(caseID): forbidden registration/OTP request attempted")
        }
        return counts.exists && forbidden.allSatisfy { !counts.label.contains($0) }
    }

    private func attach(_ record: [String: Any], name: String, activity: XCTActivity) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else {
            XCTFail("Could not preserve structural rule evidence")
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        activity.add(attachment)
    }
}
