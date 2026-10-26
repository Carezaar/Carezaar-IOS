import XCTest
@testable import Carezaar

/// Duplicate-action guard and Idempotency-Key handling (client request, 25 Oct 2026).
/// Real UserService/APIClient transport against StubHTTP; never contacts the server.
@MainActor
final class LoadingIdempotencyTests: XCTestCase {
    private let uuid = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    private func isUUID(_ s: String?) -> Bool {
        guard let s else { return false }
        return uuid.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    override func setUp() async throws {
        IdempotencyStore.shared.clearAll()
        IdempotencyStore.shared.account = "user-a"
        ActionGuard.shared.reset()
        ActionGuard.shared.account = "user-a"
    }

    // MARK: guard

    func testSecondActionOnTheSameResourceIsRejectedAtOnceNotQueued() async throws {
        let gate = AsyncGate()
        var runs = 0
        let first = Task { try await ActionGuard.shared.run("chat:5:send") { runs += 1; await gate.wait(); return "sent" } }
        await Task.yield(); await Task.yield()
        XCTAssertTrue(ActionGuard.shared.isBusy("chat:5:send"))
        do { _ = try await ActionGuard.shared.run("chat:5:send") { runs += 1; return "again" }; XCTFail("Duplicate must be rejected") }
        catch { XCTAssertTrue(error is DuplicateActionError) }
        await gate.open()
        let value = try await first.value
        XCTAssertEqual(value, "sent")
        XCTAssertEqual(runs, 1)
        XCTAssertFalse(ActionGuard.shared.isBusy("chat:5:send"), "Released after success")
    }

    func testAcceptAndRejectShareOneGuardWhileOtherResourcesStayUsable() async throws {
        let gate = AsyncGate()
        let accepting = Task { try await ActionGuard.shared.run("match:partner-1") { await gate.wait() } }
        await Task.yield(); await Task.yield()
        do { try await ActionGuard.shared.run("match:partner-1") {}; XCTFail("Reject while accepting") }
        catch { XCTAssertTrue(error is DuplicateActionError) }
        let other = try await ActionGuard.shared.run("match:partner-2") { "other match" }
        let favourite = try await ActionGuard.shared.run("bookmark:partner-1") { "favourite" }
        XCTAssertEqual(other, "other match"); XCTAssertEqual(favourite, "favourite")
        await gate.open()
        try await accepting.value
    }

    func testGuardIsReleasedAfterFailureAndCancellationAndBelongsToTheAccount() async throws {
        do { try await ActionGuard.shared.run("issue:create") { throw APIError.server("x") }; XCTFail() } catch {}
        XCTAssertFalse(ActionGuard.shared.isBusy("issue:create"))
        let task = Task { try await ActionGuard.shared.run("issue:create") { try await Task.sleep(for: .seconds(30)) } }
        await Task.yield(); await Task.yield()
        XCTAssertTrue(ActionGuard.shared.isBusy("issue:create"))
        ActionGuard.shared.account = "user-b"
        XCTAssertFalse(ActionGuard.shared.isBusy("issue:create"), "Another account is not blocked")
        ActionGuard.shared.account = "user-a"
        task.cancel()
        _ = try? await task.value
        XCTAssertFalse(ActionGuard.shared.isBusy("issue:create"), "Released after cancellation")
    }

    // MARK: idempotency store

    private func store() -> IdempotencyStore {
        let suite = UserDefaults(suiteName: "LoadingIdempotencyTests")!
        suite.removePersistentDomain(forName: "LoadingIdempotencyTests")
        let store = IdempotencyStore(defaults: suite)
        store.account = "user-a"
        return store
    }
    private let form: [String: FormValue?] = ["message": .string("Hello"), "parent_id": nil]

    func testOneUUIDPerSubmissionReusedAfterUncertainFailuresAndNewAfterSuccess() async throws {
        let store = store()
        var keys: [String] = []
        for failure in [APIError.network("lost"), .timeout, .server("502")] {
            do { _ = try await store.submit(.chatMessage, target: "7", form: form) { (k: String) -> String in keys.append(k); throw failure }; XCTFail() } catch {}
        }
        _ = try await store.submit(.chatMessage, target: "7", form: form) { (k: String) -> String in keys.append(k); return "ok" }
        XCTAssertTrue(isUUID(keys[0]))
        XCTAssertEqual(Set(keys).count, 1, "Every retry of the unresolved submission used the same key")
        _ = try await store.submit(.chatMessage, target: "7", form: form) { (k: String) -> String in keys.append(k); return "ok" }
        XCTAssertNotEqual(keys.last, keys.first, "The same text after a confirmed success is a new key")
        XCTAssertTrue(store.pending(.chatMessage, target: "7").isEmpty)
    }

    func testKeysAreScopedByDataTargetAndAccountAndSurviveARestart() async throws {
        let suite = UserDefaults(suiteName: "LoadingIdempotencyRestart")!
        suite.removePersistentDomain(forName: "LoadingIdempotencyRestart")
        let store = IdempotencyStore(defaults: suite); store.account = "user-a"
        func key(_ s: IdempotencyStore, _ form: [String: FormValue?], target: String = "7") async -> String {
            var key = ""
            _ = try? await s.submit(.chatMessage, target: target, form: form, draft: "Hello", parent: nil) { (k: String) -> String in key = k; throw APIError.network("lost") }
            return key
        }
        let a = await key(store, form)
        let other = await key(store, ["message": .string("Hello!"), "parent_id": nil])
        let reply = await key(store, ["message": .string("Hello"), "parent_id": .int(3)])
        let chat = await key(store, form, target: "8")
        store.account = "user-b"
        let account = await key(store, form)
        XCTAssertEqual(Set([a, other, reply, chat, account]).count, 5)
        // A restart: a new store over the same storage, the same account.
        let restarted = IdempotencyStore(defaults: suite); restarted.account = "user-a"
        XCTAssertEqual(restarted.pending(.chatMessage, target: "7").first(where: { $0.key == a })?.draft, "Hello")
        let again = await key(restarted, form)
        XCTAssertEqual(again, a, "The retry after a restart sends the same key")
    }

    func testDefinitiveRefusalRetiresTheKeyAndServerErrorKeepsIt() async {
        let store = store()
        _ = try? await store.submit(.issue, target: "issues", form: ["description": .string("x")]) { (_: String) -> String in throw APIError.validation(message: "x", fields: ["description": ["x"]]) }
        XCTAssertTrue(store.pending(.issue, target: "issues").isEmpty)
        _ = try? await store.submit(.issue, target: "issues", form: ["description": .string("y")]) { (_: String) -> String in throw APIError.server("500") }
        XCTAssertEqual(store.pending(.issue, target: "issues").count, 1)
    }

    func testConflictIsNotResentAndExpiredIsReconciledFirst() async throws {
        let store = store()
        var sends = 0
        do {
            _ = try await store.submit(.chatMessage, target: "7", form: form) { (_: String) -> String in sends += 1; throw IdempotencyServerError(code: "idempotency_conflict") }
            XCTFail()
        } catch { XCTAssertTrue(error is IdempotencyConflictError) }
        XCTAssertEqual(sends, 1)
        XCTAssertTrue(store.pending(.chatMessage, target: "7").isEmpty)
        let expired = IdempotencyServerError(code: "idempotency_expired")
        let found = try await store.submit(.chatMessage, target: "7", form: form) { (_: String) -> String in throw expired } reconcile: { _ in "already sent" }
        XCTAssertEqual(found, "already sent")
        do { _ = try await store.submit(.chatMessage, target: "7", form: form) { (_: String) -> String in throw expired } reconcile: { _ in nil }; XCTFail() }
        catch { XCTAssertTrue(error is SubmissionNotCarriedOutError) }
        XCTAssertTrue(store.pending(.chatMessage, target: "7").isEmpty)
        do { _ = try await store.submit(.chatMessage, target: "7", form: form) { (_: String) -> String in throw expired } reconcile: { _ in throw APIError.network("x") }; XCTFail() }
        catch {}
        XCTAssertEqual(store.pending(.chatMessage, target: "7").count, 1, "An unfinished check keeps the key")
    }

    // MARK: transport

    func testTheThreeWritesSendTheHeaderAndARenewedSignInResendsTheSameKey() async throws {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "old", refreshToken: "refresh-1"))
        var posts: [(String, String?, String?)] = []
        var refused = false
        StubHTTP.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("auth/refresh") { return (200, Data(#"{"result":{"access_token":"new","refresh_token":"refresh-2"}}"#.utf8)) }
            // The issue list read for the baseline when the screen's list isn't known.
            if refused, request.httpMethod == "GET", path.hasSuffix("users/issues") { return (200, Data(#"{"result":[]}"#.utf8)) }
            posts.append((path, request.value(forHTTPHeaderField: "Idempotency-Key"), request.value(forHTTPHeaderField: "Authorization")))
            if !refused { refused = true; return (403, Data(#"{"message":"Token is invalid!"}"#.utf8)) }
            if path.hasSuffix("users/chats/7") { return (200, Data(#"{"result":{"id":7,"messages":[]}}"#.utf8)) }
            if path.hasSuffix("users/issues") { return (200, Data(#"{"result":{"id":9,"description":"d","is_replied":false}}"#.utf8)) }
            if path.hasSuffix("users/bookmarks") { return (204, Data()) }
            return (200, Data(#"{"result":{"id":3,"is_client_accepted":false,"is_caregiver_accepted":true}}"#.utf8))
        }
        let service = UserService(client: APIClient(tokens: tokens, session: StubHTTP.session()))
        _ = try await service.sendMessage(chatId: 7, message: "Hello")
        XCTAssertEqual(posts.count, 2, "Refused once, renewed, sent once more")
        XCTAssertTrue(isUUID(posts[0].1))
        XCTAssertEqual(posts[1].1, posts[0].1, "The resend after renewal keeps the key")
        XCTAssertEqual(posts[1].2, "Bearer new")
        posts.removeAll()
        _ = try await service.createIssue(issuetypeId: nil, title: "t", description: "d")
        _ = try await service.requestMatch(partnerId: "partner-9", introduction: "Hi")
        XCTAssertEqual(posts.map(\.0), ["/api/users/issues", "/api/users/matches"])
        XCTAssertTrue(posts.allSatisfy { isUUID($0.1) })
        XCTAssertNotEqual(posts[0].1, posts[1].1)
        posts.removeAll()
        try await service.addBookmark(partnerId: "partner-9")
        XCTAssertNil(posts.first?.1, "Only the three named writes carry a key")
    }

    func testConflictAnswerFromTheServerIsNotResent() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "a", refreshToken: "r"))
        var posts = 0
        StubHTTP.handler = { _ in
            posts += 1
            return (409, Data(#"{"result":null,"meta":{"code":"idempotency_conflict"},"message":"This key was already used for a different request."}"#.utf8))
        }
        let service = UserService(client: APIClient(tokens: tokens, session: StubHTTP.session()))
        do { _ = try await service.sendMessage(chatId: 7, message: "Hello"); XCTFail() }
        catch { XCTAssertTrue(error is IdempotencyConflictError, "\(error)") }
        XCTAssertEqual(posts, 1)
    }
}

/// A one-shot gate for holding an action open in a test.
private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// Records the waits APIClient asks for between read retries, without waiting.
private final class RecordedWaits: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [Duration] = []
    var values: [Duration] { lock.withLock { waits } }
    func pause(_ duration: Duration) async throws { lock.withLock { waits.append(duration) } }
}

/// "Carezaar — Technical Alignment Tasks" (26 Oct 2026), iOS 4-6, against the Android 1.0.0
/// APK (`je.safeCall`: up to 3 retries, (n + 1) × 500 ms, any IOException but a SocketException;
/// `ms3.v()`: an unusable renewal clears the saved sign-in). Real APIClient on StubHTTP.
@MainActor
final class TechnicalAlignmentNetworkTests: XCTestCase {
    private let androidDelays: [Duration] = [.milliseconds(500), .milliseconds(1_000), .milliseconds(1_500)]

    private func client(_ tokens: FixtureTokens = FixtureTokens(), waits: RecordedWaits) -> APIClient {
        if !tokens.hasSession { tokens.save(Session(accessToken: "access", refreshToken: "refresh")) }
        return APIClient(tokens: tokens, session: StubHTTP.session(), pause: { try await waits.pause($0) })
    }

    func testTransientReadFailuresAreRetriedThreeTimesWithAndroidDelays() async {
        for code: URLError.Code in [.cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .timedOut, .networkConnectionLost, .secureConnectionFailed] {
            let waits = RecordedWaits()
            var attempts = 0
            StubHTTP.handler = { _ in attempts += 1; throw URLError(code) }
            do { _ = try await client(waits: waits).sendIgnoringResult(Endpoint(method: .get, path: "users/notifications/count")); XCTFail("\(code)") }
            catch {}
            XCTAssertEqual(attempts, 4, "One request and three retries (\(code.rawValue))")
            XCTAssertEqual(waits.values, androidDelays, "\(code.rawValue)")
        }
    }

    func testARefusedConnectionAndHTTPErrorsAreNotRetried() async {
        let waits = RecordedWaits()
        var attempts = 0
        StubHTTP.handler = { _ in attempts += 1; throw URLError(.cannotConnectToHost) }
        do { _ = try await client(waits: waits).sendIgnoringResult(Endpoint(method: .get, path: "users/notifications/count")); XCTFail() } catch {}
        XCTAssertEqual(attempts, 1, "Android's ConnectException is a SocketException: not retried")
        attempts = 0
        StubHTTP.handler = { _ in attempts += 1; return (500, Data(#"{"message":"Server Error"}"#.utf8)) }
        do { _ = try await client(waits: waits).sendIgnoringResult(Endpoint(method: .get, path: "users/notifications/count")); XCTFail() } catch {}
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(waits.values, [])
    }

    func testAReadThatRecoversReturnsItsAnswer() async throws {
        let waits = RecordedWaits()
        var attempts = 0
        StubHTTP.handler = { _ in
            attempts += 1
            if attempts < 3 { throw URLError(.notConnectedToInternet) }
            return (200, Data(#"{"result":{"count":3},"meta":null,"message":"ok","errors":null}"#.utf8))
        }
        _ = try await client(waits: waits).sendIgnoringResult(Endpoint(method: .get, path: "users/notifications/count"))
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(waits.values, Array(androidDelays.prefix(2)))
    }

    func testWritesAreNeverRetriedAutomatically() async {
        for code: URLError.Code in [.cannotFindHost, .notConnectedToInternet, .cannotConnectToHost, .timedOut, .networkConnectionLost] {
            for method: HTTPMethod in [.post, .patch, .put, .delete] {
                let waits = RecordedWaits()
                var attempts = 0
                StubHTTP.handler = { _ in attempts += 1; throw URLError(code) }
                do { _ = try await client(waits: waits).sendIgnoringResult(Endpoint(method: method, path: "users/bookmarks")); XCTFail() } catch {}
                XCTAssertEqual(attempts, 1, "\(method.rawValue) after \(code.rawValue)")
                XCTAssertEqual(waits.values, [])
            }
        }
    }

    func testTheRenewalRequestIsNotRetried() async {
        let waits = RecordedWaits()
        var refreshes = 0
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" { refreshes += 1; throw URLError(.cannotFindHost) }
            return (403, Data(#"{"message":"Valid JWT token is required!"}"#.utf8))
        }
        do { _ = try await client(waits: waits).sendIgnoringResult(Endpoint(method: .post, path: "users/bookmarks")); XCTFail() } catch {}
        XCTAssertEqual(refreshes, 1, "Android's refresh call isn't wrapped in safeCall")
    }

    func testCancellingDuringAWaitStopsRetrying() async {
        var attempts = 0
        StubHTTP.handler = { _ in attempts += 1; throw URLError(.notConnectedToInternet) }
        let tokens = FixtureTokens(); tokens.save(Session(accessToken: "access", refreshToken: "refresh"))
        let api = APIClient(tokens: tokens, session: StubHTTP.session(), pause: { _ in throw CancellationError() })
        do { _ = try await api.sendIgnoringResult(Endpoint(method: .get, path: "users/notifications/count")); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(attempts, 1)
    }

    // MARK: pending submissions past 24 hours

    private func seededStore(account: String, created: Date, form: [String: FormValue?], key: String) -> IdempotencyStore {
        let defaults = UserDefaults(suiteName: "TechnicalAlignment-\(UUID().uuidString)")!
        let scope = "\(account)|issue|issues|\(IdempotencyStore.payloadHash(form))"
        let record = PendingSubmission(key: key, created: created, account: account, operation: .issue, target: "issues", after: 4)
        defaults.set(try! JSONEncoder().encode([scope: record]), forKey: IdempotencyStore.storageKey)
        let store = IdempotencyStore(defaults: defaults)
        store.account = "account-a"
        return store
    }

    func testAnUnresolvedKeyFrom25HoursAgoIsReused() async throws {
        let form: [String: FormValue?] = ["title": .string("Login"), "description": .string("Can't sign in")]
        let old = "6d7c2b1e-0d1f-4a5b-9c8d-7e6f5a4b3c2d"
        let store = seededStore(account: "account-a", created: Date().addingTimeInterval(-25 * 3600), form: form, key: old)
        XCTAssertEqual(store.pending(.issue, target: "issues").first?.key, old, "Still pending after 25 hours")
        var sent: [String] = []
        let result = try await store.submit(.issue, target: "issues", form: form, after: 4) { (key: String) -> String in sent.append(key); return "filed" }
        XCTAssertEqual(result, "filed")
        XCTAssertEqual(sent, [old], "The original key, not a new one")
        XCTAssertTrue(store.pending(.issue, target: "issues").isEmpty, "Retired once confirmed")
    }

    func testAfter25HoursAForgottenKeyIsReconciledBeforeAnythingNewIsSent() async throws {
        let form: [String: FormValue?] = ["title": .string("Login"), "description": .string("Can't sign in")]
        let old = "6d7c2b1e-0d1f-4a5b-9c8d-7e6f5a4b3c2d"
        var sends = 0
        var store = seededStore(account: "account-a", created: Date().addingTimeInterval(-25 * 3600), form: form, key: old)
        let found = try await store.submit(.issue, target: "issues", form: form, after: 4) { (_: String) -> String in
            sends += 1; throw IdempotencyServerError(code: "idempotency_expired")
        } reconcile: { record in record.after == 4 ? "issue 5, filed earlier" : nil }
        XCTAssertEqual(found, "issue 5, filed earlier")
        XCTAssertEqual(sends, 1, "No second mutation")
        store = seededStore(account: "account-a", created: Date().addingTimeInterval(-25 * 3600), form: form, key: old)
        do {
            _ = try await store.submit(.issue, target: "issues", form: form, after: 4) { (_: String) -> String in
                throw IdempotencyServerError(code: "idempotency_expired")
            } reconcile: { _ in nil }
            XCTFail("Not found: not carried out")
        } catch { XCTAssertTrue(error is SubmissionNotCarriedOutError) }
    }

    func testARecordTheServerShowsAsCarriedOutIsRetiredAndOthersAreKept() async throws {
        let form: [String: FormValue?] = ["title": .string("Login"), "description": .string("Can't sign in")]
        let store = seededStore(account: "account-a", created: Date().addingTimeInterval(-40 * 3600), form: form, key: "6d7c2b1e-0d1f-4a5b-9c8d-7e6f5a4b3c2d")
        XCTAssertEqual(store.retireCarriedOut(.issue, target: "issues") { _ in false }, 0)
        XCTAssertEqual(store.pending(.issue, target: "issues").count, 1, "Not shown as carried out: kept")
        XCTAssertEqual(store.retireCarriedOut(.issue, target: "issues") { $0.after == 4 }, 1)
        XCTAssertTrue(store.pending(.issue, target: "issues").isEmpty, "Shown as carried out: retired")
        // The next identical issue is a new submission with a new key.
        var sent: [String] = []
        _ = try await store.submit(.issue, target: "issues", form: form, after: 9) { (key: String) -> String in sent.append(key); return "filed" }
        XCTAssertNotEqual(sent.first, "6d7c2b1e-0d1f-4a5b-9c8d-7e6f5a4b3c2d")
    }

    func testCertificateAndMalformedAnswerFailuresAreRetriedLikeAndroidIOExceptions() async {
        for code: URLError.Code in [.serverCertificateUntrusted, .cannotParseResponse, .zeroByteResource] {
            let waits = RecordedWaits()
            var attempts = 0
            StubHTTP.handler = { _ in attempts += 1; throw URLError(code) }
            do { _ = try await client(waits: waits).sendIgnoringResult(Endpoint(method: .get, path: "users/notifications/count")); XCTFail() } catch {}
            XCTAssertEqual(attempts, 4, "\(code.rawValue)")
        }
    }

    func testAnotherAccountsPendingRecordIsNeverUsed() async throws {
        let form: [String: FormValue?] = ["title": .string("Login"), "description": .string("Can't sign in")]
        let theirs = "11111111-1111-4111-8111-111111111111"
        let store = seededStore(account: "account-b", created: Date().addingTimeInterval(-30 * 3600), form: form, key: theirs)
        var sent: [String] = []
        _ = try await store.submit(.issue, target: "issues", form: form, after: 4) { (key: String) -> String in sent.append(key); return "filed" }
        XCTAssertNotEqual(sent.first, theirs)
        store.account = "account-b"
        XCTAssertEqual(store.pending(.issue, target: "issues").first?.key, theirs, "Still kept for its own account")
    }
}
