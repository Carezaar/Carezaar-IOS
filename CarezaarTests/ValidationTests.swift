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
                                  .confirmation: "<general_required>", .agreement: "<signup_credentials_accept_required>"])
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

    func testSignUpValidFormHasNoProblems() {
        XCTAssertTrue(SignUpCredentialsValidation.problems(email: " a@b.co ", password: "Abcdefg1!", confirmation: "Abcdefg1!",
                                                           accepted: true, text: text).isEmpty)
    }

}
