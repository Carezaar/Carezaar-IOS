import SwiftUI

/// Carries the in-progress signup across steps.
///
/// The Android client holds the same values in memory between `SignUpCredentials` and
/// the post-OTP sign-in (`App.l` email, `App.p` password; Android's `App.k` country is
/// no longer collected at sign-up). Nothing here is persisted — a killed app restarts signup.
@MainActor
final class SignUpFlow: ObservableObject {
    @Published var role: UserRole = .client
    @Published var email: String = ""
    @Published var password: String = ""
    /// Returned by the anonymous `users/profile` step; keys the role entity.
    @Published var userId: String?

    /// Set when the user is recovering a password rather than registering, so the
    /// shared OTP screen knows where to go next.
    @Published var isPasswordRecovery = false

    /// The client/caregiver entity exists; retrying after a failed final sign-in
    /// must not try to create it again.
    @Published var entityCreated = false

    /// The account was created but its first email code could not be sent (C4):
    /// the code screen opens anyway and offers Re-send straight away.
    @Published var otpSendFailed = false

    /// Sign-in found an account whose sign-up was never finished (B1). The profile
    /// step is keyed by email (anonymous `users/profile` accepts it again), returns
    /// the user id for the role entity, and the final sign-in uses this password.
    func resume(role: UserRole, email: String, password: String) {
        reset()
        self.role = role
        self.email = email
        self.password = password
    }

    func reset() {
        entityCreated = false
        otpSendFailed = false
        email = ""
        password = ""
        userId = nil
        isPasswordRecovery = false
    }
}
