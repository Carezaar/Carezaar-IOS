import Foundation

/// `auth/` — mirrors the Android `tj` interface.
struct AuthService: Sendable {
    let client: APIClient

    init(client: APIClient = .shared) { self.client = client }

    /// Login sends device telemetry alongside the credentials, exactly as Android does.
    func login(email: String, password: String) async throws -> Session {
        var fields: [String: FormValue?] = [
            "email": .string(email),
            "password": .string(password)
        ]
        fields.merge(DeviceInfo.loginFields) { current, _ in current }
        let session: Session = try await client.send(
            Endpoint(method: .post, path: "auth/login", body: .form(fields), requiresAuth: false)
        )
        TokenStore.shared.save(session)
        return session
    }

    /// Registration happens before the profile steps and returns the created user. Role,
    /// email and password only: the API no longer takes a country at sign-up (checked live,
    /// 2026-10-09); location is collected later in the role's preferences.
    func register(role: UserRole, email: String, password: String) async throws -> User {
        try await client.send(
            Endpoint(method: .post, path: "auth/register",
                     body: .form([
                        "role": .string(role.rawValue),
                        "email": .string(email),
                        "password": .string(password)
                     ]),
                     requiresAuth: false)
        )
    }

    func currentUser() async throws -> User {
        try await client.send(Endpoint(method: .get, path: "auth/info"))
    }

    /// Clears the local session even when the network call fails, so the user is
    /// never stuck signed in on a dead token.
    func logout() async {
        _ = try? await client.sendIgnoringResult(Endpoint(method: .delete, path: "auth/logout"))
        TokenStore.shared.clear()
    }
}
