import XCTest
import Combine
@testable import Carezaar

@MainActor
final class SessionTests: XCTestCase {
    func testLateRenewalServiceFailureCancelsBeforeReachingNewAccount() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "original", refreshToken: "original-refresh"))
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" {
                tokens.save(Session(accessToken: "new-account", refreshToken: "new-refresh"))
                return (503, Data(#"{"message":"Service unavailable"}"#.utf8))
            }
            return (403, Data(#"{"message":"Expired access"}"#.utf8))
        }
        do {
            _ = try await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .get, path: "auth/info"))
            XCTFail("Superseded operation must cancel")
        } catch is CancellationError { }
        catch { XCTFail("Late renewal failure must not reach the current account") }
        XCTAssertEqual(tokens.accessToken, "new-account")
    }

    /// Parity v3 Q1: any HTTP error answer to renewal signs the person out without the
    /// Connection Problem window. Technical Alignment (26 Oct 2026), iOS 5: so does a 2xx
    /// answer that can't provide a usable session (malformed JSON, no result, empty or
    /// missing tokens), as Android clears its saved sign-in then.
    func testRenewalHTTPErrorOrUnusableSuccessSignsOutWithoutDialog() async {
        let answers: [(Int, String)] = [(400, #"{"message":"Renewal refused"}"#), (404, #"{"message":"Renewal refused"}"#),
            (500, #"{"message":"Renewal refused"}"#), (503, #"{"message":"Renewal refused"}"#),
            (200, #"{"result":{}}"#), (200, "{"), (200, #"{"result":null}"#),
            (200, #"{"result":{"access_token":"","refresh_token":""}}"#),
            (200, #"{"result":{"access_token":"only-access"}}"#)]
        for (status, body) in answers {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "original-access", refreshToken: "original-refresh"))
            var dialogRequests = 0
            StubHTTP.handler = { request in
                if request.url!.lastPathComponent == "refresh" { return (status, Data(body.utf8)) }
                return (403, Data(#"{"message":"Expired access"}"#.utf8))
            }
            let client = APIClient(tokens: tokens, session: StubHTTP.session(), reportRenewalUnreachable: { _ in
                await MainActor.run { dialogRequests += 1 }
            })
            do {
                _ = try await client.sendIgnoringResult(Endpoint(method: .get, path: "auth/info"))
                XCTFail("Unsuccessful renewal must report an error")
            } catch let error as APIError {
                guard case .unauthenticated = error else { XCTFail("HTTP \(status) \(body) renewal must end the session"); continue }
            } catch { XCTFail("Unexpected renewal error") }
            XCTAssertEqual(dialogRequests, 0, "A received answer is not a connectivity failure (HTTP \(status))")
            XCTAssertFalse(tokens.hasSession, "HTTP \(status) \(body)")
            XCTAssertNil(tokens.accessToken)
            XCTAssertNil(tokens.refreshToken)
        }
    }

    func testRenewalServerErrorDuringStartupSignsOut() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
        StubHTTP.handler = { request in
            request.url!.lastPathComponent == "refresh" ? (500, Data(#"{"message":"Server error"}"#.utf8))
                : (403, Data(#"{"message":"Expired"}"#.utf8))
        }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertTrue(manager.savedSessionRejected)
        XCTAssertFalse(tokens.hasSession)
    }

    /// Parity v3 B1: an unfinished sign-up answers login with 409 and the role in meta.
    func testIncompleteRegistrationLoginCarriesServerMessageAndRole() async {
        let tokens = FixtureTokens()
        StubHTTP.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/auth/login")
            return (409, Data(#"{"result":null,"meta":{"role":"caregiver"},"message":"Your registration is not complete. Please complete your profile to continue.","errors":null}"#.utf8))
        }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        do {
            try await manager.signIn(email: "unfinished@example.invalid", password: "Aa1!aaaa")
            XCTFail("An unfinished sign-up cannot sign in")
        } catch let error as RegistrationIncompleteError {
            XCTAssertEqual(error, RegistrationIncompleteError(
                message: "Your registration is not complete. Please complete your profile to continue.", role: .caregiver))
        } catch { XCTFail("Expected RegistrationIncompleteError, got \(error)") }
        XCTAssertFalse(tokens.hasSession)
        XCTAssertEqual(manager.state.user, nil)
        // 409 elsewhere is not an unfinished sign-up.
        StubHTTP.handler = { _ in (409, Data(#"{"message":"Conflict","meta":{"role":"client"}}"#.utf8)) }
        do {
            try await UserService(client: APIClient(tokens: tokens, session: StubHTTP.session())).sendOTP(email: "x@example.invalid")
            XCTFail("Conflict must fail")
        } catch let error as APIError { XCTAssertEqual(error, .unknown("Conflict")) }
        catch { XCTFail("Unexpected error type") }
    }

    @MainActor func testSignUpResumeSeedsProfileStepState() {
        let flow = SignUpFlow()
        flow.userId = "stale"; flow.entityCreated = true; flow.isPasswordRecovery = true; flow.otpSendFailed = true
        flow.resume(role: .caregiver, email: "a@example.invalid", password: "Aa1!aaaa")
        XCTAssertEqual(flow.role, .caregiver)
        XCTAssertEqual(flow.email, "a@example.invalid")
        XCTAssertEqual(flow.password, "Aa1!aaaa")
        XCTAssertNil(flow.userId)
        XCTAssertFalse(flow.entityCreated)
        XCTAssertFalse(flow.isPasswordRecovery)
        XCTAssertFalse(flow.otpSendFailed)
    }

    func testLateValidationResponseCannotReachNewAccount() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        StubHTTP.handler = { _ in
            tokens.save(Session(accessToken: "new-account-access", refreshToken: "new-account-refresh"))
            return (422, Data(#"{"message":"Old account validation","errors":{"email":["Correct old email"]}}"#.utf8))
        }
        do {
            _ = try await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .post, path: "users/issues"))
            XCTFail("Superseded operation must cancel")
        } catch is CancellationError { }
        catch { XCTFail("A late failure belongs to the old account, not the current UI: \(type(of: error))") }
        XCTAssertEqual(tokens.accessToken, "new-account-access")
    }

    func testRefreshStorageFailurePreservesSessionWithoutClaimingServerRejection() async {
        let tokens = RefreshStorageFailureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" { return (200, Self.passwordPair) }
            return (403, Data(#"{"message":"Expired access"}"#.utf8))
        }
        do {
            _ = try await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .get, path: "auth/info"))
            XCTFail("Failed persistence cannot report successful renewal")
        } catch APIError.unauthenticated { XCTFail("Local persistence failure is not a server refusal") }
        catch { }
        XCTAssertTrue(tokens.hasSession)
        XCTAssertEqual(tokens.accessToken, "old-access")
        XCTAssertEqual(tokens.refreshToken, "old-refresh")
    }

    func testStartupConnectivityFailurePreservesCredentialsAcrossRestartAndRetry() async {
        for failure in [URLError.notConnectedToInternet, .timedOut, .cannotConnectToHost] {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
            StubHTTP.handler = { _ in throw URLError(failure) }
            let auth = AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session()))
            let manager = SessionManager(auth: auth, tokens: tokens)
            await manager.restore()
            XCTAssertEqual(manager.state, .loading, "Unverified saved session stays behind startup recovery UI")
            XCTAssertTrue(tokens.hasSession, "Connectivity failure must not destroy saved credentials")
            XCTAssertFalse(manager.savedSessionRejected)
            XCTAssertNotNil(manager.errorMessage, "Retry UI must receive the connection failure")
            let restarted = SessionManager(auth: auth, tokens: tokens)
            await restarted.restore()
            XCTAssertTrue(tokens.hasSession, "An unresolved connection failure must survive app restart")
            StubHTTP.handler = { _ in (200, Data(#"{"result":{"id":"fixture-user","role":"client"}}"#.utf8)) }
            await restarted.retry()
            XCTAssertEqual(restarted.state.user?.id, "fixture-user")
            XCTAssertTrue(tokens.hasSession)
            XCTAssertNil(restarted.errorMessage)
        }
    }

    func testAcknowledgedPasswordChangeSignsOutWithoutBackgroundLogin() async throws {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        var logins = 0, reads = 0, changes = 0, graphSwitches = 0
        StubHTTP.handler = { request in
            switch request.url!.lastPathComponent {
            case "change": changes += 1; return (204, Data())
            case "login": logins += 1; return (200, Self.passwordPair)
            case "logout": return (204, Data())
            default: reads += 1; return (200, Self.passwordUser)
            }
        }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        manager.willSwitchGraph = { graphSwitches += 1 }
        try await manager.changePassword(current: "Old-password1!", new: "Accepted-new-password1!")
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(logins, 0, "Confirmed change must require the user's explicit next sign-in")
        XCTAssertEqual(reads, 1, "No identity read is needed after confirmed password change")
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertFalse(tokens.hasSession)
        XCTAssertEqual(graphSwitches, 1)
    }

    func testAmbiguousPasswordChangeVerifiesNewPasswordWithoutInstallingSessionOrRepeatingChange() async throws {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        var changes = 0, probes = 0, candidateReads = 0
        StubHTTP.handler = { request in
            switch request.url!.lastPathComponent {
            case "change": changes += 1; throw URLError(.networkConnectionLost)
            case "login": probes += 1; return (200, Self.passwordPair)
            case "logout": return (204, Data())
            default:
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-access" {
                    candidateReads += 1
                    XCTAssertEqual(tokens.accessToken, "old-access", "Verification must not silently install candidate credentials")
                }
                return (200, Self.passwordUser)
            }
        }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        try await manager.changePassword(current: "Old-password1!", new: "Accepted-new-password1!")
        XCTAssertEqual(changes, 1, "An unknown write must never be replayed")
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(candidateReads, 1)
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertFalse(tokens.hasSession)
    }

    /// Parity v3 Q2: the request that met an unreachable renewal fails with its own
    /// error at once; Retry renews the session and the request is never repeated.
    func testUnreachableRenewalFailsRequestOpensWindowAndRetryRenewsWithoutReplay() async throws {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        var recovered = false, callbacks = 0, reads = 0, refreshes = 0
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" {
                refreshes += 1
                if !recovered { throw URLError(.timedOut) }
                return (200, Data(#"{"result":{"access_token":"new-access","refresh_token":"new-refresh"}}"#.utf8))
            }
            reads += 1
            return (403, Data(#"{"message":"Expired access token"}"#.utf8))
        }
        let client = APIClient(tokens: tokens, session: StubHTTP.session(), reportRenewalUnreachable: { generation in
            await MainActor.run {
                XCTAssertEqual(generation, tokens.generation)
                callbacks += 1
            }
        })
        do {
            let _: User = try await client.send(Endpoint(method: .get, path: "auth/info"))
            XCTFail("The interrupted request must fail")
        } catch let error as APIError { XCTAssertEqual(error, .timeout) }
        XCTAssertEqual(callbacks, 1, "Unreachable renewal opens the Connection Problem window")
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(tokens.hasSession)
        recovered = true
        let outcome = await client.retryRenewal(generation: tokens.generation)
        XCTAssertEqual(outcome, .renewed)
        XCTAssertEqual(tokens.accessToken, "new-access")
        XCTAssertEqual(refreshes, 2)
        XCTAssertEqual(reads, 1, "Retry must not repeat the request that failed")
    }

    func testRetryRenewalReportsUnreachableAndRejected() async {
        for (handler, expected) in [
            ({ (_: URLRequest) throws -> (Int, Data) in throw URLError(.notConnectedToInternet) }, APIClient.RenewalRetryOutcome.unreachable),
            ({ (_: URLRequest) throws -> (Int, Data) in (500, Data(#"{"message":"down"}"#.utf8)) }, .rejected),
        ] {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "a", refreshToken: "r"))
            StubHTTP.handler = handler
            let outcome = await APIClient(tokens: tokens, session: StubHTTP.session()).retryRenewal(generation: tokens.generation)
            XCTAssertEqual(outcome, expected)
            XCTAssertEqual(tokens.hasSession, expected == .unreachable)
        }
    }

    func testRecoveryWindowPresentsOnceAndSuccessfulRetryClosesIt() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        var renewals = 0
        let recovery = SessionRecoveryCoordinator(tokens: tokens) { _ in renewals += 1; return .renewed }
        recovery.configure(signedIn: true)
        var presentations = 0
        let observation = recovery.$isPresented.dropFirst().sink { if $0 { presentations += 1 } }
        defer { observation.cancel() }
        recovery.present(generation: tokens.generation)
        recovery.present(generation: tokens.generation)
        XCTAssertTrue(recovery.isPresented)
        XCTAssertEqual(presentations, 1, "Concurrent failures share one window")
        await recovery.retry()
        XCTAssertFalse(recovery.isPresented)
        XCTAssertEqual(renewals, 1)
    }

    func testRecoveryRetryKeepsWindowOnlyWhileServerUnreachable() async {
        for outcome in [APIClient.RenewalRetryOutcome.unreachable, .rejected, .failed] {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "a", refreshToken: "r"))
            let recovery = SessionRecoveryCoordinator(tokens: tokens) { _ in outcome }
            recovery.configure(signedIn: true)
            recovery.present(generation: tokens.generation)
            await recovery.retry()
            XCTAssertEqual(recovery.isPresented, outcome == .unreachable, "\(outcome)")
        }
    }

    func testDeletionCannotBorrowCredentialsFromAccountChangedBeforeAPIDispatch() async {
        let tokens = DeletionDispatchSwapTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        var deletes = 0
        StubHTTP.handler = { request in
            if request.httpMethod == "DELETE" { deletes += 1; return (204, Data()) }
            return (200, Data(#"{"result":{"id":"fixture-owner","role":"client"}}"#.utf8))
        }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        tokens.arm()
        _ = try? await manager.deleteAccount(reasonId: 1)
        XCTAssertEqual(deletes, 0, "An old deletion intent must never use a newer account's credential")
        XCTAssertEqual(tokens.accessToken, "new-account-access")
    }

    func testNewSignInDismissesOlderRecoveryWindowWithoutRenewingNewCredentials() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
        var renewals = 0
        let recovery = SessionRecoveryCoordinator(tokens: tokens) { _ in renewals += 1; return .renewed }
        recovery.configure(signedIn: true)
        recovery.present(generation: tokens.generation)
        XCTAssertTrue(recovery.isPresented)
        let old = tokens.generation
        tokens.save(Session(accessToken: "new-account-access", refreshToken: "new-account-refresh"))
        recovery.configure(signedIn: true)
        XCTAssertFalse(recovery.isPresented)
        recovery.present(generation: old)
        XCTAssertFalse(recovery.isPresented, "A late failure of the old account cannot open the window")
        await recovery.retry()
        XCTAssertEqual(renewals, 0)
        XCTAssertEqual(tokens.accessToken, "new-account-access")
    }

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

    /// October 13 supersedes retained-session handoff: even revoked old tokens
    /// must end at start, followed by an explicit new-password sign-in.
    func testAcknowledgedPasswordChangeWithRevokedPairRequiresExplicitNewSignIn() async throws {
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
            case "logout": return (204, Data())
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
        try await manager.changePassword(current: "Old-password1!", new: "Accepted-new-password1!")
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertFalse(tokens.hasSession)
        XCTAssertEqual(logins, 0)
        XCTAssertEqual(switches, 1)
        try await manager.signIn(email: "fixture@example.invalid", password: "Accepted-new-password1!")
        XCTAssertEqual(logins, 1, "Only explicit sign-in may install the new pair")
        XCTAssertEqual(tokens.accessToken, "replacement-access")
        XCTAssertEqual(manager.state.user?.id, "fixture-user")
        await manager.restore()
        XCTAssertEqual(manager.state.user?.id, "fixture-user")
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
                case "change": changed = true; throw URLError(.networkConnectionLost)
                case "login":
                    logins += 1
                    return wrongUser != nil ? (200, Self.passwordPair) : (400, Data(#"{"message":"Invalid Credentials!"}"#.utf8))
                case "refresh": return (403, Data(#"{"message":"Revoked"}"#.utf8))
                default:
                    if changed {
                        if request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-access" {
                            XCTAssertEqual(tokens.accessToken, "old-access", "Wrong-identity candidate must never be installed")
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
            XCTAssertEqual(manager.state.user?.id, "fixture-user")
            XCTAssertTrue(tokens.hasSession)
        }
    }

    func testRepeatedUncertainPasswordChangeProbesOriginalOutcomeWithoutAnotherWrite() async throws {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        var writes = 0, probes = 0
        StubHTTP.handler = { request in
            switch request.url!.lastPathComponent {
            case "change": writes += 1; return (503, Data())
            case "login":
                probes += 1
                XCTAssertTrue(StubHTTP.body(request).contains("Accepted-new-password"),
                              "A later edited form must still reconcile the originally submitted password")
                return probes == 1 ? (503, Data()) : (200, Self.passwordPair)
            case "logout": return (204, Data())
            default: return (200, Self.passwordUser)
            }
        }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        do {
            try await manager.changePassword(current: "Old-password1!", new: "Accepted-new-password1!")
            XCTFail("An inconclusive outcome cannot be reported as success")
        } catch { }
        XCTAssertTrue(tokens.hasSession)
        try await manager.changePassword(current: "Old-password1!", new: "Later-edited-password1!")
        XCTAssertEqual(writes, 1, "An uncertain password mutation must never be repeated")
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertFalse(tokens.hasSession)
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

    func testAmbiguousPasswordProbeDefersOldExpiryThenSignsOutAfterVerification() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        let loginPending = expectation(description: "replacement login pending")
        let release = DispatchSemaphore(value: 0)
        var changed = false, switches = 0
        StubHTTP.handler = { request in
            switch request.url!.lastPathComponent {
            case "change": changed = true; throw URLError(.networkConnectionLost)
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
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(tokens.accessToken)
        XCTAssertEqual(switches, 1)
    }

    func testConfirmedPasswordChangeEndsEvenStillValidOldPairWithoutExtraLogin() async throws {
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
        XCTAssertEqual(logins, 0, "Successful change requires explicit sign-in, even when old pair was still valid")
        XCTAssertNil(tokens.accessToken)
        XCTAssertNil(tokens.refreshToken)
        XCTAssertNotEqual(tokens.generation, generation)
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertEqual(switches, 1)
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
                case "change": changed = true; throw URLError(.networkConnectionLost)
                case "login": logins += 1; XCTAssertEqual(tokens.accessToken, "old-access"); return (200, candidate)
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
            XCTAssertEqual(tokens.accessToken, "old-access")
            XCTAssertEqual(tokens.refreshToken, "old-refresh")
            XCTAssertEqual(manager.state.user?.id, "fixture-user")
        }
    }

    func testPasswordHandoffNeverInstallsUnverifiableCandidate() async {
        for timeout in [false, true] {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
            var changed = false, candidateReads = 0, logins = 0
            StubHTTP.handler = { request in
                switch request.url!.lastPathComponent {
                case "change": changed = true; throw URLError(.networkConnectionLost)
                case "login": logins += 1; return (200, Self.passwordPair)
                case "refresh": return (403, Data(#"{"message":"Revoked"}"#.utf8))
                default:
                    if request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-access" {
                        candidateReads += 1
                        XCTAssertEqual(tokens.accessToken, "old-access", "Candidate must remain outside shared credentials throughout verification")
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
            XCTAssertEqual(tokens.accessToken, "old-access")
            XCTAssertEqual(tokens.refreshToken, "old-refresh")
            XCTAssertEqual(manager.state.user?.id, "fixture-user")
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
                case "change": changed = true; transport.client?.urlProtocol(transport, didFailWithError: URLError(.networkConnectionLost))
                case "login":
                    let form = StubHTTP.body(request)
                    transport.respond(200, form.contains("Accepted-new-password") ? Self.passwordPair
                        : Data(#"{"result":{"access_token":"unrelated-access","refresh_token":"unrelated-refresh"}}"#.utf8))
                case "refresh": transport.respond(403, Data(#"{"message":"Revoked"}"#.utf8))
                case "logout": transport.respond(204, Data())
                default:
                    switch request.value(forHTTPHeaderField: "Authorization") {
                    case "Bearer replacement-access":
                        XCTAssertEqual(tokens.accessToken, "old-access", "Candidate cannot be installed before verification completes")
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

    /// P16-015 (owner decision, 21 Oct 2026): after a successful renewal a refused replay means
    /// "not allowed here" (e.g. the other role's screen), not an invalid session: report it as
    /// forbidden and keep the user signed in, as the web does. Still exactly one replay.
    func testRejectedReplayAfterSuccessfulRefreshKeepsSessionAndReportsForbidden() async {
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
            do {
                try await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(
                    Endpoint(method: .get, path: "users/notifications/count"))
                XCTFail("A refused replay must fail")
            } catch let error as APIError {
                guard case .forbidden = error else { XCTFail("HTTP \(status) refused replay must be forbidden, not \(error)"); continue }
            } catch { XCTFail("Unexpected \(error)") }
            XCTAssertEqual(reads, 2, "Retry once after renewal, never loop on refusal")
            XCTAssertEqual(refreshes, 1)
            XCTAssertTrue(tokens.hasSession, "A refused request on a renewed session keeps the user signed in")
            XCTAssertEqual(tokens.accessToken, "renewed-access")
        }
    }

    /// The identity check refused with a freshly renewed token means the account itself is
    /// not usable: that captured session still ends.
    func testRejectedIdentityReplayAfterSuccessfulRefreshExpiresCapturedSession() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        var reads = 0
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" {
                return (200, Data(#"{"result":{"access_token":"renewed-access","refresh_token":"renewed-refresh"}}"#.utf8))
            }
            reads += 1
            return (403, Data(#"{"message":"Refused"}"#.utf8))
        }
        _ = try? await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .get, path: "auth/info"))
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(tokens.hasSession, "A refused identity check on a renewed credential cannot remain signed in")
    }

    func testRejectedReplayUsingConcurrentRenewalKeepsCapturedSession() async {
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
        XCTAssertTrue(tokens.hasSession, "P16-015: a refused replay on the renewed session keeps it")
        XCTAssertEqual(tokens.accessToken, "renewed-access")
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
    /// Technical Alignment (26 Oct 2026), iOS 5: an empty pair is not a usable session, so the
    /// saved sign-in is cleared, as Android does when renewal brings no tokens.
    func testEmptyRefreshPairIsUnusableAndClearsSavedCredentials() async {
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
        XCTAssertNil(tokens.accessToken)
        XCTAssertNil(tokens.refreshToken)
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
    // October 13 explicitly supersedes the older clear-on-unverifiable-launch policy.
    func testServerUnavailableAtStartupPreservesSavedSessionUntilVerified() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
        StubHTTP.handler = { _ in (503, Data(#"{"message":"Service unavailable"}"#.utf8)) }
        let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
        await manager.restore()
        XCTAssertEqual(manager.state, .loading)
        XCTAssertTrue(tokens.hasSession)
        XCTAssertFalse(manager.savedSessionRejected)
        XCTAssertNotNil(manager.errorMessage)
        StubHTTP.handler = { _ in (200, Data(#"{"result":{"id":"fixture-user","role":"client"}}"#.utf8)) }
        await manager.retry()
        XCTAssertEqual(manager.state.user?.id, "fixture-user")
        XCTAssertNil(manager.errorMessage)
    }

    func testRenewalConnectivityFailureKeepsCurrentSessionAndRecoversOnNextRequest() async throws {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old-access", refreshToken: "old-refresh"))
        var online = false, renewals = 0
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" {
                renewals += 1
                if !online { throw URLError(.timedOut) }
                return (200, Data(#"{"result":{"access_token":"new-access","refresh_token":"new-refresh"}}"#.utf8))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access" {
                return (200, Data(#"{"result":{"id":"fixture-user","role":"client"}}"#.utf8))
            }
            return (403, Data(#"{"message":"Expired access token"}"#.utf8))
        }
        let client = APIClient(tokens: tokens, session: StubHTTP.session())
        do {
            let _: User = try await client.send(Endpoint(method: .get, path: "auth/info"))
            XCTFail("Unavailable renewal cannot verify identity")
        } catch let error as APIError {
            XCTAssertEqual(error, .timeout, "Connectivity is not an explicit session rejection")
        }
        XCTAssertEqual(tokens.accessToken, "old-access")
        XCTAssertEqual(tokens.refreshToken, "old-refresh")
        online = true
        let user: User = try await client.send(Endpoint(method: .get, path: "auth/info"))
        XCTAssertEqual(user.id, "fixture-user")
        XCTAssertEqual(tokens.accessToken, "new-access")
        XCTAssertEqual(renewals, 2)
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
    /// Technical Alignment (26 Oct 2026), iOS 5: an unusable 2xx renewal at startup clears the
    /// saved sign-in and lands signed out, as Android does; protected requests then carry no token.
    func testUnusableRefreshSuccessAtStartupSignsOut() async {
        for body in [#"{"result":{}}"#, "{", #"{"result":null}"#] {
            let tokens = FixtureTokens()
            tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
            StubHTTP.handler = { request in
                request.url!.lastPathComponent == "refresh" ? (200, Data(body.utf8)) : (403, Data(#"{"message":"Expired"}"#.utf8))
            }
            let manager = SessionManager(auth: AuthService(client: APIClient(tokens: tokens, session: StubHTTP.session())), tokens: tokens)
            await manager.restore()
            XCTAssertEqual(manager.state, .signedOut, body)
            XCTAssertFalse(tokens.hasSession, body)
            var authorization: String?? = .none
            StubHTTP.handler = { request in authorization = .some(request.value(forHTTPHeaderField: "Authorization")); return (403, Data(#"{"message":"Valid JWT token is required!"}"#.utf8)) }
            _ = try? await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .get, path: "users/notifications/count"))
            XCTAssertEqual(authorization, .some(nil), "A protected request after sign-out carries no saved token (\(body))")
        }
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

/// Simulates an account replacement between the owning session's capture and
/// entry into the API actor. Uses the existing storage seam, no real Keychain.
private final class DeletionDispatchSwapTokens: SessionTokenStorage, @unchecked Sendable {
    private let base = FixtureTokens()
    private let lock = NSLock()
    private var armed = false
    private var reads = 0
    func arm() { lock.lock(); armed = true; reads = 0; lock.unlock() }
    var generation: UUID {
        lock.lock(); defer { lock.unlock() }
        if armed {
            reads += 1
            if reads == 2 { base.save(Session(accessToken: "new-account-access", refreshToken: "new-account-refresh")) }
        }
        return base.generation
    }
    var accessToken: String? { base.accessToken }
    var refreshToken: String? { base.refreshToken }
    var hasSession: Bool { base.hasSession }
    func save(_ pair: Session) { base.save(pair) }
    func clear() { base.clear() }
    func replace(_ pair: Session, ifGeneration: UUID, refreshToken: String) -> Bool {
        base.replace(pair, ifGeneration: ifGeneration, refreshToken: refreshToken)
    }
    func clear(ifGeneration: UUID) -> Bool { base.clear(ifGeneration: ifGeneration) }
}

private final class RefreshStorageFailureTokens: SessionTokenStorage, @unchecked Sendable {
    private let storage = FixtureTokens()
    var generation: UUID { storage.generation }
    var accessToken: String? { storage.accessToken }
    var refreshToken: String? { storage.refreshToken }
    var hasSession: Bool { storage.hasSession }
    func save(_ session: Session) { storage.save(session) }
    func clear() { storage.clear() }
    func replace(_ session: Session, ifGeneration: UUID, refreshToken: String) -> Bool { false }
    func clear(ifGeneration: UUID) -> Bool { storage.clear(ifGeneration: ifGeneration) }
}
