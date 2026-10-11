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

        var user: User? {
            switch self {
            case .signedIn(let u): return u
            case .loading, .signedOut: return nil
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
    private let tokens: any SessionTokenStorage
    private var authRevision = 0
    private var passwordHandoff: (id: UUID, revision: Int)?
    @Published private(set) var savedSessionRejected = false
    private var cancellables = Set<AnyCancellable>()

    var role: UserRole? { state.user?.role }

    init(auth: AuthService = AuthService(), tokens: any SessionTokenStorage = TokenStore.shared) {
        self.auth = auth
        self.tokens = tokens
        NotificationCenter.default.publisher(for: .carezaarSessionExpired)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.tokens.hasSession else { return }
                // Only this captured password transaction may defer an old-pair
                // expiry. Explicit logout/new login still changes authRevision.
                if self.passwordHandoff?.revision == self.authRevision { return }
                self.authRevision += 1
                self.savedSessionRejected = true
                self.state = .signedOut
            }
            .store(in: &cancellables)
    }

    /// Splash behaviour: token present ⇒ fetch `auth/info`, else straight to Intro.
    func restore() async {
        let revision = authRevision
        guard tokens.hasSession else {
            if tokens.accessToken != nil || tokens.refreshToken != nil {
                tokens.clear()
                savedSessionRejected = true
            }
            state = .signedOut
            return
        }
        do {
            let user = try await auth.currentUser()
            guard revision == authRevision, tokens.hasSession else { return }
            apply(user)
        } catch {
            guard revision == authRevision else { return }
            // Unverifiable launch credentials never authorize this or a later launch.
            tokens.clear()
            savedSessionRejected = true
            state = .signedOut
        }
    }

    func retry() async { state = .loading; await restore() }

    func signIn(email: String, password: String) async throws {
        authRevision += 1
        let revision = authRevision
        let pair = try await auth.login(email: email, password: password)
        guard revision == authRevision else { throw CancellationError() }
        guard !pair.accessToken.isEmpty, !pair.refreshToken.isEmpty else {
            throw APIError.decoding("Login did not return valid credentials.")
        }
        tokens.save(pair)
        do {
            let user = try await auth.currentUser()
            guard revision == authRevision, tokens.hasSession else { throw CancellationError() }
            apply(user)
        } catch {
            if revision == authRevision { tokens.clear(); state = .signedOut }
            throw error
        }
    }

    /// The change endpoint returns no JWTs and may revoke the old pair. Keep the
    /// settings graph during a narrowly scoped, verified same-account handoff.
    func changePassword(current: String, new: String) async throws {
        guard let original = state.user, tokens.hasSession, passwordHandoff == nil else {
            throw APIError.unauthenticated("")
        }
        let revision = authRevision, operation = UUID()
        passwordHandoff = (operation, revision)
        var acknowledged = false
        defer {
            if passwordHandoff?.id == operation { passwordHandoff = nil }
            if revision == authRevision, !tokens.hasSession {
                savedSessionRejected = true
                authRevision += 1
                state = .signedOut
            }
        }
        func checkOwner() throws {
            guard revision == authRevision, passwordHandoff?.id == operation else { throw CancellationError() }
        }
        func checkIdentity(_ user: User) throws {
            guard user.id == original.id, user.role == original.role,
                  user.email == original.email else {
                throw APIError.unauthenticated("Could not verify the changed-password account.")
            }
        }
        do {
            try await UserService(client: auth.client).changePassword(oldPassword: current, newPassword: new)
            acknowledged = true
            try checkOwner()
            do {
                let verified = try await auth.currentUser()
                try checkOwner()
                try checkIdentity(verified)
                guard tokens.hasSession else { throw APIError.unauthenticated("") }
                apply(verified)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Old credentials may be revoked, or their read unverifiable.
                // Obtain genuine replacement credentials using the accepted input.
                try checkOwner()
            }
            let pair = try await auth.login(email: original.email, password: new)
            try checkOwner()
            guard !pair.accessToken.isEmpty, !pair.refreshToken.isEmpty else {
                throw APIError.decoding("Login did not return valid credentials.")
            }
            let verified = try await auth.client.verifyUser(accessToken: pair.accessToken)
            try checkOwner()
            try checkIdentity(verified)
            // Unverified credentials never enter shared storage or reach pollers.
            tokens.save(pair)
            apply(verified)
        } catch {
            try checkOwner()
            if acknowledged || !tokens.hasSession {
                tokens.clear()
                savedSessionRejected = true
                authRevision += 1
                state = .signedOut
            }
            throw error
        }
    }

    func refreshUser() async {
        guard tokens.hasSession, passwordHandoff == nil else { return }
        let revision = authRevision
        do {
            let user = try await auth.currentUser()
            guard revision == authRevision, tokens.hasSession, passwordHandoff == nil else { return }
            apply(user)
        } catch APIError.unauthenticated {
            guard revision == authRevision, passwordHandoff == nil else { return }
            tokens.clear()
            authRevision += 1
            state = .signedOut
        } catch {
            // A transient profile read failure does not revoke a previously verified
            // session; explicit refusal/failed refresh above does.
        }
    }

    func signOut() async {
        let oldAccess = tokens.accessToken
        authRevision += 1
        tokens.clear()
        state = .signedOut
        await auth.logout(accessToken: oldAccess)
    }

    func endDeletedSession() {
        authRevision += 1
        tokens.clear()
        state = .signedOut
    }

    private func apply(_ user: User) {
        // One signed-in state whatever `status` says: there is no verification step.
        savedSessionRejected = false
        state = .signedIn(user)
    }
}
