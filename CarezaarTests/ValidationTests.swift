import XCTest
@testable import Carezaar
final class ValidationTests: XCTestCase {
    func testEveryListedPasswordSymbolCounts() {
        for symbol in "!@#$%^&*()_+[]{}|-;:,.<>?" {
            XCTAssertTrue(PasswordValidator.isValid("Abcdef1" + String(symbol)), "Allowed: \(symbol)")
        }
    }
    func testUnsupportedPasswordSymbolsDoNotCount() {
        for symbol in ["=", "/", "\\", "`", "~", "€", "🙂", "'", "\"", " "] {
            XCTAssertFalse(PasswordValidator.isValid("Abcdef1" + symbol), "Unsupported: \(symbol)")
        }
    }
    func testOtherPasswordRulesRemainRequired() {
        for password in ["Ab1!", "ABCDEFG1!", "abcdefg1!", "Abcdefgh!", "Abcdefg1"] {
            XCTAssertFalse(PasswordValidator.isValid(password))
        }
        XCTAssertTrue(PasswordValidator.isValid("Abcdefg1!"))
    }

    // MARK: Parity v3 C1 — every field checked at once, managed texts only

    private func text(_ slug: String, _ fallback: String) -> String { "<\(slug)>" }

    func testSignUpContinueReportsEveryEmptyFieldAtOnce() {
        let problems = SignUpCredentialsValidation.problems(email: " ", password: "", confirmation: "", accepted: false, text: text)
        XCTAssertEqual(problems, [.email: "<general_required>", .password: "<general_required>",
                                  .confirmation: "<general_required>"])
    }

    func testSignUpInvalidEmailMismatchAndFirstUnmetPasswordRule() {
        let problems = SignUpCredentialsValidation.problems(email: "not-an-email", password: "abcdefgh",
                                                           confirmation: "abcdefgX", accepted: true, text: text)
        XCTAssertEqual(problems[.email], "<signup_credentials_email_invalid>")
        // Length and lowercase are met; uppercase is the first unmet rule in checklist order.
        XCTAssertEqual(problems[.password], "<signup_credentials_password_validation_1_uppercase>")
        XCTAssertEqual(problems[.confirmation], "<signup_credentials_password_match>")
        XCTAssertNil(problems[.agreement])
        XCTAssertEqual(SignUpCredentialsValidation.problems(email: "a@b.co", password: "Ab1!", confirmation: "Ab1!",
                                                            accepted: true, text: text)[.password],
                       "<signup_credentials_password_validation_8_letters>")
        XCTAssertEqual(SignUpCredentialsValidation.problems(email: "a@b.co", password: "Abcdefg1", confirmation: "Abcdefg1",
                                                            accepted: true, text: text)[.password],
                       "<signup_credentials_password_validation_1_special_symbol>")
    }

    func testAgreementIsLastGateAfterValidFields() {
        let result = SignUpCredentialsValidation.problems(email: "test@example.com", password: "Abcdefg1!", confirmation: "Abcdefg1!", accepted: false, text: text)
        XCTAssertEqual(result, [.agreement: "<signup_credentials_accept_required>"])
    }

    func testSignUpValidFormHasNoProblems() {
        XCTAssertTrue(SignUpCredentialsValidation.problems(email: " a@b.co ", password: "Abcdefg1!", confirmation: "Abcdefg1!",
                                                           accepted: true, text: text).isEmpty)
    }

}


final class LegalConfigurationTests: XCTestCase {
    func testBuiltApplicationContainsLegalURLConfigurationKeysEvenWhenUnconfigured() throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.aariz51.carezaar", "Inspect the built application host, not a fabricated configuration dictionary")
        for key in [LegalDocumentConfiguration.termsURLKey, LegalDocumentConfiguration.privacyURLKey] {
            let value = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: key) as? String,
                                     "Built app Info.plist must contain \(key), including an empty string when unconfigured")
            XCTAssertFalse(value.contains("$("), "Built URL setting was not expanded")
            XCTAssertNoThrow(try LegalDocumentConfiguration.httpsURL(value))
        }
    }
    func testMissingLegalAddressDiffersFromInvalidConfiguredAddress() throws {
        XCTAssertNil(try LegalDocumentConfiguration.httpsURL(nil))
        XCTAssertNil(try LegalDocumentConfiguration.httpsURL("  "))
        XCTAssertEqual(try LegalDocumentConfiguration.httpsURL(" https://documents.example/terms.pdf ")?.absoluteString,
                       "https://documents.example/terms.pdf")
        for value in ["http://documents.example/terms", "file:///terms.pdf", "javascript:alert(1)", "https://user:secret@documents.example/terms"] {
            XCTAssertThrowsError(try LegalDocumentConfiguration.httpsURL(value))
        }
    }
    func testEveryLegalOpeningBuildsCacheBypassingRequestWithoutAuthorization() throws {
        let url = try XCTUnwrap(URL(string: "https://documents.example/privacy.pdf"))
        for _ in 0..<2 {
            let request = LegalDocumentConfiguration.request(for: url)
            XCTAssertEqual(request.url, url)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache, no-store")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Pragma"), "no-cache")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }
}

/// "Carezaar — Technical Alignment Tasks" (26 Oct 2026), iOS 1-3, against the Android 1.0.0
/// APK: rules `e54.m` / `ua` 6-10 (`length() > 7`, `.*[A-Z].*`, `.*[a-z].*`, `.*[0-9].*`,
/// special sets), error order `tz` 0-4, Set Up Password `iy` and Change Password `vk` gates.
final class TechnicalAlignmentPasswordTests: XCTestCase {
    private func failing(_ password: String, special: String = PasswordValidator.specialCharacters) -> [String] {
        PasswordValidator.rules(for: password, special: special).filter { !$0.isSatisfied }.map(\.id)
    }

    func testRulesInAndroidOrderAndFirstUnmetRule() {
        XCTAssertEqual(PasswordValidator.rules(for: "").map(\.id), ["8_letters", "1_uppercase", "1_lowercase", "1_number", "1_special_symbol"])
        XCTAssertEqual(PasswordValidator.firstUnmetRule("abc")?.id, "8_letters")
        XCTAssertEqual(PasswordValidator.firstUnmetRule("abcdefgh")?.id, "1_uppercase", "Uppercase before lowercase")
        XCTAssertEqual(PasswordValidator.firstUnmetRule("ABCDEFGH")?.id, "1_lowercase")
        XCTAssertEqual(PasswordValidator.firstUnmetRule("ABCDefgh")?.id, "1_number")
        XCTAssertEqual(PasswordValidator.firstUnmetRule("ABCDefg1")?.id, "1_special_symbol")
        XCTAssertNil(PasswordValidator.firstUnmetRule("ABCDef1!"))
    }

    func testLengthCountsUTF16UnitsAtTheBoundary() {
        XCTAssertEqual(failing("Ab1!xyz"), ["8_letters"])
        XCTAssertEqual(failing("Ab1!wxyz"), [])
        // Two emoji are four UTF-16 units (Kotlin `length`), though only two characters.
        XCTAssertEqual(failing("Ab1!\u{1F600}\u{1F600}"), [])
        XCTAssertEqual(failing("Ab1!\u{1F600}x"), ["8_letters"])
        // Combining accents add units too: "é" written as e + U+0301 is two.
        XCTAssertEqual(failing("Ab1!e\u{301}e\u{301}"), [])
    }

    func testLettersAndDigitsAreASCIIOnly() {
        XCTAssertEqual(failing("ÄÖÜabcd1!"), ["1_uppercase"])
        XCTAssertEqual(failing("ABCDéüñ1!"), ["1_lowercase"])
        XCTAssertEqual(failing("ABCDabc٣!"), ["1_number"], "An Arabic-Indic digit is not 0-9")
        XCTAssertEqual(failing("ABCDabc1!\u{301}"), [], "A symbol carrying a combining mark still counts, unit by unit")
    }

    func testALineTerminatorFailsEveryCharacterRuleAsInJava() {
        for terminator in ["\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(failing("Abcdef1!\(terminator)"), ["1_uppercase", "1_lowercase", "1_number", "1_special_symbol"])
        }
        XCTAssertEqual(failing("Abcdef1!\t"), [])
    }

    func testExactSpecialSetsFullAndChangePassword() {
        for c in "!@#$%^&*()_+[]{}|-;:,.<>?" { XCTAssertEqual(failing("Abcdefg1\(c)"), [], String(c)) }
        for c in "~=/\\'\"` §€" { XCTAssertEqual(failing("Abcdefg1\(c)"), ["1_special_symbol"], String(c)) }
        let narrow = PasswordValidator.changePasswordSpecialCharacters
        XCTAssertEqual(narrow, "!@#%^&*()?")
        for c in narrow { XCTAssertEqual(failing("Abcdefg1\(c)", special: narrow), [], String(c)) }
        for c in "$_+[]{}|-;:,.<>" { XCTAssertEqual(failing("Abcdefg1\(c)", special: narrow), ["1_special_symbol"], String(c)) }
    }

    func testPasswordResetGate() {
        XCTAssertTrue(PasswordValidator.canSubmitReset(code: "12345", password: "weak", confirmation: "weak"), "Strength is the API's")
        XCTAssertFalse(PasswordValidator.canSubmitReset(code: "1234", password: "Abcdef1!", confirmation: "Abcdef1!"))
        XCTAssertFalse(PasswordValidator.canSubmitReset(code: "123456", password: "Abcdef1!", confirmation: "Abcdef1!"))
        XCTAssertFalse(PasswordValidator.canSubmitReset(code: "12a45", password: "Abcdef1!", confirmation: "Abcdef1!"))
        XCTAssertFalse(PasswordValidator.canSubmitReset(code: "١٢٣٤٥", password: "Abcdef1!", confirmation: "Abcdef1!"))
        XCTAssertFalse(PasswordValidator.canSubmitReset(code: "12345", password: "", confirmation: ""))
        XCTAssertFalse(PasswordValidator.canSubmitReset(code: "12345", password: "   ", confirmation: "   "))
        XCTAssertFalse(PasswordValidator.canSubmitReset(code: "12345", password: "Abcdef1!", confirmation: "Abcdef1?"))
    }

    func testChangePasswordGate() {
        XCTAssertTrue(PasswordValidator.canSubmitChange(current: "old", new: "new", confirmation: "new"), "Strength is the API's")
        XCTAssertFalse(PasswordValidator.canSubmitChange(current: "", new: "new", confirmation: "new"))
        XCTAssertFalse(PasswordValidator.canSubmitChange(current: " ", new: "new", confirmation: "new"))
        XCTAssertFalse(PasswordValidator.canSubmitChange(current: "old", new: " ", confirmation: " "))
        XCTAssertFalse(PasswordValidator.canSubmitChange(current: "old", new: "new", confirmation: "New"))
    }

    func testBlankIsKotlinsIsBlank() {
        for blank in ["", "   ", "\t\n\u{0B}\u{0C}\r", "\u{A0}\u{2007}\u{202F}", "\u{1C}\u{1F}", "\u{2028}\u{2029}", "\u{3000}"] {
            XCTAssertTrue(PasswordValidator.isBlank(blank), blank.debugDescription)
        }
        for notBlank in ["a", " a ", "\u{85}", "\u{FEFF}", "\u{200B}"] {
            XCTAssertFalse(PasswordValidator.isBlank(notBlank), notBlank.debugDescription)
        }
    }

    func testSignUpReportsTheFirstUnmetRuleInAndroidOrder() {
        let problems = SignUpCredentialsValidation.problems(email: "a@b.co", password: "abcdefgh", confirmation: "abcdefgh",
                                                           accepted: true) { slug, _ in "<\(slug)>" }
        XCTAssertEqual(problems[.password], "<signup_credentials_password_validation_1_uppercase>")
    }
}
