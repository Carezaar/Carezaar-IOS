import XCTest

/// Client request, 23 Oct 2026: My Matches keeps the chosen sort for the whole sign-in and forgets
/// it on sign-out; coming back to the tab keeps the list on screen in that order and refreshes
/// every loaded page quietly — no loading window, no return to the first page.
/// Production API; the primary account (QA_EMAIL) is the caregiver of the owned pair (51 clients,
/// several pages); QA_CLIENT_EMAIL is the client (one page). Request counts come from the app's
/// Debug request ledger (`--qa-request-counts`).
final class MyMatchesStateUITests: XCTestCase {
    private let app = XCUIApplication()
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() { continueAfterFailure = false }
    override func tearDown() { app.terminate(); super.tearDown() }

    // MARK: Helpers

    private func launch(_ extra: [String] = []) throws {
        guard let email = env["QA_EMAIL"], let password = env["QA_PASSWORD"] else { throw XCTSkip("QA_EMAIL / QA_PASSWORD required") }
        // Keep the system log off the app's stderr: a long list makes XCTest's snapshot logging
        // fill that pipe, which blocks the app's main thread (seen as a never-idle app).
        app.launchEnvironment["OS_ACTIVITY_DT_MODE"] = "NO"
        app.launchEnvironment["QA_EMAIL"] = email
        app.launchEnvironment["QA_PASSWORD"] = password
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-tab", "matches",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"] + extra
        app.launch()
        try waitForCards()
    }

    private func ledger() -> [String: Int] {
        // firstMatch: no uniqueness check across the screen's elements.
        let element = app.staticTexts.matching(identifier: "qa-request-counts").firstMatch
        guard element.exists else { return [:] }
        var result: [String: Int] = [:]
        for line in element.label.split(separator: "\n") {
            guard let equal = line.lastIndex(of: "="), let value = Int(line[line.index(after: equal)...]) else { continue }
            result[String(line[..<equal])] = value
        }
        return result
    }
    /// My Matches list requests: a caregiver loads `caregivers/matches`, a client `clients/matches`.
    private func requests() -> Int {
        let counts = ledger()
        return (counts["GET /api/caregivers/matches"] ?? 0) + (counts["GET /api/clients/matches"] ?? 0)
    }

    /// The list's state from the app's Debug readout: sort, pages, items, the card at the top
    /// (from SwiftUI's scroll position), whether a quiet refresh or a load is running.
    private func state() -> [String: String] {
        let element = app.staticTexts.matching(identifier: "qa-matches-state").firstMatch
        guard element.waitForExistence(timeout: 10) else { return [:] }
        var out: [String: String] = [:]
        for part in element.label.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }

    private var sortButton: XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sort (")).firstMatch }
    private var cards: XCUIElementQuery { app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "mile(s) away")) }

    private func waitForCards(timeout: TimeInterval = 60) throws {
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: timeout), "My Matches shows cards")
        XCTAssertTrue(app.staticTexts["Please wait..."].waitForNonExistence(timeout: timeout))
    }

    /// Waits until the list reports `pages` loaded and nothing running.
    private func waitForList(pages: Int? = nil, timeout: TimeInterval = 60) {
        let ready = NSPredicate { _, _ in
            let s = self.state()
            return s["loading"] == "false" && s["revalidating"] == "false" && (pages == nil || Int(s["pages"] ?? "") ?? 0 >= pages!)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: timeout), .completed, "list ready \(state())")
    }

    private func chooseSort(_ name: String) throws {
        // Not while a loading window covers the screen (just after sign-in).
        XCTAssertTrue(sortButton.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Please wait..."].waitForNonExistence(timeout: 30))
        sortButton.tap()
        let option = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        // Just after sign-in the app's "New Notification(s)" banner can swallow the first tap.
        if !option.waitForExistence(timeout: 3) { sortButton.tap() }
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        option.tap()
        let chosen = NSPredicate { _, _ in self.sortButton.exists && self.sortButton.label.contains(name) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: chosen, object: nil)], timeout: 10), .completed)
        try waitForCards()
    }

    /// True if the blocking loading window appears within `seconds`.
    private func loadingWindowAppears(within seconds: TimeInterval) -> Bool {
        let busy = app.staticTexts["Please wait..."]
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if busy.exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// The bottom bar's tab ("Profile" is also the avatar button in the top bar, which comes first).
    private func tab(_ name: String) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "label == %@", name))
        return all.count > 1 ? all.element(boundBy: all.count - 1) : all.firstMatch
    }

    /// Opens a tab, retrying while a tap is swallowed (a notification banner, or another tab's
    /// loading window on a slow network); `onMatches` says whether My Matches should then show.
    private func open(_ name: String, onMatches: Bool) {
        let readout = app.descendants(matching: .any)["qa-matches-state"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        repeat {
            tab(name).tap()
            if onMatches ? readout.waitForExistence(timeout: 2) : readout.waitForNonExistence(timeout: 2) { return }
        } while Date() < deadline
        XCTFail("\(name) tab opened")
    }

    private func signOutThroughTheApp() {
        let logout = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Log Out")).firstMatch
        // Just after sign-in the "New Notification(s)" banner can swallow the tab tap.
        for _ in 0..<3 where !logout.exists {
            tab("Profile").tap()
            Thread.sleep(forTimeInterval: 1)
            for _ in 0..<8 where !(logout.exists && logout.isHittable) { app.swipeUp() }
        }
        XCTAssertTrue(logout.waitForExistence(timeout: 10))
        logout.tap()
        let confirm = app.alerts.buttons["Confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
    }

    private func signInThroughTheApp(email: String, password: String) throws {
        let field = app.textFields["Enter your email address..."]
        if !field.waitForExistence(timeout: 10) {
            let signIn = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Sign In")).firstMatch
            XCTAssertTrue(signIn.waitForExistence(timeout: 30)); signIn.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap(); field.typeText(email)
        let secret = app.secureTextFields["Enter your password..."]
        for _ in 0..<3 where !((secret.value(forKey: "hasKeyboardFocus") as? Bool) ?? false) {
            secret.tap(); Thread.sleep(forTimeInterval: 0.5)
        }
        secret.typeText(password)
        let submit = { self.app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Sign In")).allElementsBoundByIndex.last { $0.isHittable } }
        // On a small screen the keyboard covers the button: close it first, as a person would.
        for _ in 0..<3 where submit() == nil { app.swipeUp() }
        if submit() == nil, app.keyboards.buttons["return"].exists { app.keyboards.buttons["return"].tap() }
        XCTAssertNotNil(submit(), "the Sign In button can be reached")
        submit()?.tap()
        // iOS offers to save the password after a typed sign-in (it can cover the list before the
        // cards are read); a person would say Not Now.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !cards.firstMatch.exists {
            for notNow in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where notNow.exists { notNow.tap() }
            Thread.sleep(forTimeInterval: 1)
        }
        for notNow in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where notNow.waitForExistence(timeout: 2) {
            notNow.tap(); break
        }
        try waitForCards(timeout: 30)
        waitForList()
    }

    /// Leaves My Matches the given way and comes back; returns what the return looked like.
    private func leaveAndReturn(_ how: String) -> (loadingWindow: Bool, sent: Int) {
        let sent = requests()
        if how == "profile" {
            let s = state()
            let card = cards.matching(NSPredicate(format: "label BEGINSWITH %@", s["topName"] ?? "")).firstMatch
            let target = card.exists ? card : cards.firstMatch
            Thread.sleep(forTimeInterval: 1) // let the list come to rest; a tap on a moving list only stops it
            target.tap()
            let back = app.buttons["BackButton"]
            if !back.waitForExistence(timeout: 5) { target.tap() }
            XCTAssertTrue(back.waitForExistence(timeout: 30))
            XCTAssertTrue(app.staticTexts["Please wait..."].waitForNonExistence(timeout: 60))
            back.tap()
        } else {
            // Leaving the tab removes My Matches (and its readout).
            open(how, onMatches: false)
            Thread.sleep(forTimeInterval: 1)
            open("Matches", onMatches: true)
        }
        return (loadingWindowAppears(within: 2.5), sent)
    }

    private func attach(_ name: String, _ facts: [String: Any]) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name + "-screen"; shot.lifetime = .keepAlways; add(shot)
        if let data = try? JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]) {
            let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); a.name = name; a.lifetime = .keepAlways; add(a)
        }
    }

    // MARK: Tests

    func testSortListAndPlaceAreKeptOnReturnAndEveryLoadedPageIsRefreshedQuietly() throws {
        try launch(["--qa-matches-pages", "3"])
        waitForList(pages: 3)
        XCTAssertTrue(sortButton.label.contains("Distance"), "a fresh sign-in starts sorted by distance: \(sortButton.label)")
        try chooseSort("Pay")
        waitForList(pages: 3)
        let loaded = state()
        let pages = Int(loaded["pages"] ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(pages, 3, "several pages loaded: \(loaded)")
        XCTAssertFalse((loaded["top"] ?? "").isEmpty, "a card of page 3 is at the top: \(loaded)")
        attach("my-matches-before-leaving", loaded)

        for (cycle, how) in ["profile", "Messages", "Profile", "profile", "Messages", "Profile"].enumerated() {
            let before = state()
            let result = leaveAndReturn(how)
            let immediately = state() // before the refresh has answered
            let refreshed = NSPredicate { _, _ in self.requests() - result.sent >= pages && self.state()["revalidating"] == "false" }
            let done = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: refreshed, object: nil)], timeout: 30) == .completed
            Thread.sleep(forTimeInterval: 1)
            let after = state()
            let count = requests() - result.sent
            attach("my-matches-return-\(cycle + 1)-\(how)", ["how": how, "before": before, "immediately": immediately, "after": after,
                   "refreshRequests": count, "pagesLoaded": pages, "loadingWindow": result.loadingWindow, "sortLabel": sortButton.label])
            XCTAssertTrue(sortButton.label.contains("Pay"), "[\(how)] the sort is kept: \(sortButton.label)")
            XCTAssertEqual(immediately["sort"], "pay")
            XCTAssertEqual(immediately["items"], before["items"], "[\(how)] every loaded page is still on screen when coming back")
            XCTAssertEqual(immediately["top"], before["top"], "[\(how)] the same card at the top (same place in the list)")
            XCTAssertFalse(result.loadingWindow, "[\(how)] no loading window when the list was already loaded")
            XCTAssertEqual(Int(after["appears"] ?? ""), (Int(before["appears"] ?? "") ?? -1) + 1, "[\(how)] My Matches came back once")
            XCTAssertTrue(done, "[\(how)] every loaded page is refreshed (\(count) of \(pages))")
            XCTAssertEqual(count, pages, "[\(how)] each loaded page once: not page 1 only, and not twice")
            XCTAssertEqual(after["pages"], before["pages"], "[\(how)] still \(pages) pages after the refresh")
            XCTAssertEqual(after["top"], before["top"], "[\(how)] the same place after the refresh")
        }
    }

    func testSignOutForgetsTheSortAndAnotherAccountStartsFresh() throws {
        guard let email = env["QA_EMAIL"], let password = env["QA_PASSWORD"],
              let clientEmail = env["QA_CLIENT_EMAIL"], let clientPassword = env["QA_CLIENT_PASSWORD"] else { throw XCTSkip("credentials required") }
        try launch()
        waitForList()
        let caregiverFirst = state()["firstName"] ?? ""
        try chooseSort("Pay")
        waitForList()
        signOutThroughTheApp()
        try signInThroughTheApp(email: email, password: password)
        let again = state()
        attach("my-matches-after-sign-in-again", again)
        XCTAssertTrue(sortButton.label.contains("Distance"), "signing in again starts from the default sort: \(sortButton.label)")
        XCTAssertEqual(again["sort"], "distance")
        XCTAssertEqual(again["pages"], "1", "the list starts again from page 1")

        // Another account (the client): its own default sort and its own (caregiver) cards.
        signOutThroughTheApp()
        try signInThroughTheApp(email: clientEmail, password: clientPassword)
        let client = state()
        attach("my-matches-other-account", client)
        XCTAssertTrue(sortButton.label.contains("Distance"), "another account starts from the default sort")
        XCTAssertNotEqual(client["firstName"], caregiverFirst, "the previous account's list is not shown")
        // One page: sort and list kept on return, the loaded pages refreshed quietly.
        try chooseSort("Pay")
        Thread.sleep(forTimeInterval: 2)
        waitForList()
        let before = state()
        let pages = Int(before["pages"] ?? "") ?? 0
        let result = leaveAndReturn("Messages")
        let immediately = state()
        Thread.sleep(forTimeInterval: 3)
        let count = requests() - result.sent
        attach("my-matches-client-one-page", ["before": before, "immediately": immediately, "after": state(), "refreshRequests": count, "loadingWindow": result.loadingWindow])
        XCTAssertTrue(sortButton.label.contains("Pay"))
        XCTAssertEqual(immediately["items"], before["items"])
        XCTAssertEqual(immediately["firstName"], before["firstName"])
        XCTAssertFalse(result.loadingWindow)
        XCTAssertEqual(count, pages, "the loaded page(s) refreshed once each")
    }

    func testOfflineRefreshKeepsTheListAndASortChangeWinsOverALateRefresh() throws {
        // Offline from 75 s to 95 s after launch; every request is slowed by 4 s. The test's clock
        // starts before the app's, so its 77 s and 102 s fall inside and after that window.
        let launched = Date()
        try launch(["--qa-matches-pages", "2", "--qa-offline", "75", "95", "--qa-latency", "4"])
        waitForList(pages: 2, timeout: 90)
        try chooseSort("Pay")
        waitForList(pages: 2, timeout: 90)
        // The QA hook puts a card of page 2 at the top a moment after the pages arrive.
        let placed = NSPredicate { _, _ in !(self.state()["top"] ?? "").isEmpty }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: placed, object: nil)], timeout: 20), .completed)
        Thread.sleep(forTimeInterval: 1)
        let before = state()
        // A refresh while offline: the list stays, no error replaces it.
        while Date().timeIntervalSince(launched) < 77 { Thread.sleep(forTimeInterval: 0.5) }
        let offline = leaveAndReturn("Messages")
        Thread.sleep(forTimeInterval: 8)
        let afterOffline = state()
        attach("my-matches-offline-refresh", ["before": before, "after": afterOffline, "loadingWindow": offline.loadingWindow])
        XCTAssertTrue(sortButton.label.contains("Pay"))
        XCTAssertEqual(afterOffline["items"], before["items"], "the last good list stays")
        XCTAssertEqual(afterOffline["top"], before["top"])
        XCTAssertFalse(offline.loadingWindow)
        XCTAssertFalse(app.buttons["Try Again"].exists, "no error screen instead of the list")
        // Back online: return, and change the sort while the slow quiet refresh is still running.
        while Date().timeIntervalSince(launched) < 102 { Thread.sleep(forTimeInterval: 0.5) }
        // Back by hand (no wait for a loading window) so the sort changes while the refresh runs.
        open("Messages", onMatches: false)
        open("Matches", onMatches: true)
        XCTAssertEqual(state()["revalidating"], "true", "the quiet refresh is running")
        try chooseSort("Distance")
        Thread.sleep(forTimeInterval: 10) // the late Pay answers have arrived by now
        let after = state()
        attach("my-matches-sort-during-refresh", ["payBefore": before, "after": after, "sortLabel": sortButton.label])
        XCTAssertTrue(sortButton.label.contains("Distance"), "the newer sort stays")
        XCTAssertEqual(after["sort"], "distance")
        XCTAssertEqual(after["pages"], "2", "the Distance list (2 pages by the QA hook), not the Pay list put back")
        XCTAssertNotEqual(after["firstName"], before["firstName"], "the Pay list did not come back over the Distance list")

        // Empty list (simulated with --qa-empty-matches: no QA account has zero matches).
        app.terminate()
        app.launchArguments = ["--qa-request-counts", "--qa-tab", "matches", "--qa-empty-matches", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let empty = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "All Matches (0)")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 60), "the empty state")
        let result = leaveAndReturn("Messages")
        XCTAssertFalse(result.loadingWindow, "no loading window over the empty state on return")
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "the empty state stays")
        attach("my-matches-empty", ["state": state()])
    }
}
