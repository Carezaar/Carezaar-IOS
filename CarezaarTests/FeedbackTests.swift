import XCTest
@testable import Carezaar

@MainActor
final class FeedbackTests: XCTestCase {
    func testCommonFailuresNeverShowRawImplementationWording() {
        for error in [APIError.unknown("Database lookup failed"), .validation(message: "Internal query failed", fields: [:]), .server("Internal query failed"), .notFound("No row in database")] {
            XCTAssertEqual(Feedback.message(error), "This isn't working right now. Please try again later.")
        }
        XCTAssertEqual(Feedback.message(APIError.unauthenticated("Valid JWT token is required!")), "Your session has expired. Please sign in again.")
    }
    func testUsefulFieldValidationIsPreservedAndStable() {
        XCTAssertEqual(Feedback.message(APIError.validation(message: "Invalid input", fields: ["email": ["Please enter a valid email."]])), "Please enter a valid email.")
        XCTAssertEqual(Feedback.message(APIError.validation(message: "Invalid input", fields: ["email": ["SQLSTATE internal"]])), "This isn't working right now. Please try again later.")
    }

    func testRouteReferenceValidationUsesManagedGeneralError() {
        for field in ["id", "partner_id", "chat_id", "match_id", "user_id"] {
            let error = APIError.validation(message: "Invalid reference", fields: [field: ["The selected id is invalid."]])
            XCTAssertEqual(Feedback.message(error), "This isn't working right now. Please try again later.", field)
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
        XCTAssertEqual(Feedback.message(error), "This isn't working right now. Please try again later.")
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
