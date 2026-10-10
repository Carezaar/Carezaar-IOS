import Foundation
import Combine

/// Drives the same launch decision the Android Splash screen makes: if a token
/// exists, resolve the user and enter the app; otherwise show Intro.
@MainActor
final class SessionManager: ObservableObject {

    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(User)
        /// A stored session could not be checked (offline, server down). The token is
        /// kept and the splash offers a retry instead of silently signing out.
        case unreachable

        var user: User? {
            switch self {
            case .signedIn(let u): return u
            case .loading, .signedOut, .unreachable: return nil
            }
        }
    }

    @Published private(set) var state: State = .loading {
        willSet {
            // Signing in or out swaps the navigation graph; the router must be cleared
            // first so the new stack doesn't inherit the old one's path.
            if (state.user == nil) != (newValue.user == nil), newValue != .loading { willSwitchGraph?() }
        }
    }
    var willSwitchGraph: (() -> Void)?
    @Published var errorMessage: String?

    private let auth: AuthService
    private var cancellables = Set<AnyCancellable>()

    var role: UserRole? { state.user?.role }

    init(auth: AuthService = AuthService()) {
        self.auth = auth
        NotificationCenter.default.publisher(for: .carezaarSessionExpired)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.state = .signedOut }
            .store(in: &cancellables)
    }

    /// Splash behaviour: token present ⇒ fetch `auth/info`, else straight to Intro.
    func restore() async {
        guard TokenStore.shared.hasSession else {
            state = .signedOut
            return
        }
        do {
            let user = try await auth.currentUser()
            apply(user)
        } catch APIError.unauthenticated {
            TokenStore.shared.clear()
            state = .signedOut
        } catch {
            // A transient network failure must not sign the user out.
            if let user = state.user { apply(user) } else { state = .unreachable }
        }
    }

    func retry() async {
        state = .loading
        await restore()
    }

    func signIn(email: String, password: String) async throws {
        _ = try await auth.login(email: email, password: password)
        do {
            apply(try await auth.currentUser())
        } catch {
            // Tokens without a user would leave a half-signed-in app; undo the login.
            TokenStore.shared.clear()
            throw error
        }
    }

    func refreshUser() async {
        guard let user = try? await auth.currentUser() else { return }
        apply(user)
    }

    func signOut() async {
        await auth.logout()
        state = .signedOut
    }

    /// The account no longer exists (deleted): there is no session left to log out of.
    func endDeletedSession() {
        TokenStore.shared.clear()
        state = .signedOut
    }

    private func apply(_ user: User) {
        // One signed-in state whatever `status` says: there is no verification step.
        state = .signedIn(user)
    }
}
