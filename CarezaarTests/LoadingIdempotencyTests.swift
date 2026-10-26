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
