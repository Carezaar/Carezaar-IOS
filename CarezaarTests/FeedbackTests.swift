import XCTest
@testable import Carezaar

@MainActor
final class FeedbackTests: XCTestCase {
    private var originalTranslation: ((String, String) -> String)?
    override func setUp() {
        super.setUp()
        originalTranslation = Feedback.translate
        // Each test chooses its own managed translator; the host app may restore
        // any previously selected language while loading its scene.
        Feedback.translate = { _, fallback in fallback }
    }
    override func tearDown() {
        if let originalTranslation { Feedback.translate = originalTranslation }
        super.tearDown()
    }

    func testCommonFailuresNeverShowRawImplementationWording() {
        for error in [APIError.unknown("Database lookup failed"), .validation(message: "Internal query failed", fields: [:]), .server("Internal query failed")] {
            XCTAssertEqual(Feedback.message(error), "Something went wrong. Please try again.")
        }
        XCTAssertEqual(Feedback.message(APIError.unauthenticated("Valid JWT token is required!")), "You can't do this right now.")
    }
    func testManagedErrorCategoriesUseActualCMSKeysWithoutObsoleteSuffixes() {
        let original = Feedback.translate
        defer { Feedback.translate = original }
        Feedback.translate = { key, _ in "managed:\(key)" }
        for error in [APIError.network("offline"), .timeout] {
            XCTAssertEqual(Feedback.message(error), "managed:general_network_title")
        }
        XCTAssertEqual(Feedback.message(APIError.unauthenticated("JWT required")), "managed:general_error_forbidden")
        XCTAssertEqual(Feedback.message(APIError.notFound("Missing row")), "managed:general_error_not_found")
        for error in [APIError.server("query failed"), .unknown("raw fault"), .decoding("invalid JSON"),
                      .validation(message: "raw fault", fields: [:])] {
            XCTAssertEqual(Feedback.message(error), "managed:general_error_general")
        }
        XCTAssertEqual(Feedback.unavailable("Change Password"), "managed:general_error_forbidden")
        XCTAssertEqual(APIError.server("Internal query failed").message, "managed:general_error_general")
    }

    func testMissingManagedErrorEntriesKeepCanonicalCategoryFallbacks() {
        let original = Feedback.translate
        defer { Feedback.translate = original }
        let loc = Localization()
        loc.languageId = 3
        Feedback.translate = { loc.t($0, $1) }
        XCTAssertEqual(Feedback.message(APIError.network("offline")), "Cannot communicate with server.")
        XCTAssertEqual(Feedback.message(APIError.timeout), "Cannot communicate with server.")
        XCTAssertEqual(Feedback.message(APIError.notFound("raw fault")), "This item is no longer available.")
        XCTAssertEqual(Feedback.unavailable("Report Issue"), "You can't do this right now.")
    }

    func testManagedErrorLanguageSwitchUsesEverySupportedLanguage() throws {
        let original = Feedback.translate
        defer { Feedback.translate = original }
        let keys = ["general_network_title", "general_error_forbidden", "general_error_not_found", "general_error_general"]
        let rows: [[String: Any]] = keys.enumerated().map { index, key in
            ["id": index + 1, "slug": key, "translations": (1...8).map {
                ["id": index * 8 + $0, "language_id": $0, "name": "language\($0):\(key)"] as [String: Any]
            }]
        }
        let loc = Localization()
        loc.apply(try JSONDecoder().decode([BaseItem].self, from: JSONSerialization.data(withJSONObject: rows)))
        Feedback.translate = { loc.t($0, $1) }
        for language in 1...8 {
            loc.languageId = language
            XCTAssertEqual(Feedback.message(APIError.timeout), "language\(language):general_network_title")
            XCTAssertEqual(Feedback.message(APIError.unauthenticated("raw")), "language\(language):general_error_forbidden")
            XCTAssertEqual(Feedback.message(APIError.notFound("raw")), "language\(language):general_error_not_found")
            XCTAssertEqual(Feedback.message(APIError.server("raw")), "language\(language):general_error_general")
        }
    }

    func testUsefulFieldValidationIsPreservedAndStable() {
        XCTAssertEqual(Feedback.message(APIError.validation(message: "Invalid input", fields: ["email": ["Please enter a valid email."]])), "Please enter a valid email.")
        XCTAssertEqual(Feedback.message(APIError.validation(message: "Invalid input", fields: ["email": ["SQLSTATE internal"]])), "Something went wrong. Please try again.")
    }

    func testRouteReferenceValidationUsesManagedGeneralError() {
        for field in ["id", "partner_id", "chat_id", "match_id", "user_id"] {
            let error = APIError.validation(message: "Invalid reference", fields: [field: ["The selected id is invalid."]])
            XCTAssertEqual(Feedback.message(error), "Something went wrong. Please try again.", field)
        }
    }

    func testUsefulEditableFieldWinsOverUneditableReferenceValidation() {
        let error = APIError.validation(message: "Invalid input", fields: [
            "id": ["The selected id is invalid."], "subject": ["Please enter a subject."]
        ])
        XCTAssertEqual(Feedback.message(error), "Please enter a subject.")
    }

    func testEmptyEarlyValidationMessagesDoNotHideLaterUsefulCorrection() {
        let error = APIError.validation(message: "Invalid input", fields: [
            "email": ["", "  \n"], "password": ["Please enter a stronger password."]
        ])
        XCTAssertEqual(Feedback.message(error), "Please enter a stronger password.")
    }

    func testTechnicalEarlyMessagesDoNotHideFirstSafeCorrectionInStableFieldOrder() {
        let laterField = APIError.validation(message: "Invalid input", fields: [
            "email": ["SQLSTATE internal"], "password": ["Please enter a stronger password."]
        ])
        XCTAssertEqual(Feedback.message(laterField), "Please enter a stronger password.")
        let error = APIError.validation(message: "Invalid input", fields: [
            "subject": ["Please enter a subject."],
            "email": ["SQLSTATE internal", "Please enter a valid email.", "Later email correction."],
            "id": ["The selected id is invalid."]
        ])
        XCTAssertEqual(Feedback.message(error), "Please enter a valid email.",
                       "Ignore unsafe candidates before selecting by sorted editable field and message order")
    }

    func testAllUnsafeOrReferenceValidationMessagesKeepManagedGeneralError() {
        let error = APIError.validation(message: "Internal query failed", fields: [
            "email": ["", "SQLSTATE internal", "  \n"],
            "password": ["Undefined variable in reset.php"],
            "id": ["The selected id is invalid."], "chat_id": ["Unauthorized value."]
        ])
        XCTAssertEqual(Feedback.message(error), "Something went wrong. Please try again.")
    }

    func testOTPInlineNeverAllowsServiceOrTechnicalErrorsToBypassCommonCopy() {
        for error in [APIError.server("SQLSTATE exception reading OTP table"), .server("Invalid OTP"),
                      .notFound("OTP route missing"), .unknown("Undefined variable otp in reset.php"),
                      .validation(message: "Exception processing OTP", fields: ["otp": ["Invalid OTP"]]),
                      .unauthenticated("OTP session expired"), .network("OTP connection dropped")] {
            XCTAssertNil(Feedback.otpInlineMessage(error))
        }
    }
    func testRecognizedInvalidAndExpiredOTPUsesSafeCanonicalCopy() {
        for error in [APIError.unknown("Invalid OTP code!"), .unknown("The OTP code is invalid!"), .validation(message: "OTP is incorrect!", fields: [:]),
                      .validation(message: "Invalid input", fields: ["otp": ["Invalid value"]])] {
            XCTAssertEqual(Feedback.otpInlineMessage(error), "The code is invalid. Check it and try again.")
        }
        XCTAssertEqual(Feedback.otpInlineMessage(APIError.unknown("Your OTP has expired!")),
                       "Your code has expired. Request a new code.")
        XCTAssertNil(Feedback.otpInlineMessage(APIError.unknown("OTP processing failed unexpectedly")))
        XCTAssertNil(Feedback.otpInlineMessage(APIError.unknown("Internal OTP lookup invalid database state")))
    }
}
