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
}
