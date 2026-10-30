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
    /// Android's special set on sign-up and Set Up Password (`.*[!@#$%^&*()_+\[\]{}|\-;:,.<>?].*`);
    /// other symbols do not satisfy this rule.
    static let specialCharacters = "!@#$%^&*()_+[]{}|-;:,.<>?"

    /// Android tests each rule with Java's `Pattern.matches(".*[class].*")`. Java's `.` stops at
    /// line terminators, so a password containing one fails every character rule there.
    private static let javaLineTerminators: Set<UInt16> = [0x0A, 0x0D, 0x85, 0x2028, 0x2029]

    /// Whether some UTF-16 unit of the password passes `test`, the way Android's pattern does.
    private static func javaContains(_ password: String, _ test: (UInt16) -> Bool) -> Bool {
        let units = Array(password.utf16)
        if units.contains(where: javaLineTerminators.contains) { return false }
        return units.contains(where: test)
    }

    /// In Android's order (its checklist and its error toasts): length, uppercase, lowercase,
    /// number, special. Length counts UTF-16 units (Kotlin `String.length`); letters and digits
    /// are ASCII only, as in Android's `[A-Z]`, `[a-z]` and `[0-9]`.
    static func rules(for password: String, special: String = specialCharacters) -> [PasswordRule] {
        let specialUnits = Set(special.utf16)
        return [PasswordRule(id: "8_letters", label: "At least 8 characters",
                             isSatisfied: password.utf16.count >= minimumLength),
                PasswordRule(id: "1_uppercase", label: "At least 1 uppercase letter",
                             isSatisfied: javaContains(password) { (0x41...0x5A).contains($0) }),
                PasswordRule(id: "1_lowercase", label: "At least 1 lowercase letter",
                             isSatisfied: javaContains(password) { (0x61...0x7A).contains($0) }),
                PasswordRule(id: "1_number", label: "At least 1 number",
                             isSatisfied: javaContains(password) { (0x30...0x39).contains($0) }),
                PasswordRule(id: "1_special_symbol", label: "At least 1 special symbol",
                             isSatisfied: javaContains(password) { specialUnits.contains($0) })]
    }

    /// The first rule the password doesn't meet, in Android's order, or nil.
    static func firstUnmetRule(_ password: String) -> PasswordRule? {
        rules(for: password).first { !$0.isSatisfied }
    }

    static func isValid(_ password: String) -> Bool {
        rules(for: password).allSatisfy(\.isSatisfied)
    }

    /// Kotlin's `isBlank`: empty, or only characters Kotlin's `Char.isWhitespace` accepts — Java
    /// `isWhitespace` or `isSpaceChar`: space, line and paragraph separators (Zs, Zl, Zp, no-break
    /// spaces included), tab, line feed, vertical tab, form feed, carriage return and U+001C-U+001F.
    static func isBlank(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
            default: return (0x09...0x0D).contains(scalar.value) || (0x1C...0x1F).contains(scalar.value)
            }
        }
    }

    /// Set Up Password (reset) can be submitted, as on Android: a five-digit code and two
    /// nonblank, identical passwords. Password strength is the API's to judge.
    static func canSubmitReset(code: String, password: String, confirmation: String) -> Bool {
        FieldValidator.isFiveDigitCode(code) && !isBlank(password) && !isBlank(confirmation) && password == confirmation
    }

    /// Change Password's confirmation, as on Android: all three fields nonblank and the new
    /// passwords identical. Password strength is the API's to judge.
    static func canSubmitChange(current: String, new: String, confirmation: String) -> Bool {
        !isBlank(current) && !isBlank(new) && !isBlank(confirmation) && new == confirmation
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
        else if let rule = PasswordValidator.firstUnmetRule(password) {
            problems[.password] = text("signup_credentials_password_validation_\(rule.id)", rule.label)
        }
        if confirmation.isEmpty { problems[.confirmation] = required }
        else if confirmation != password {
            problems[.confirmation] = text("signup_credentials_password_match", "Passwords do not match.")
        }
        if problems.isEmpty && !accepted {
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

    /// Exactly five ASCII digits.
    static func isFiveDigitCode(_ code: String) -> Bool {
        code.utf16.count == otpLength && code.utf16.allSatisfy { (0x30...0x39).contains($0) }
    }

    static func otp(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        return digits.count == otpLength ? nil : "Enter the \(otpLength)-digit code"
    }

    /// Profile photo is mandatory (`signup_profile_completion_photo_validation`).
    static func photo(_ data: Data?) -> String? {
        data == nil ? "A profile photo is required" : nil
    }
}
