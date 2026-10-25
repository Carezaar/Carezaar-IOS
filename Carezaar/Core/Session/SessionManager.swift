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
            // Signing out (or a sign-in ending) forgets the My Matches sort and list (23 Oct 2026).
            if newValue == .signedOut { MatchesStore.shared.forget() }
            // Action guards and unfinished submissions belong to the signed-in account (25 Oct 2026).
            ActionGuard.shared.account = newValue.user?.id ?? "signed-out"
            IdempotencyStore.shared.account = newValue.user?.id
        }
    }
    var willSwitchGraph: (() -> Void)?
    @Published var errorMessage: String?

    private let auth: AuthService
    private let tokens: any SessionTokenStorage
    private var deleting = false
    private var pendingDeletion: (revision: Int, generation: UUID, error: Error)?
    private var restoring = false
    private var authRevision = 0
    private var passwordHandoff: (id: UUID, revision: Int)?
    // Memory only: retain the original candidate while its write is uncertain.
    // Later confirmations probe this outcome instead of sending another PATCH.
    private var pendingPassword: (revision: Int, generation: UUID, user: User, candidate: String, error: Error)?
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
        guard !restoring else { return }
        restoring = true
        defer { restoring = false }
        errorMessage = nil
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
            // A temporary failure does not establish that the saved sign-in is
            // invalid. Keep credentials behind the startup gate until Retry can
            // verify them; only explicit authentication rejection ends a session.
            if case APIError.unauthenticated = error {
                tokens.clear()
                savedSessionRejected = true
                state = .signedOut
            } else if !(error is CancellationError) {
                errorMessage = Feedback.message(error)
            }
        }
    }

    func retry() async { state = .loading; await restore() }

    func signIn(email: String, password: String) async throws {
        pendingPassword = nil
        authRevision += 1
        let revision = authRevision
        let pair = try await auth.login(email: email, password: password)
        guard revision == authRevision else { throw CancellationError() }
        guard !pair.accessToken.isEmpty, !pair.refreshToken.isEmpty else {
            throw APIError.decoding("Login did not return valid credentials.")
        }
        tokens.save(pair)
        // Keychain writes can fail or leave an older pair behind. Identity
        // verification must use the exact credentials returned by this login.
        guard tokens.accessToken == pair.accessToken,
              tokens.refreshToken == pair.refreshToken else {
            tokens.clear()
            state = .signedOut
            throw APIError.unknown("Login credentials could not be stored.")
        }
        do {
            let user = try await auth.currentUser()
            guard revision == authRevision, tokens.hasSession else { throw CancellationError() }
            apply(user)
        } catch {
            if revision == authRevision { tokens.clear(); state = .signedOut }
            throw error
        }
    }

    /// A confirmed password change ends the current session. The next sign-in
    /// belongs to the user; no background login or replacement pair is installed.
    func changePassword(current: String, new: String) async throws {
        guard let original = state.user, tokens.hasSession, passwordHandoff == nil else {
            throw APIError.unauthenticated("")
        }
        let revision = authRevision, generation = tokens.generation, operation = UUID()
        passwordHandoff = (operation, revision)
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
        func reconcile(user: User, candidate: String, originalError: Error) async throws {
            let pair: Session
            do {
                pair = try await auth.login(email: user.email, password: candidate)
                try checkOwner()
                guard !pair.accessToken.isEmpty, !pair.refreshToken.isEmpty else { throw APIError.decoding("") }
                let verified = try await auth.client.verifyUser(accessToken: pair.accessToken)
                try checkOwner()
                guard verified.id == user.id, verified.role == user.role,
                      verified.email == user.email else { throw APIError.unauthenticated("") }
            } catch {
                try checkOwner()
                throw originalError
            }
            await auth.logout(accessToken: pair.accessToken)
            try checkOwner()
        }
        if let pending = pendingPassword, pending.revision == revision, pending.generation == generation {
            try await reconcile(user: pending.user, candidate: pending.candidate, originalError: pending.error)
        } else {
            pendingPassword = nil
            do {
                try await UserService(client: auth.client).changePassword(oldPassword: current, newPassword: new, ifGeneration: generation)
            } catch {
                try checkOwner()
                guard MutationOutcome.mayHaveCommitted(error) else { throw error }
                pendingPassword = (revision, generation, original, new, error)
                // Isolated authentication proves acceptance; it never installs
                // credentials or turns into an automatic background sign-in.
                try await reconcile(user: original, candidate: new, originalError: error)
            }
        }
        try checkOwner()
        await signOut()
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
        pendingPassword = nil
        let oldAccess = tokens.accessToken
        authRevision += 1
        tokens.clear()
        state = .signedOut
        await auth.logout(accessToken: oldAccess)
    }

    /// The session owning a deletion request is the only session it may end.
    /// Once the write is uncertain, later taps can verify only, never repeat DELETE.
    func deleteAccount(reasonId: Int) async throws {
        guard state.user != nil, tokens.hasSession else { throw APIError.unauthenticated("") }
        guard !deleting else { throw APIError.unknown("") }
        deleting = true
        defer { deleting = false }
        let revision = authRevision, generation = tokens.generation
        func checkOwner() throws {
            guard revision == authRevision, generation == tokens.generation else { throw CancellationError() }
        }
        func endRejectedOwner() throws {
            guard !tokens.hasSession else { throw CancellationError() }
            if revision == authRevision {
                endDeletedSession()
            } else if !(authRevision == revision + 1 && state == .signedOut && savedSessionRejected) {
                throw CancellationError()
            }
        }
        func reconcile(_ originalError: Error) async throws {
            do {
                _ = try await auth.currentUser(ifGeneration: generation)
            } catch APIError.unauthenticated {
                try endRejectedOwner()
                return
            } catch {
                try checkOwner()
                throw originalError
            }
            try checkOwner()
            throw originalError
        }
        if let pendingDeletion, pendingDeletion.revision == revision, pendingDeletion.generation == generation {
            try await reconcile(pendingDeletion.error)
            return
        }
        do {
            try await UserService(client: auth.client).deleteAccount(reasonId: reasonId, ifGeneration: generation)
        } catch APIError.unauthenticated {
            try endRejectedOwner()
            return
        } catch is CancellationError { throw CancellationError() }
        catch {
            try checkOwner()
            guard MutationOutcome.mayHaveCommitted(error) else { throw error }
            pendingDeletion = (revision, generation, error)
            try await reconcile(error)
            return
        }
        try checkOwner()
        endDeletedSession()
    }

    func endDeletedSession() {
        pendingDeletion = nil
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

/// One "Connection Problem" window for the current sign-in, shown when renewing the
/// session could not reach the server. The root controls eligibility so startup
/// uses its own Try Again gate.
///
/// Parity review v3, Q2: requests that failed while the window is open have already
/// reported their own error and are never resumed or repeated. Retry renews the
/// session only: success closes the window, an unreachable server keeps it, and an
/// HTTP error answer ends the session (Q1).
@MainActor
final class SessionRecoveryCoordinator: ObservableObject {
    static let shared = SessionRecoveryCoordinator()
    @Published private(set) var isPresented = false
    @Published private(set) var isRetrying = false
    private let tokens: any SessionTokenStorage
    private let renew: (UUID) async -> APIClient.RenewalRetryOutcome
    private var enabled = false
    private var generation: UUID?

    init(tokens: any SessionTokenStorage = TokenStore.shared,
         renew: ((UUID) async -> APIClient.RenewalRetryOutcome)? = nil) {
        self.tokens = tokens
        self.renew = renew ?? { await APIClient.shared.retryRenewal(generation: $0) }
    }

    func configure(signedIn: Bool) {
        enabled = signedIn
        if !signedIn || !tokens.hasSession || generation != tokens.generation { dismiss() }
    }

    /// Called by the API client after a renewal could not reach the server.
    func present(generation: UUID) {
        guard enabled, tokens.hasSession, tokens.generation == generation else { return }
        self.generation = generation
        if !isPresented { isPresented = true }
    }

    func retry() async {
        // The alert closes on any tap; it reopens only if the server is still unreachable.
        if isPresented { isPresented = false }
        guard let generation, !isRetrying else { return }
        isRetrying = true
        let outcome = await renew(generation)
        isRetrying = false
        guard self.generation == generation else { return }
        if outcome == .unreachable, enabled, tokens.hasSession, tokens.generation == generation {
            isPresented = true
        } else {
            dismiss()
        }
    }

    private func dismiss() {
        generation = nil
        if isPresented { isPresented = false }
    }
}
