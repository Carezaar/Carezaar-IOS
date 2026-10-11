import XCTest
@testable import Carezaar

@MainActor
final class PollerTests: XCTestCase {
    func testOnlyTimerTicksRequestCountAndDuplicateStartDoesNotCreateLoop() async {
        let gate = PollSleepGate()
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
        let suite = "carezaar.poller.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var countRequests = 0
        StubHTTP.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/users/notifications/count")
            countRequests += 1
            return (200, Data(#"{"result":3}"#.utf8))
        }
        var permissionRequests = 0
        let poller = NotificationPoller(service: UserService(client: APIClient(tokens: tokens, session: StubHTTP.session())),
            tokens: tokens, defaults: defaults, sleep: { try await gate.sleep($0) },
            requestPermission: { permissionRequests += 1 }, deliver: { _ in })
        poller.start { _, fallback in fallback }
        poller.start { _, fallback in fallback }
        await gate.waitForSleep()
        XCTAssertEqual(gate.intervals, [.seconds(30)])
        XCTAssertEqual(countRequests, 0, "No immediate/foreground count request")
        XCTAssertEqual(permissionRequests, 1)
        gate.advance()
        await gate.waitForSleep()
        XCTAssertEqual(countRequests, 1)
        XCTAssertEqual(poller.unread, 3)
        poller.stop()
        gate.advance()
        await Task.yield()
        await poller.poll()
        XCTAssertEqual(countRequests, 1)
        XCTAssertEqual(poller.unread, 0)
        poller.start { _, fallback in fallback }
        await gate.waitForSleep()
        XCTAssertEqual(permissionRequests, 1, "Restart must not ask permission again")
        XCTAssertEqual(countRequests, 1, "Restart still waits for its first timer tick")
        poller.stop()
        gate.advance()
        tokens.clear()
    }

    func testStoppedOrLoggedOutPollerDoesNotApplyLateResult() async {
        let gate = PollSleepGate()
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "fixture", refreshToken: "fixture-refresh"))
        let suite = "carezaar.poller.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let requested = expectation(description: "count request started")
        let release = DispatchSemaphore(value: 0)
        StubHTTP.handler = { _ in
            requested.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return (200, Data(#"{"result":7}"#.utf8))
        }
        let poller = NotificationPoller(service: UserService(client: APIClient(tokens: tokens, session: StubHTTP.session())),
            tokens: tokens, defaults: defaults, sleep: { try await gate.sleep($0) },
            requestPermission: {}, deliver: { _ in XCTFail("A cancelled poll must not post a notification") })
        poller.start { _, fallback in fallback }
        await gate.waitForSleep()
        gate.advance()
        await fulfillment(of: [requested], timeout: 2)
        tokens.clear()
        poller.stop()
        release.signal()
        // A direct late poll, as an already-enqueued lifecycle task, is also inert.
        await poller.poll()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(poller.unread, 0)
        XCTAssertEqual(defaults.integer(forKey: "carezaar.notificationCount"), 0)
        gate.advance()
    }
}

@MainActor
private final class PollSleepGate {
    private var waiting: CheckedContinuation<Void, Error>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private(set) var intervals: [Duration] = []
    func sleep(_ duration: Duration) async throws {
        intervals.append(duration)
        try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            let pending = observers
            observers.removeAll()
            pending.forEach { $0.resume() }
        }
        try Task.checkCancellation()
    }
    func waitForSleep() async {
        if waiting != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func advance() {
        let current = waiting
        waiting = nil
        current?.resume()
    }
}
