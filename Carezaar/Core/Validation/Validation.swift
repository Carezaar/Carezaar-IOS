import Foundation

/// The five password conditions the Android app displays as a live checklist on
/// SignUpCredentials, SetupPassword and ChangePassword.
/// Keys: `*_password_validation_8_letters | _1_lowercase | _1_uppercase | _1_number | _1_special_symbol`
struct PasswordRule: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let isSatisfied: Bool
}

enum PasswordValidator {
    static let minimumLength = 8
    /// The client-defined complete set; other symbols do not satisfy this rule.
    static let specialCharacters = Set("!@#$%^&*()_+[]{}|-;:,.<>?")

    static func rules(for password: String) -> [PasswordRule] {
        [PasswordRule(id: "8_letters", label: "At least 8 characters",
                      isSatisfied: password.count >= minimumLength),
         PasswordRule(id: "1_lowercase", label: "At least 1 lowercase letter",
                      isSatisfied: password.contains { $0.isLowercase }),
         PasswordRule(id: "1_uppercase", label: "At least 1 uppercase letter",
                      isSatisfied: password.contains { $0.isUppercase }),
         PasswordRule(id: "1_number", label: "At least 1 number",
                      isSatisfied: password.contains { $0.isNumber }),
         PasswordRule(id: "1_special_symbol", label: "At least 1 special symbol",
                      isSatisfied: password.contains { specialCharacters.contains($0) })]
    }

    static func isValid(_ password: String) -> Bool {
        rules(for: password).allSatisfy(\.isSatisfied)
    }
}

/// Sign-up credentials (parity review v3, C1): Continue is always active and checks
/// every field at once; each problem is shown under its own field. A password that
/// breaks a rule reports the first unmet rule, by its managed checklist label
/// (`signup_credentials_password_validation_*`), in the checklist's own order.
enum SignUpCredentialsValidation {
    enum Field: Hashable, CaseIterable { case email, password, confirmation, agreement }

    static func problems(email: String, password: String, confirmation: String, accepted: Bool,
                         text: (String, String) -> String) -> [Field: String] {
        var problems: [Field: String] = [:]
        let required = text("general_required", "This field is required.")
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { problems[.email] = required }
        else if FieldValidator.email(trimmed) != nil {
            problems[.email] = text("signup_credentials_email_invalid", "Please enter a valid email address.")
        }
        if password.isEmpty { problems[.password] = required }
        else if let rule = PasswordValidator.rules(for: password).first(where: { !$0.isSatisfied }) {
            problems[.password] = text("signup_credentials_password_validation_\(rule.id)", rule.label)
        }
        if confirmation.isEmpty { problems[.confirmation] = required }
        else if confirmation != password {
            problems[.confirmation] = text("signup_credentials_password_match", "Passwords do not match.")
        }
        if !accepted {
            problems[.agreement] = text("signup_credentials_accept_required", "Please accept the license agreement to continue.")
        }
        return problems
    }
}

enum FieldValidator {
    /// Matches the Android copy: "Password is required" / "Confirm Password is required".
    static func required(_ value: String, field: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(field) is required" : nil
    }

    static func email(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Email is required" }
        // Deliberately permissive; the backend is authoritative and returns 422.
        let pattern = #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#
        return trimmed.range(of: pattern, options: .regularExpression) == nil
            ? "Please enter a valid email address" : nil
    }

    /// "Passwords do not match."
    static func confirmation(_ password: String, _ confirmation: String) -> String? {
        if confirmation.isEmpty { return "Confirm Password is required" }
        return password == confirmation ? nil : "Passwords do not match."
    }

    /// The OTP is 5 digits ("Kindly enter the 5-digit OTP that we sent to your email.").
    static let otpLength = 5

    static func otp(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        return digits.count == otpLength ? nil : "Enter the \(otpLength)-digit code"
    }

    /// Profile photo is mandatory (`signup_profile_completion_photo_validation`).
    static func photo(_ data: Data?) -> String? {
        data == nil ? "A profile photo is required" : nil
    }
}
