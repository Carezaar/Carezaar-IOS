import XCTest

/// P04-032: scoped owned-pair bookmark persistence, not arbitrary match cards.
/// Future runner execution restores the original state even when assertions fail.
final class FavoritePersistenceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app?.terminate() }

    private struct Fixture {
        let email: String
        let password: String
        let token: String
        let partnerID: String
        let endpoint: String
        let route: String
        let partnerName: String
        let initialFavorite: Bool
    }

    private func fixture() throws -> Fixture {
        guard let email = env["QA_EMAIL"], !email.isEmpty,
              let password = env["QA_PASSWORD"], !password.isEmpty,
              let clientID = env["QA_CLIENT_USER_ID"], !clientID.isEmpty,
              let caregiverID = env["QA_CG_ID"], !caregiverID.isEmpty else {
            throw XCTSkip("Retained owned pair IDs and primary credentials required")
        }
        let token = try CarezaarAPI.login(email, password)
        XCTAssertFalse(token.isEmpty)
        let me = try CarezaarAPI.me(token)
        let id = me["id"].map { String(describing: $0) } ?? ""
        let role = me["role"] as? String
        let partnerID: String, endpoint: String, route: String, partnerRole: String
        if id == clientID && role == "client" {
            partnerID = caregiverID; endpoint = "clients/caregivers/\(partnerID)"
            route = "CaregiverDetails/\(partnerID)"; partnerRole = "caregiver"
        } else if id == caregiverID && role == "caregiver" {
            partnerID = clientID; endpoint = "caregivers/clients/\(partnerID)"
            route = "ClientDetails/\(partnerID)"; partnerRole = "client"
        } else {
            XCTFail("Primary fixture identity/role does not match retained pair")
            throw URLError(.userAuthenticationRequired)
        }
        let response = try CarezaarAPI.callWithHTTPStatus("GET", endpoint, token: token)
        XCTAssertTrue((200..<300).contains(response.status))
        let profile = CarezaarAPI.result(response.body)
        guard let user = profile["user"] as? [String: Any],
              user["id"].map({ String(describing: $0) }) == partnerID,
              user["role"] as? String == partnerRole,
              let initial = user["is_favorite"] as? Bool else {
            XCTFail("Profile must prove exact owned counterpart identity, role and bookmark state")
            throw URLError(.cannotParseResponse)
        }
        let name = [user["first_name"] as? String, user["last_name"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertFalse(name.isEmpty)
        return Fixture(email: email, password: password, token: token, partnerID: partnerID,
                       endpoint: endpoint, route: route, partnerName: name, initialFavorite: initial)
    }

    private func favorite(_ f: Fixture) throws -> Bool {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", f.endpoint, token: f.token)
        guard (200..<300).contains(response.status),
              let user = CarezaarAPI.result(response.body)["user"] as? [String: Any],
              user["id"].map({ String(describing: $0) }) == f.partnerID,
              let on = user["is_favorite"] as? Bool else {
            throw URLError(.cannotParseResponse)
        }
        return on
    }
    private func waitForBackend(_ expected: Bool, fixture f: Fixture) throws {
        for attempt in 0..<8 {
            if try favorite(f) == expected { return }
            if attempt < 7 { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTFail("Owned partner bookmark did not persist to backend")
    }
    private func count(_ key: String) -> Int {
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 5))
        let prefix = key + "="
        return ledger.label.split(separator: "\n").first { $0.hasPrefix(prefix) }
            .flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
    }
    private func toggle(to expected: Bool, fixture f: Fixture) throws {
        let action = app.navigationBars.buttons[expected ? "Add to favorites" : "Remove from favorites"]
        // Actual failed recording shows startup/profile/favorites busy overlay:
        // the toolbar exists underneath before the native control is tappable.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            action.exists && action.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed,
                       "Owned profile bookmark must become genuinely tappable after loading")
        action.tap()
        try waitForBackend(expected, fixture: f)
        let resulting = app.navigationBars.buttons[expected ? "Remove from favorites" : "Add to favorites"]
        XCTAssertTrue(resulting.waitForExistence(timeout: 10), "Rendered bookmark state must agree with persisted backend")
    }

    func testOwnedPartnerFavoritePersistsAcrossFavoritesAndProfileReopen() throws {
        let f = try fixture()
        var nativeAttempted = false
        defer {
            if nativeAttempted {
                do {
                    let current = try favorite(f)
                    if current != f.initialFavorite {
                        let response = try CarezaarAPI.callWithHTTPStatus(
                            f.initialFavorite ? "POST" : "DELETE",
                            f.initialFavorite ? "users/bookmarks" : "users/bookmarks/\(f.partnerID)",
                            form: f.initialFavorite ? ["partner_id": f.partnerID] : [:], token: f.token)
                        XCTAssertTrue((200..<300).contains(response.status), "Owned bookmark restoration was refused")
                    }
                    XCTAssertEqual(try favorite(f), f.initialFavorite, "Original owned bookmark state must be restored")
                } catch { XCTFail("Owned fixture bookmark restoration failed; investigate before further mutation") }
            }
        }
        app.launchEnvironment["QA_EMAIL"] = f.email; app.launchEnvironment["QA_PASSWORD"] = f.password
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", "Favorites,\(f.route)",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let initialAction = app.navigationBars.buttons[f.initialFavorite ? "Remove from favorites" : "Add to favorites"]
        XCTAssertTrue(initialAction.waitForExistence(timeout: 45), "Native initial bookmark must match backend preflight")
        nativeAttempted = true
        try toggle(to: !f.initialFavorite, fixture: f)
        if f.initialFavorite { try toggle(to: true, fixture: f) }
        XCTAssertEqual(count("POST /api/users/bookmarks"), 1, "Exactly one owned native add request")
        app.navigationBars.buttons["Favorites"].tap()
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", f.partnerName)).firstMatch
        for _ in 0..<8 where !card.isHittable { app.swipeUp() }
        XCTAssertTrue(card.exists && card.isHittable, "Persisted owned partner must appear in reopened Favorites")
        card.tap()
        XCTAssertTrue(app.navigationBars.buttons["Remove from favorites"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", f.partnerName)).firstMatch.exists,
                      "Favorites card must open the correct owned partner")
        XCTAssertEqual(count("GET /api/\(f.endpoint)"), 2, "Card must reopen that exact partner endpoint")
        try waitForBackend(true, fixture: f)
        try toggle(to: false, fixture: f)
        app.navigationBars.buttons["Favorites"].tap()
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 10), .completed,
                       "Unbookmarked partner must disappear from existing Favorites list")
        try waitForBackend(false, fixture: f)
        XCTAssertEqual(count("DELETE /api/users/bookmarks/\(f.partnerID)"), f.initialFavorite ? 2 : 1)
        let record: [String: Any] = ["case": "P04-032", "ownedPairIdentityVerified": true,
            "initialFavorite": f.initialFavorite, "nativeAddRequests": 1,
            "nativeRemoveRequests": f.initialFavorite ? 2 : 1, "profileOpenGETs": 2,
            "favoriteBackendVerified": true, "correctPartnerReopened": true,
            "removedCardAbsent": true, "originalStateRestoration": "defer_verified_separately"]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "P04-032-owned-favorite-persistence"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
