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
}
