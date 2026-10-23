import XCTest
@testable import Carezaar

@MainActor
final class PagerTests: XCTestCase {
    struct Row: Identifiable { let id: Int }
    private let staleMeta = APIMeta(currentPage: 1, lastPage: 1, perPage: 10, total: 1)

    func testLoadsBeyondInitialLastPageAndShortPagesUntilEmpty() async {
        let pager = Pager<Row>()
        var requested: [Int] = []
        let fetch: Pager<Row>.Fetch = { page in
            requested.append(page)
            return (page < 4 ? [Row(id: page)] : [], self.staleMeta)
        }
        await pager.reload(fetch)
        await pager.loadMore(fetch)
        await pager.loadMore(fetch)
        await pager.loadMore(fetch)
        await pager.loadMore(fetch)
        XCTAssertEqual(requested, [1, 2, 3, 4])
        XCTAssertEqual(pager.items.map(\.id), [1, 2, 3])
        XCTAssertFalse(pager.hasMore)
    }

    func testEmptyFirstPageStopsEvenWhenMetadataClaimsMore() async {
        let pager = Pager<Row>()
        var calls = 0
        let fetch: Pager<Row>.Fetch = { _ in
            calls += 1
            return ([], APIMeta(currentPage: 1, lastPage: 50, perPage: 10, total: 500))
        }
        await pager.reload(fetch)
        await pager.loadMore(fetch)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(pager.hasMore)
        XCTAssertTrue(pager.loadedOnce)
    }

    func testDeduplicatesItemsAndStopsRepeatedNonemptyPage() async {
        let pager = Pager<Row>()
        var pages: [Int] = []
        let fetch: Pager<Row>.Fetch = { page in
            pages.append(page)
            return ([Row(id: 1), Row(id: 2), Row(id: 1)], nil)
        }
        await pager.reload(fetch)
        await pager.loadMore(fetch)
        await pager.loadMore(fetch)
        XCTAssertEqual(pager.items.map(\.id), [1, 2])
        XCTAssertEqual(pages, [1, 2])
        XCTAssertFalse(pager.hasMore)
    }

    func testLaterFailurePreservesItemsAndAllowsSamePageRetry() async {
        let pager = Pager<Row>()
        var failing = true
        var pages: [Int] = []
        let fetch: Pager<Row>.Fetch = { page in
            pages.append(page)
            if page == 2 && failing { throw APIError.network("QA dropped connection") }
            return (page == 1 ? (1...10).map(Row.init) : [Row(id: 11)], nil)
        }
        await pager.reload(fetch)
        await pager.loadMore(fetch)
        XCTAssertEqual(pager.items.map(\.id), Array(1...10))
        XCTAssertNotNil(pager.error)
        failing = false
        await pager.loadMore(fetch)
        XCTAssertEqual(pages, [1, 2, 2])
        XCTAssertEqual(pager.items.map(\.id), Array(1...11))
        XCTAssertNil(pager.error)
    }

    func testFailedReloadPreservesOldRowsThenAtomicallyReplacesOnRetry() async {
        let pager = Pager<Row>()
        await pager.reload { _ in ([Row(id: 1), Row(id: 2)], nil) }
        await pager.reload { _ in throw APIError.network("QA reload failure") }
        XCTAssertEqual(pager.items.map(\.id), [1, 2])
        XCTAssertNotNil(pager.error)
        var pages: [Int] = []
        await pager.loadMore { page in
            pages.append(page)
            return ([Row(id: 2), Row(id: 3)], nil)
        }
        XCTAssertEqual(pages, [1])
        XCTAssertEqual(pager.items.map(\.id), [2, 3])
        XCTAssertNil(pager.error)
    }

    func testConcurrentLoadMoreUsesOneRequest() async {
        let pager = Pager<Row>()
        await pager.reload { _ in ((1...10).map(Row.init), nil) }
        var calls = 0
        var gate: CheckedContinuation<([Row], APIMeta?), Error>?
        let started = expectation(description: "page request started")
        let fetch: Pager<Row>.Fetch = { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { continuation in
                gate = continuation
                started.fulfill()
            }
        }
        let first = Task { await pager.loadMore(fetch) }
        await fulfillment(of: [started], timeout: 2)
        await pager.loadMore(fetch)
        gate?.resume(returning: ([Row(id: 11)], nil))
        await first.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(pager.items.map(\.id), Array(1...11))
        XCTAssertFalse(pager.isLoading)
    }

    func testSupersededReloadCannotOverwriteNewGeneration() async {
        let pager = Pager<Row>()
        var oldGate: CheckedContinuation<([Row], APIMeta?), Error>?
        let started = expectation(description: "old reload started")
        let old = Task {
            await pager.reload { _ in
                try await withCheckedThrowingContinuation { continuation in
                    oldGate = continuation
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await pager.reload { _ in ([Row(id: 100)], nil) }
        oldGate?.resume(returning: ([Row(id: 1)], self.staleMeta))
        await old.value
        XCTAssertEqual(pager.items.map(\.id), [100])
        XCTAssertTrue(pager.hasMore)
        XCTAssertFalse(pager.isLoading)
    }

    func testCancelledPendingPagePreservesRowsClearsLoadingAndAllowsSamePageRetry() async {
        let pager = Pager<Row>()
        await pager.reload { _ in ((1...10).map(Row.init), nil) }
        let oldIDs = pager.items.map(\.id)
        let started = expectation(description: "pending second page entered")
        var pages: [Int] = []
        let pending = Task {
            await pager.loadMore { page in
                pages.append(page)
                started.fulfill()
                // Real pending cooperative work: cancellation throws before any rows return.
                try await Task.sleep(for: .seconds(30))
                XCTFail("Cancelled pending fetch must not deliver success")
                return ([Row(id: 99)], nil)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(pager.isLoading)
        pending.cancel()
        await pending.value
        XCTAssertEqual(pager.items.map(\.id), oldIDs)
        XCTAssertFalse(pager.isLoading)
        XCTAssertNil(pager.error, "Cancellation is not a connection error")
        XCTAssertTrue(pager.hasMore)
        XCTAssertEqual(pages, [2])
        await Task.yield()
        XCTAssertEqual(pages, [2], "No automatic extra page after cancelled task completes")
        await pager.loadMore { page in
            pages.append(page)
            return ([Row(id: 11)], nil)
        }
        XCTAssertEqual(pages, [2, 2], "Explicit retry uses the same uncommitted page")
        XCTAssertEqual(pager.items.map(\.id), Array(1...11))
        XCTAssertFalse(pager.isLoading)
        XCTAssertNil(pager.error)
    }

    func testCancelledPageCannotApplyLateSuccessAndExplicitRetryKeepsSamePage() async {
        let pager = Pager<Row>()
        await pager.reload { _ in ((1...10).map(Row.init), nil) }
        let oldIDs = pager.items.map(\.id)
        let started = expectation(description: "page2 continuation installed")
        var pages: [Int] = []
        var gate: CheckedContinuation<([Row], APIMeta?), Never>?
        let pending = Task {
            await pager.loadMore { page in
                pages.append(page)
                return await withCheckedContinuation { continuation in
                    gate = continuation
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(pager.isLoading)
        XCTAssertEqual(pages, [2])
        pending.cancel()
        // Same MainActor test execution: cancellation happens before the result is released.
        // This models a response that was already delivered despite transport cancellation.
        gate?.resume(returning: ([Row(id: 99)], nil))
        gate = nil
        await pending.value
        XCTAssertEqual(pager.items.map(\.id), oldIDs, "Cancelled late success must not mutate existing list")
        XCTAssertFalse(pager.isLoading)
        XCTAssertNil(pager.error, "Cancellation does not become a connection failure")
        XCTAssertTrue(pager.hasMore)
        XCTAssertEqual(pages, [2], "No automatic extra fetch")
        await pager.loadMore { page in
            pages.append(page)
            return ([Row(id: 11)], nil)
        }
        XCTAssertEqual(pages, [2, 2], "Late cancelled success must not commit page2; explicit retry stays page2")
        XCTAssertEqual(pager.items.map(\.id), Array(1...11))
        XCTAssertFalse(pager.isLoading)
        XCTAssertNil(pager.error)
    }

    func testCancelledQuietRefreshCannotApplyLateSuccessOrAdvanceExplicitPaging() async {
        let pager = Pager<Row>()
        await pager.reload { _ in ((1...10).map(Row.init), nil) }
        let oldIDs = pager.items.map(\.id)
        let started = expectation(description: "quiet refresh continuation installed")
        var quietPages: [Int] = []
        var gate: CheckedContinuation<([Row], APIMeta?), Never>?
        let pending = Task {
            await pager.refreshQuietly { page in
                quietPages.append(page)
                return await withCheckedContinuation { continuation in
                    gate = continuation
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(quietPages, [1])
        XCTAssertEqual(pager.items.map(\.id), oldIDs)
        XCTAssertFalse(pager.isLoading, "Quiet refresh must not introduce a foreground loading state")
        XCTAssertNil(pager.error)
        pending.cancel()
        gate?.resume(returning: ([Row(id: 99)], nil))
        gate = nil
        await pending.value
        XCTAssertEqual(pager.items.map(\.id), oldIDs, "Cancelled quiet result must not replace the visible list")
        XCTAssertFalse(pager.isLoading)
        XCTAssertNil(pager.error)
        XCTAssertTrue(pager.hasMore)
        XCTAssertEqual(quietPages, [1], "No automatic extra quiet fetch")
        var explicitPages: [Int] = []
        await pager.loadMore { page in
            explicitPages.append(page)
            return ([Row(id: 11)], nil)
        }
        XCTAssertEqual(explicitPages, [2], "Cancelled refresh cannot unexpectedly advance the explicit pager")
        XCTAssertEqual(pager.items.map(\.id), Array(1...11))
        XCTAssertFalse(pager.isLoading)
        XCTAssertNil(pager.error)
    }

    // MARK: Parity v3 K1 — quiet periodic refresh

    func testQuietRefreshReplacesListOnSuccessAndKeepsItOnFailure() async {
        let pager = Pager<Row>()
        await pager.reload { _ in ([Row(id: 1)], nil) }
        await pager.refreshQuietly { page in
            XCTAssertEqual(page, 1)
            return ([Row(id: 2), Row(id: 1)], nil)
        }
        XCTAssertEqual(pager.items.map(\.id), [2, 1])
        await pager.refreshQuietly { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(pager.items.map(\.id), [2, 1], "A failed background refresh keeps the list")
        XCTAssertNil(pager.error, "A failed background refresh shows no error state")
    }

    func testQuietRefreshWaitsForFirstLoad() async {
        let pager = Pager<Row>()
        var calls = 0
        await pager.refreshQuietly { _ in calls += 1; return ([Row(id: 9)], nil) }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(pager.items.isEmpty)
    }

    // MARK: Quiet refresh of the loaded pages (My Matches on return, client request 23 Oct 2026)

    /// Records calls from the refresh's concurrent page requests.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [Int] = []
        func add(_ page: Int) { lock.lock(); pages.append(page); lock.unlock() }
        var sorted: [Int] { lock.lock(); defer { lock.unlock() }; return pages.sorted() }
    }

    func testRefreshLoadedAsksForEveryLoadedPageOnceAndRebuildsTheListInOrder() async {
        let pager = Pager<Row>()
        let first: Pager<Row>.Fetch = { page in (Array((page - 1) * 3 + 1...page * 3).map(Row.init), self.staleMeta) }
        await pager.reload(first)
        await pager.loadMore(first)
        await pager.loadMore(first)
        XCTAssertEqual(pager.items.map(\.id), Array(1...9))
        // Since then id 2 went away and id 4 moved up into page 1, so page 2 repeats it.
        let calls = Calls()
        let fresh: Pager<Row>.Fetch = { page in
            calls.add(page)
            switch page {
            case 1: return ([1, 3, 4].map(Row.init), self.staleMeta)
            case 2: return ([4, 5, 6].map(Row.init), self.staleMeta)
            default: return ([7, 8, 9].map(Row.init), self.staleMeta)
            }
        }
        let refreshed = await pager.refreshLoaded(fresh)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(calls.sorted, [1, 2, 3], "every loaded page, once; not only page 1")
        XCTAssertEqual(pager.items.map(\.id), [1, 3, 4, 5, 6, 7, 8, 9], "in order, no duplicates, the removed record dropped")
        XCTAssertNil(pager.error)
        XCTAssertFalse(pager.isLoading, "no loading state")
        XCTAssertFalse(pager.isRevalidating)
        XCTAssertEqual(pager.page, 3, "the next page continues after the refreshed ones")
    }

    func testFailedRefreshKeepsTheListAndShowsNoError() async {
        let pager = Pager<Row>()
        let first: Pager<Row>.Fetch = { page in (page < 3 ? [Row(id: page * 10), Row(id: page * 10 + 1)] : [], self.staleMeta) }
        await pager.reload(first)
        await pager.loadMore(first)
        let before = pager.items.map(\.id)
        let failing: Pager<Row>.Fetch = { page in
            if page == 2 { throw URLError(.notConnectedToInternet) }
            return ([Row(id: 99)], self.staleMeta)
        }
        let refreshed = await pager.refreshLoaded(failing)
        XCTAssertFalse(refreshed)
        XCTAssertEqual(pager.items.map(\.id), before, "the last good list stays")
        XCTAssertNil(pager.error)
    }

    func testReloadStartedDuringARefreshWinsOverItsLateAnswers() async {
        let pager = Pager<Row>()
        await pager.reload { _ in ([Row(id: 1), Row(id: 2)], self.staleMeta) }
        let slow: Pager<Row>.Fetch = { _ in
            try await Task.sleep(for: .milliseconds(300))
            return ([Row(id: 500)], self.staleMeta)
        }
        let refresh = Task { await pager.refreshLoaded(slow) }
        try? await Task.sleep(for: .milliseconds(50))
        await pager.reload { _ in ([Row(id: 7)], self.staleMeta) } // a new sort
        let refreshed = await refresh.value
        XCTAssertFalse(refreshed)
        XCTAssertEqual(pager.items.map(\.id), [7], "the late refresh answers do not replace the new sort's list")
    }

    func testMatchesStoreKeepsStateForTheSameSignInOnlyAndForgetsOnSignOut() async {
        let store = MatchesStore.shared
        store.forget()
        store.prepare(for: "sign-in-1|user-a|client")
        store.sort = .pay
        store.loadedSort = .pay
        store.topCard = "card-15"
        await store.pager.reload { _ in ([MatchesTab.Card(id: "c1", user: User(id: "u1", countryId: 1, genderId: nil, role: .caregiver, email: "fixture@example.invalid", firstName: nil, lastName: nil, photo: nil, bio: nil, dateOfBirth: nil, status: .verified, isFavorite: false), min: nil, max: nil, distance: nil, clienttypeId: nil, isMatch: false)], self.staleMeta) }
        store.prepare(for: "sign-in-1|user-a|client") // back on the tab
        XCTAssertEqual(store.sort, .pay)
        XCTAssertEqual(store.topCard, "card-15")
        XCTAssertEqual(store.pager.items.count, 1)
        store.prepare(for: "sign-in-2|user-a|client") // signed in again
        XCTAssertEqual(store.sort, .distance)
        XCTAssertNil(store.loadedSort)
        XCTAssertNil(store.topCard)
        XCTAssertTrue(store.pager.items.isEmpty, "nothing of the earlier sign-in is shown")
        store.sort = .pay
        store.forget() // sign-out
        XCTAssertEqual(store.sort, .distance)
        XCTAssertTrue(store.pager.items.isEmpty)
    }
}
