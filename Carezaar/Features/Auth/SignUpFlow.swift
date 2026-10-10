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

    func reset() {
        entityCreated = false
        email = ""
        password = ""
        userId = nil
        isPasswordRecovery = false
    }
}
