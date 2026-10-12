import XCTest
@testable import Carezaar

@MainActor
final class SessionTests: XCTestCase {
    func testLoginStorageFailureCannotVerifyMissingPartialOrPreviousCredentials() async {
        for failure in LoginStorageFailureTokens.Failure.allCases {
            let tokens = LoginStorageFailureTokens(failure: failure)
            var identityRequests = 0
            StubHTTP.handler = { request in
                if request.url!.lastPathComponent == "login" {
                    return (200, Data(#"{"result":{"access_token":"new-access","refresh_token":"new-refresh"}}"#.utf8))
                }
                if request.url!.lastPathComponent == "info" {
                    identityRequests += 1
                    if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access" {
                        return (200, Data(#"{"result":{"id":"previous-user","role":"caregiver"}}"#.utf8))
                    }
                    if request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access" {
                        return (200, Data(#"{"result":{"id":"new-user","role":"client"}}"#.utf8))
                    }
                }
                return (403, Data(#"{"message":"Fixture authentication refused"}"#.utf8))
            }
            let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
            do {
                try await manager.signIn(email: "new@example.invalid", password: "Fixture-password1!")
                XCTFail("Failed credential persistence must not complete a login")
            } catch let error as APIError {
                if case .unknown = error {} else { XCTFail("Local persistence failure must not be reported as backend authentication rejection") }
            } catch { XCTFail("Local persistence failure must have a managed API error") }
            XCTAssertEqual(identityRequests, 0, "Do not verify login using absent, partial or previous stored credentials")
            XCTAssertEqual(manager.state, .signedOut)
            XCTAssertNil(tokens.accessToken)
            XCTAssertNil(tokens.refreshToken)
        }
    }

    func testAcknowledgedPasswordChangeReauthenticatesRevokedPairWithoutChangingGraph() async throws {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        var changed = false, logins = 0, switches = 0
        StubHTTP.handler = { request in
            switch request.url!.lastPathComponent {
            case "change": changed = true; return (204, Data())
            case "login":
                logins += 1
                let fields = URLComponents(string: "https://fixture.invalid/?" + StubHTTP.body(request))!.queryItems!
                XCTAssertEqual(fields.first { $0.name == "email" }?.value, "fixture@example.invalid")
                XCTAssertEqual(fields.first { $0.name == "password" }?.value, "Accepted-new-password1!")
                return (200, Self.passwordPair)
            case "refresh": return (403, Data(#"{"message":"Revoked"}"#.utf8))
            default:
                if changed && request.value(forHTTPHeaderField: "Authorization") != "Bearer replacement-access" {
                    return (403, Data(#"{"message":"Revoked"}"#.utf8))
                }
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-access" {
                    XCTAssertNil(tokens.accessToken, "Candidate pair must stay out of shared storage until identity is verified")
                }
                return (200, Self.passwordUser)
            }
        }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        manager.willSwitchGraph = { switches += 1 }
        try await manager.changePassword(current: "Old-password1!", new: "Accepted-new-password1!")
        XCTAssertEqual(manager.state.user?.id, "fixture-user")
        XCTAssertEqual(tokens.accessToken, "replacement-access")
        XCTAssertEqual(logins, 1)
        XCTAssertEqual(switches, 0, "Verified replacement must preserve the current settings graph")
        StubHTTP.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer replacement-access")
            return (200, Self.passwordUser)
        }
        await manager.restore()
        XCTAssertEqual(manager.state.user?.id, "fixture-user", "Replacement pair must restore through auth/info")
    }

    func testPasswordHandoffRejectsLoginRefusalAndWrongIdentity() async {
        let wrongUsers: [Data?] = [nil,
            Data(#"{"result":{"id":"another-user","role":"client","email":"fixture@example.invalid"}}"#.utf8),
            Data(#"{"result":{"id":"fixture-user","role":"caregiver","email":"fixture@example.invalid"}}"#.utf8),
            Data(#"{"result":{"id":"fixture-user","role":"client","email":"another@example.invalid"}}"#.utf8)]
        for wrongUser in wrongUsers {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
            var changed = false, logins = 0
            StubHTTP.handler = { request in
                switch request.url!.lastPathComponent {
                case "change": changed = true; return (204, Data())
                case "login":
                    logins += 1
                    return wrongUser != nil ? (200, Self.passwordPair) : (400, Data(#"{"message":"Invalid Credentials!"}"#.utf8))
                case "refresh": return (403, Data(#"{"message":"Revoked"}"#.utf8))
                default:
                    if changed {
                        if request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-access" {
                            XCTAssertNil(tokens.accessToken, "Wrong-identity candidate must never be installed")
                            return (200, wrongUser!)
                        }
                        return (403, Data(#"{"message":"Revoked"}"#.utf8))
                    }
                    return (200, Self.passwordUser)
                }
            }
            let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
            await manager.restore()
            do {
                try await manager.changePassword(current: "Old-password1!", new: "Accepted-new-password1!")
                XCTFail("A refused or unrelated replacement cannot be reported as a retained session")
            } catch { }
            XCTAssertEqual(logins, 1)
            XCTAssertEqual(manager.state, .signedOut)
            XCTAssertFalse(tokens.hasSession)
        }
    }

    func testLogoutOrNewAccountWinsLateAcknowledgedPasswordChange() async {
        for newAccount in [false, true] {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
            let started = expectation(description: "password change pending")
            let release = DispatchSemaphore(value: 0)
            var replacementLogins = 0
            StubHTTP.handler = { request in
                if request.url!.lastPathComponent == "change" {
                    started.fulfill(); _ = release.wait(timeout: .now() + 5)
                    return (204, Data())
                }
                if request.url!.lastPathComponent == "login" {
                    let body = StubHTTP.body(request)
                    if body.contains("Accepted-new-password") { replacementLogins += 1; return (200, Self.passwordPair) }
                    return (200, Data(#"{"result":{"access_token":"unrelated-access","refresh_token":"unrelated-refresh"}}"#.utf8))
                }
                if request.url!.lastPathComponent == "logout" { return (204, Data()) }
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer unrelated-access" {
                    return (200, Data(#"{"result":{"id":"another-user","role":"caregiver","email":"another@example.invalid"}}"#.utf8))
                }
                return (200, Self.passwordUser)
            }
            let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
            await manager.restore()
            let operation = Task { try? await manager.changePassword(current: "Old-password1!", new: "Accepted-new-password1!") }
            await fulfillment(of: [started], timeout: 2)
            if newAccount { try? await manager.signIn(email: "another@example.invalid", password: "Other-password1!") }
            else { await manager.signOut() }
            release.signal()
            await operation.value
            XCTAssertEqual(replacementLogins, 0, "Late acknowledgement must not reauthenticate a superseded account")
            XCTAssertEqual(manager.state.user?.id, newAccount ? "another-user" : nil)
            XCTAssertEqual(tokens.accessToken, newAccount ? "unrelated-access" : nil)
        }
    }

    func testPasswordHandoffDefersOldSessionExpiryUntilReplacementIsVerified() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        let loginPending = expectation(description: "replacement login pending")
        let release = DispatchSemaphore(value: 0)
        var changed = false, switches = 0
        StubHTTP.handler = { request in
            switch request.url!.lastPathComponent {
            case "change": changed = true; return (204, Data())
            case "login":
                // A previously captured old-token poll completes during handoff.
                // Model its real expiry effect rather than inventing valid old auth.
                tokens.clear()
                NotificationCenter.default.post(name: .carezaarSessionExpired, object: nil)
                loginPending.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return (200, Self.passwordPair)
            case "refresh": return (403, Data(#"{"message":"Revoked"}"#.utf8))
            default:
                if changed && request.value(forHTTPHeaderField: "Authorization") != "Bearer replacement-access" {
                    return (403, Data(#"{"message":"Revoked"}"#.utf8))
                }
                return (200, Self.passwordUser)
            }
        }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        manager.willSwitchGraph = { switches += 1 }
        let operation = Task { try? await manager.changePassword(current: "Old-password1!", new: "Accepted-new-password1!") }
        await fulfillment(of: [loginPending], timeout: 2)
        let notificationDelivered = expectation(description: "main queue expiry delivered")
        DispatchQueue.main.async { notificationDelivered.fulfill() }
        await fulfillment(of: [notificationDelivered], timeout: 1)
        XCTAssertEqual(manager.state.user?.id, "fixture-user", "Pending password handoff must not briefly navigate to Welcome")
        XCTAssertEqual(switches, 0)
        release.signal()
        await operation.value
        XCTAssertEqual(manager.state.user?.id, "fixture-user")
        XCTAssertEqual(tokens.accessToken, "replacement-access")
        XCTAssertEqual(switches, 0)
    }

    func testPasswordChangeKeepsVerifiedOldPairWithoutExtraLogin() async throws {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        let generation = tokens.generation
        var patches = 0, logins = 0, switches = 0
        StubHTTP.handler = { request in
            switch request.url!.lastPathComponent {
            case "change": patches += 1; return (204, Data())
            case "login": logins += 1; return (200, Self.passwordPair)
            default:
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
                return (200, Self.passwordUser)
            }
        }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        manager.willSwitchGraph = { switches += 1 }
        try await manager.changePassword(current: "Old-password1!", new: "Accepted-new-password1!")
        XCTAssertEqual(patches, 1)
        XCTAssertEqual(logins, 0, "A still-valid pair needs no replacement login")
        XCTAssertEqual(tokens.accessToken, "old-access")
        XCTAssertEqual(tokens.refreshToken, "old-refresh")
        XCTAssertEqual(tokens.generation, generation)
        XCTAssertEqual(manager.state.user?.id, "fixture-user")
        XCTAssertEqual(switches, 0)
    }

    func testPasswordHandoffNeverInstallsMalformedCandidate() async {
        let malformedPairs = [
            Data(#"{"result":{"access_token":"","refresh_token":"replacement-refresh"}}"#.utf8),
            Data(#"{"result":{"access_token":"replacement-access","refresh_token":""}}"#.utf8),
            Data(#"{"result":{"access_token":"replacement-access"}}"#.utf8),
            Data("not an envelope".utf8)]
        for candidate in malformedPairs {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
            var changed = false, candidateReads = 0, logins = 0
            StubHTTP.handler = { request in
                switch request.url!.lastPathComponent {
                case "change": changed = true; return (204, Data())
                case "login": logins += 1; XCTAssertNil(tokens.accessToken); return (200, candidate)
                case "refresh": return (403, Data(#"{"message":"Revoked"}"#.utf8))
                default:
                    if request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-access" { candidateReads += 1 }
                    return changed ? (403, Data(#"{"message":"Revoked"}"#.utf8)) : (200, Self.passwordUser)
                }
            }
            let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
            await manager.restore()
            do {
                try await manager.changePassword(current: "Old-password1!", new: "Accepted-new-password1!")
                XCTFail("Malformed candidate cannot complete a password handoff")
            } catch { }
            XCTAssertEqual(logins, 1)
            XCTAssertEqual(candidateReads, 0, "Unusable pair must be rejected before verification transport")
            XCTAssertNil(tokens.accessToken)
            XCTAssertNil(tokens.refreshToken)
            XCTAssertEqual(manager.state, .signedOut)
        }
    }

    func testPasswordHandoffNeverInstallsUnverifiableCandidate() async {
        for timeout in [false, true] {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
            var changed = false, candidateReads = 0, logins = 0
            StubHTTP.handler = { request in
                switch request.url!.lastPathComponent {
                case "change": changed = true; return (204, Data())
                case "login": logins += 1; return (200, Self.passwordPair)
                case "refresh": return (403, Data(#"{"message":"Revoked"}"#.utf8))
                default:
                    if request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-access" {
                        candidateReads += 1
                        XCTAssertFalse(tokens.hasSession, "Candidate must remain outside shared credentials throughout verification")
                        if timeout { throw URLError(.timedOut) }
                        return (200, Data("malformed candidate identity".utf8))
                    }
                    return changed ? (403, Data(#"{"message":"Revoked"}"#.utf8)) : (200, Self.passwordUser)
                }
            }
            let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
            await manager.restore()
            do {
                try await manager.changePassword(current: "Old-password1!", new: "Accepted-new-password1!")
                XCTFail("Unverifiable candidate cannot complete a password handoff")
            } catch { }
            XCTAssertEqual(logins, 1)
            XCTAssertGreaterThanOrEqual(candidateReads, 1)
            XCTAssertNil(tokens.accessToken)
            XCTAssertNil(tokens.refreshToken)
            XCTAssertEqual(manager.state, .signedOut)
        }
    }

    func testLogoutOrNewAccountWinsDuringCandidateIdentityVerification() async {
        for newAccount in [false, true] {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
            let verifying = expectation(description: "candidate auth info pending")
            let gate = PasswordCandidateResponseGate()
            var changed = false
            PasswordCandidateHTTP.handler = { request, transport in
                switch request.url!.lastPathComponent {
                case "change": changed = true; transport.respond(204, Data())
                case "login":
                    let form = StubHTTP.body(request)
                    transport.respond(200, form.contains("Accepted-new-password") ? Self.passwordPair
                        : Data(#"{"result":{"access_token":"unrelated-access","refresh_token":"unrelated-refresh"}}"#.utf8))
                case "refresh": transport.respond(403, Data(#"{"message":"Revoked"}"#.utf8))
                case "logout": transport.respond(204, Data())
                default:
                    switch request.value(forHTTPHeaderField: "Authorization") {
                    case "Bearer replacement-access":
                        XCTAssertFalse(tokens.hasSession, "Candidate cannot be installed before verification completes")
                        gate.hold(transport)
                        verifying.fulfill()
                    case "Bearer unrelated-access":
                        transport.respond(200, Data(#"{"result":{"id":"another-user","role":"caregiver","email":"another@example.invalid"}}"#.utf8))
                    default:
                        transport.respond(changed ? 403 : 200, changed ? Data(#"{"message":"Revoked"}"#.utf8) : Self.passwordUser)
                    }
                }
            }
            let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: PasswordCandidateHTTP.session())), tokens: tokens)
            await manager.restore()
            let operation = Task { try? await manager.changePassword(current: "Old-password1!", new: "Accepted-new-password1!") }
            await fulfillment(of: [verifying], timeout: 3)
            if newAccount { try? await manager.signIn(email: "another@example.invalid", password: "Other-password1!") }
            else { await manager.signOut() }
            XCTAssertEqual(manager.state.user?.id, newAccount ? "another-user" : nil,
                           "Explicit user action must finish before the old candidate response is released")
            gate.release(Self.passwordUser)
            await operation.value
            XCTAssertEqual(manager.state.user?.id, newAccount ? "another-user" : nil)
            XCTAssertEqual(tokens.accessToken, newAccount ? "unrelated-access" : nil)
            XCTAssertEqual(tokens.refreshToken, newAccount ? "unrelated-refresh" : nil)
        }
    }

    nonisolated private static var passwordUser: Data {
        Data(#"{"result":{"id":"fixture-user","role":"client","email":"fixture@example.invalid"}}"#.utf8)
    }
    nonisolated private static var passwordPair: Data {
        Data(#"{"result":{"access_token":"replacement-access","refresh_token":"replacement-refresh"}}"#.utf8)
    }

    func testOldMutationCannotBorrowNewLoginDuringBearerCapture() async {
        let tokens = BearerSwapTokens(swapOnRead: 1)
        var writes = 0
        StubHTTP.handler = { request in
            writes += 1
            XCTAssertNotEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unrelated-login",
                              "An old operation must never run as the new account")
            return (204, Data())
        }
        _ = try? await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(
            Endpoint(method: .post, path: "clients/matches/fixture/accept"))
        XCTAssertEqual(writes, 0, "A generation change while capturing bearer must stop before transport")
        XCTAssertEqual(tokens.currentAccess, "unrelated-login")
    }

    func testOldRefreshCannotBorrowNewLoginDuringRefreshBearerCapture() async {
        let tokens = BearerSwapTokens(swapOnRead: 99, swapOnRefreshRead: true)
        var refreshes = 0
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" {
                refreshes += 1
                XCTAssertNotEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unrelated-refresh")
                return (200, Data(#"{"result":{"access_token":"late","refresh_token":"late-refresh"}}"#.utf8))
            }
            return (403, Data(#"{"message":"Expired"}"#.utf8))
        }
        _ = try? await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(
            Endpoint(method: .get, path: "auth/info"))
        XCTAssertEqual(refreshes, 0, "An old refresh task must stop before using another login's credential")
        XCTAssertEqual(tokens.currentAccess, "unrelated-login")
    }

    func testRequestBuildDoesNotRecaptureAnotherAccountsBearer() async {
        let tokens = BearerSwapTokens(swapOnRead: 2)
        var writes = 0
        StubHTTP.handler = { request in
            writes += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
            return (204, Data())
        }
        _ = try? await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(
            Endpoint(method: .post, path: "clients/matches/fixture/accept"))
        XCTAssertEqual(tokens.accessReads, 1, "Build uses the captured bearer, never a second live token read")
        XCTAssertEqual(writes, 1)
    }

    func testRejectedReplayAfterSuccessfulRefreshExpiresCapturedSession() async {
        for status in [401, 403] {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
            var reads = 0, refreshes = 0
            StubHTTP.handler = { request in
                if request.url!.lastPathComponent == "refresh" {
                    refreshes += 1
                    return (200, Data(#"{"result":{"access_token":"renewed-access","refresh_token":"renewed-refresh"}}"#.utf8))
                }
                reads += 1
                if reads == 2 { XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed-access") }
                return (status, Data(#"{"message":"Refused"}"#.utf8))
            }
            _ = try? await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(
                Endpoint(method: .get, path: "users/notifications/count"))
            XCTAssertEqual(reads, 2, "Retry once after renewal, never loop on refusal")
            XCTAssertEqual(refreshes, 1)
            XCTAssertFalse(tokens.hasSession, "A rejected renewed credential cannot remain signed in")
        }
    }

    func testRejectedReplayUsingConcurrentRenewalExpiresCapturedSession() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        let generation = tokens.generation
        var reads = 0
        StubHTTP.handler = { request in
            XCTAssertNotEqual(request.url!.lastPathComponent, "refresh", "Reuse the already-renewed pair")
            reads += 1
            if reads == 1 {
                // Another response renewed this generation while the rejected read
                // was in flight. Deterministically exercise that concurrent branch.
                XCTAssertTrue(tokens.replace(Session(accessToken: "renewed-access", refreshToken: "renewed-refresh"),
                                             ifGeneration: generation, refreshToken: "old-refresh"))
            } else {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed-access")
            }
            return (403, Data(#"{"message":"Refused"}"#.utf8))
        }
        _ = try? await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(
            Endpoint(method: .get, path: "users/notifications/count"))
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(tokens.hasSession)
    }

    func testRejectedReplayNeverExpiresUnrelatedNewLogin() async {
        for alreadyRenewed in [false, true] {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
            let generation = tokens.generation
            var reads = 0
            StubHTTP.handler = { request in
                if request.url!.lastPathComponent == "refresh" {
                    return (200, Data(#"{"result":{"access_token":"renewed-access","refresh_token":"renewed-refresh"}}"#.utf8))
                }
                reads += 1
                if reads == 1 && alreadyRenewed {
                    XCTAssertTrue(tokens.replace(Session(accessToken: "renewed-access", refreshToken: "renewed-refresh"),
                                                 ifGeneration: generation, refreshToken: "old-refresh"))
                }
                if reads == 2 {
                    tokens.save(Session(accessToken: "unrelated-login", refreshToken: "unrelated-refresh"))
                }
                return (403, Data(#"{"message":"Refused"}"#.utf8))
            }
            _ = try? await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(
                Endpoint(method: .get, path: "users/notifications/count"))
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(tokens.accessToken, "unrelated-login")
            XCTAssertTrue(tokens.hasSession, "An old rejected replay cannot expire another login")
        }
    }

    func testLateRefreshCannotRestoreLoggedOutCredentials() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" {
                tokens.clear()
                return (200, Data(#"{"result":{"access_token":"late-access","refresh_token":"late-refresh"}}"#.utf8))
            }
            return (403, Data(#"{"message":"Expired"}"#.utf8))
        }
        let client = APIClient(tokens: tokens, session: StubHTTP.session())
        _ = try? await client.sendIgnoringResult(Endpoint(method: .get, path: "auth/info"))
        XCTAssertFalse(tokens.hasSession, "A delayed refresh must not undo logout")
    }
    func testLateRefreshCannotReplaceOrExpireNewLogin() async {
        for status in [200, 403] {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
            StubHTTP.handler = { request in
                if request.url!.lastPathComponent == "refresh" {
                    tokens.save(Session(accessToken: "new-login", refreshToken: "new-login-refresh"))
                    return (status, Data(#"{"result":{"access_token":"late-access","refresh_token":"late-refresh"}}"#.utf8))
                }
                return (403, Data(#"{"message":"Expired"}"#.utf8))
            }
            let client = APIClient(tokens: tokens, session: StubHTTP.session())
            _ = try? await client.sendIgnoringResult(Endpoint(method: .get, path: "auth/info"))
            XCTAssertEqual(tokens.accessToken, "new-login", "Old session responses cannot alter a new login")
        }
    }
    func testEmptyRefreshTokenPairIsRejected() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" {
                return (200, Data(#"{"result":{"access_token":"","refresh_token":""}}"#.utf8))
            }
            return (403, Data(#"{"message":"Expired"}"#.utf8))
        }
        _ = try? await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .get, path: "auth/info"))
        XCTAssertFalse(tokens.hasSession)
    }
    func testPasswordVerificationRefusalEndsSessionButOfflineDoesNot() async {
        for status in [403, 200] {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
            var refuses = false
            StubHTTP.handler = { _ in
                if !refuses { return (200, Data(#"{"result":{"id":"fixture-user","role":"client"}}"#.utf8)) }
                if status == 200 { throw URLError(.timedOut) }
                return (403, Data(#"{"message":"Revoked"}"#.utf8))
            }
            let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
            await manager.restore()
            refuses = true
            await manager.refreshUser()
            XCTAssertEqual(manager.state.user != nil, status == 200)
            XCTAssertEqual(tokens.hasSession, status == 200)
        }
    }
    func testLateRestoreCannotEnterSignedInGraphAfterLogout() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
        let started = expectation(description: "auth info pending")
        let release = DispatchSemaphore(value: 0)
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "info" {
                started.fulfill()
                _ = release.wait(timeout: .now() + 4)
                return (200, Data(#"{"result":{"id":"fixture-user","role":"client"}}"#.utf8))
            }
            return (204, Data())
        }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        let task = Task { await manager.restore() }
        await fulfillment(of: [started], timeout: 2)
        await manager.signOut()
        release.signal()
        await task.value
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertFalse(tokens.hasSession)
    }
    func testRevokedSavedSessionShowsWelcomeWhenReferenceCacheIsMissing() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
        StubHTTP.handler = { _ in (403, Data(#"{"message":"Revoked"}"#.utf8)) }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        XCTAssertEqual(StartupDestination.resolve(state: manager.state, referencesReady: false, savedSessionRejected: manager.savedSessionRejected), .welcome)
        XCTAssertFalse(tokens.hasSession)
    }
    func testSignInSendsFilledMalformedEmailAndPasswordExactlyAsEntered() async throws {
        let tokens = FixtureTokens()
        let enteredEmail = " malformed email ", enteredPassword = " Password with spaces! "
        var logins = 0
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "login" {
                logins += 1
                let form = URLComponents(string: "https://fixture.invalid/?" + StubHTTP.body(request))!.queryItems!
                XCTAssertEqual(form.first { $0.name == "email" }?.value, enteredEmail)
                XCTAssertEqual(form.first { $0.name == "password" }?.value, enteredPassword)
                return (200, Data(#"{"result":{"access_token":"fixture","refresh_token":"fixture-refresh"}}"#.utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            return (200, Data(#"{"result":{"id":"fixture-user","role":"client"}}"#.utf8))
        }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        try await manager.signIn(email: enteredEmail, password: enteredPassword)
        XCTAssertEqual(logins, 1)
        XCTAssertEqual(manager.state.user?.id, "fixture-user")
        XCTAssertTrue(tokens.hasSession)
    }
    func testUnverifiableSavedSessionIsClearedAndCannotRestoreOnNextLaunch() async {
        for code in [URLError.notConnectedToInternet, .timedOut, .networkConnectionLost] {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
            var calls = 0
            StubHTTP.handler = { _ in calls += 1; throw URLError(code) }
            let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
            await manager.restore()
            XCTAssertEqual(manager.state, .signedOut)
            XCTAssertFalse(tokens.hasSession)
            XCTAssertNil(tokens.refreshToken)
            let before = calls
            await manager.restore()
            XCTAssertEqual(calls, before, "Invalid saved credentials must not return on subsequent launch")
        }
    }
    func testMissingCredentialsDoNotRequestAuthInfo() async {
        let tokens = FixtureTokens()
        StubHTTP.handler = { _ in XCTFail("No session requires no server check"); return (500, Data()) }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        XCTAssertEqual(manager.state, .signedOut)
    }
    func testVerifiedSavedSessionRemainsSignedIn() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
        StubHTTP.handler = { _ in (200, Data(#"{"result":{"id":"fixture-user","role":"client"}}"#.utf8)) }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        XCTAssertEqual(manager.state.user?.id, "fixture-user")
        XCTAssertTrue(tokens.hasSession)
    }
    func testMalformedRefreshClearsSavedCredentials() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
        StubHTTP.handler = { request in
            request.url!.lastPathComponent == "refresh" ? (200, Data(#"{"result":{}}"#.utf8)) : (403, Data(#"{"message":"Expired"}"#.utf8))
        }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertFalse(tokens.hasSession)
    }
}

/// Faults at the existing public storage seam model failed writes without
/// exhausting the real disk or modifying the production Keychain.
private final class LoginStorageFailureTokens: SessionTokenStorage, @unchecked Sendable {
    enum Failure: CaseIterable { case bothMissing, accessMissing, refreshMissing, previousPair }
    private let failure: Failure
    private let storage = FixtureTokens()
    init(failure: Failure) {
        self.failure = failure
        if failure == .previousPair { storage.save(Session(accessToken: "old-access", refreshToken: "old-refresh")) }
    }
    var generation: UUID { storage.generation }
    var accessToken: String? { storage.accessToken }
    var refreshToken: String? { storage.refreshToken }
    var hasSession: Bool { storage.hasSession }
    func save(_ session: Session) {
        switch failure {
        case .bothMissing: storage.clear()
        case .accessMissing: storage.save(Session(accessToken: "", refreshToken: session.refreshToken))
        case .refreshMissing: storage.save(Session(accessToken: session.accessToken, refreshToken: ""))
        case .previousPair: storage.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        }
    }
    func clear() { storage.clear() }
    func replace(_ session: Session, ifGeneration: UUID, refreshToken: String) -> Bool {
        storage.replace(session, ifGeneration: ifGeneration, refreshToken: refreshToken)
    }
    func clear(ifGeneration: UUID) -> Bool { storage.clear(ifGeneration: ifGeneration) }
}

/// Deterministically swaps accounts within a token getter to expose the gap
/// between generation capture and bearer construction without timing sleeps.
private final class BearerSwapTokens: SessionTokenStorage, @unchecked Sendable {
    private let base = FixtureTokens()
    private let lock = NSLock()
    private let swapOnRead: Int
    private let swapOnRefreshRead: Bool
    private var reads = 0
    private var refreshReads = 0
    init(swapOnRead: Int, swapOnRefreshRead: Bool = false) {
        self.swapOnRead = swapOnRead
        self.swapOnRefreshRead = swapOnRefreshRead
        base.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
    }
    var accessToken: String? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if reads == swapOnRead {
            base.save(Session(accessToken: "unrelated-login", refreshToken: "unrelated-refresh"))
        }
        return base.accessToken
    }
    var accessReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var currentAccess: String? { base.accessToken }
    var refreshToken: String? {
        lock.lock(); defer { lock.unlock() }
        refreshReads += 1
        if swapOnRefreshRead && refreshReads == 2 {
            base.save(Session(accessToken: "unrelated-login", refreshToken: "unrelated-refresh"))
        }
        return base.refreshToken
    }
    var hasSession: Bool { base.hasSession }
    var generation: UUID { base.generation }
    func save(_ session: Session) { base.save(session) }
    func clear() { base.clear() }
    func replace(_ session: Session, ifGeneration: UUID, refreshToken: String) -> Bool {
        base.replace(session, ifGeneration: ifGeneration, refreshToken: refreshToken)
    }
    func clear(ifGeneration: UUID) -> Bool { base.clear(ifGeneration: ifGeneration) }
}

/// Suspends only the candidate GET response, allowing real concurrent logout/new
/// login requests to finish first. No thread-blocking semaphore or timing sleep.
private final class PasswordCandidateHTTP: URLProtocol {
    static var handler: ((URLRequest, PasswordCandidateHTTP) -> Void)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler(request, self) }
    override func stopLoading() { }
    func respond(_ status: Int, _ data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PasswordCandidateHTTP.self]
        return URLSession(configuration: configuration)
    }
}

private final class PasswordCandidateResponseGate {
    private let lock = NSLock()
    private var response: PasswordCandidateHTTP?
    func hold(_ response: PasswordCandidateHTTP) {
        lock.lock(); defer { lock.unlock() }
        self.response = response
    }
    func release(_ data: Data) {
        lock.lock(); let response = self.response; self.response = nil; lock.unlock()
        response?.respond(200, data)
    }
}
