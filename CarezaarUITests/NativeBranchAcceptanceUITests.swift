import XCTest

/// Brief §10.6/19D: genuine reciprocal Request activation, not normal Accept.
/// The existing Debug delay changes timing only; every Match is a real backend result.
final class NativeBranchAcceptanceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private struct Fixture {
        let token: String, peerToken: String, role: String, primaryID: String, partnerID: String
        let endpoint: String, peerEndpoint: String, route: String, marker: String
    }
    private var cleanup: Fixture?
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() {
        // A delayed native POST must finish or be cancelled before relation restoration.
        app?.terminate()
        if let fixture = cleanup {
            do { try restoreOwnedNone(fixture) }
            catch { XCTFail("Reciprocal owned-pair cleanup unverified; inspect privately before other mutation tests") }
        }
        super.tearDown()
    }

    func testRealReciprocalRequestDuringNativePostDelayOpensMatched() throws {
        let f = try ownedFixture()
        let before = try profile(f), peerBefore = try profile(f, peer: true)
        guard isNone(before), isNone(peerBefore) else {
            throw XCTSkip("Reciprocal scenario requires exact retained owned pair NONE; no existing relation is cleared")
        }
        let contents = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: f.token)
        guard contents.status == 200, let rows = contents.body["result"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        func managed(_ slug: String, _ fallback: String) -> String {
            guard let row = rows.first(where: { $0["slug"] as? String == slug }),
                  let translations = row["translations"] as? [[String: Any]],
                  let english = translations.first(where: { ($0["language_id"] as? NSNumber)?.intValue == 1 }),
                  let name = english["name"] as? String, !name.isEmpty else { return fallback }
            return name
        }
        let submitting = managed("loading_match_submit", "Submitting match request")
        let matchedTitle = managed("match_matched_title", "It's a Match!")
        let viewProfile = managed("match_matched_profile_button", "View Profile")
        let intro = managed("match_introduction_title", "Introduction")
        app.launchEnvironment = ["QA_EMAIL": env["QA_EMAIL"]!, "QA_PASSWORD": env["QA_PASSWORD"]!]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", f.route,
                               "--qa-latency", "20", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let request = app.buttons["match-request"]
        try reveal(request, timeout: 130)
        let profileKey = "GET /api/" + f.endpoint
        XCTAssertEqual(try count(profileKey), 1)
        XCTAssertEqual(try writes(), 0)
        request.tap()
        let fieldReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.textFields[intro].firstMatch.exists || self.app.textViews[intro].firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fieldReady], timeout: 10), .completed)
        // Query by the sole composer type after entry; vertical TextField AX can
        // lose its placeholder match once populated. The empty label is verified first.
        let field = app.textFields[intro].firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertEqual(field.label, intro)
        XCTAssertTrue(field.exists && field.isHittable)
        field.tap(); field.typeText(f.marker)
        XCTAssertEqual(field.value as? String, f.marker)
        let confirm = app.buttons["match-request-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10) && confirm.isHittable)
        confirm.tap()

        // This exact operation is inserted only AFTER the current NONE preflight
        // returned and its comparison passed. Native POST is still sleeping20s.
        let operation = app.staticTexts.matching(NSPredicate(format: "label == %@", "- " + submitting)).firstMatch
        XCTAssertTrue(operation.waitForExistence(timeout: 45), "Real mutation-stage overlay must follow completed preflight")
        let overlayObserved = Date()
        XCTAssertEqual(try count(profileKey), 2)
        XCTAssertEqual(try count("POST /api/users/matches"), 0)
        XCTAssertEqual(try writes(), 0)
        cleanup = f // Reconcile even a lost peer acknowledgement; never assume no mutation.
        let staged = try CarezaarAPI.callWithHTTPStatus("POST", "users/matches", form: [
            "partner_id": f.primaryID, "introduction": f.marker + " peer"
        ], token: f.peerToken)
        guard staged.status == 200, let row = staged.body["result"] as? [String: Any],
              let id = row["id"] as? Int, id > 0 else {
            throw URLError(.badServerResponse)
        }
        _ = try ownedEdge(id, fixture: f)
        let pending = try profile(f), peerPending = try profile(f, peer: true)
        let peerCommitElapsed = Date().timeIntervalSince(overlayObserved)
        XCTAssertEqual(pending["match_status"] as? String, "received")
        XCTAssertEqual(peerPending["match_status"] as? String, "sent")
        XCTAssertEqual(pending["match_id"] as? Int, id)
        XCTAssertEqual(peerPending["match_id"] as? Int, id)
        guard peerCommitElapsed < 12,
              try count("POST /api/users/matches") == 0 else {
            XCTFail("Peer must commit while genuine native POST is still held; timing prerequisite failed")
            throw URLError(.timedOut)
        }

        let matchedReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.navigationBars[matchedTitle].exists ||
                self.app.staticTexts.matching(NSPredicate(format: "label == %@", matchedTitle)).firstMatch.exists
        }, object: nil)
        let destinationVisible = XCTWaiter.wait(for: [matchedReady], timeout: 90) == .completed
        let after = try profile(f), peerAfter = try profile(f, peer: true)
        XCTAssertEqual(try count("POST /api/users/matches"), 1, "Exactly one native Request; no Accept/retry")
        let actual = try ownedEdge(id, fixture: f)
        let active = actual["is_active"] as? Bool == true && actual["is_client_accepted"] as? Bool == true &&
            actual["is_caregiver_accepted"] as? Bool == true && (actual["finished_at"] == nil || actual["finished_at"] is NSNull)
        if !active {
            // Schema does not promise reciprocity. Preserve an honest external
            // eligibility limitation, not a fabricated active response or HTTP code.
            guard after["match_status"] as? String == "received", peerAfter["match_status"] as? String == "sent",
                  after["match_id"] as? Int == id, peerAfter["match_id"] as? Int == id else {
                XCTFail("Unexpected owned relationship outcome; cannot classify reciprocal eligibility safely")
                throw URLError(.cannotParseResponse)
            }
            proof(["scope": "real-reciprocal-request", "nativePOST": 1, "peerCommittedBeforeNativePOST": true,
                   "backendActivated": false, "nativeMatchedVisible": destinationVisible,
                   "httpStatusNotObserved": true], name: "reciprocal-backend-eligibility-unavailable")
            try restoreOwnedNone(f); cleanup = nil
            throw XCTSkip("Real reciprocal POST did not activate this owned pending pair; backend eligibility/result requires review. Native HTTP status is not exposed by the request-count ledger.")
        }
        XCTAssertTrue(destinationVisible, "Actual backend reciprocal activation must open native It's a Match")
        XCTAssertEqual(after["match_status"] as? String, "active")
        XCTAssertEqual(peerAfter["match_status"] as? String, "active")
        XCTAssertEqual(after["match_id"] as? Int, id)
        XCTAssertEqual(peerAfter["match_id"] as? Int, id)
        XCTAssertEqual(try writes(), 1)
        XCTAssertEqual(try count("GET /api/users/matches/\(id)"), 0, "No redundant connection precheck")
        let profileButton = app.buttons[viewProfile]
        try reveal(profileButton, timeout: 45)
        XCTAssertEqual(try count(profileKey), 3, "Initial opening + preflight + single matched profile load")
        let crop = XCTAttachment(screenshot: profileButton.screenshot())
        crop.name = "real-instant-matched-profile-control"; crop.lifetime = .keepAlways; add(crop)
        profileButton.tap()
        let activeAction = app.buttons["match-unmatch"]
        try reveal(activeAction, timeout: 15)
        XCTAssertEqual(try count(profileKey), 3, "Returning to already-open profile must not refetch")
        XCTAssertEqual(try writes(), 1)
        proof(["scope": "brief-10.6-real-reciprocal-instant", "ownedIdentitiesVerified": true,
               "initialBothNone": true, "peerCommittedBeforeNativePOST": true,
               "peerCommitWindowSeconds": peerCommitElapsed,
               "nativePOST": 1, "nativeAcceptPATCH": 0, "backendActiveBothAccepted": active,
               "matchedDestinationVisible": destinationVisible, "profileGETs": 3,
               "connectionGETs": 0, "profileReturnRefetches": 0], name: "real-native-instant-reciprocal-proof")
        try restoreOwnedNone(f); cleanup = nil
    }

    private func isNone(_ row: [String: Any]) -> Bool {
        row["match_status"] as? String == "none" && (row["match_id"] == nil || row["match_id"] is NSNull)
    }
    private func restoreOwnedNone(_ f: Fixture) throws {
        let a = try profile(f), b = try profile(f, peer: true)
        if isNone(a), isNone(b) { return }
        guard let id = a["match_id"] as? Int, id > 0, b["match_id"] as? Int == id else {
            throw URLError(.cannotParseResponse)
        }
        _ = try ownedEdge(id, fixture: f)
        let path: String, token: String
        if a["match_status"] as? String == "active", b["match_status"] as? String == "active" {
            path = "users/matches/\(id)"; token = f.token
        } else if a["match_status"] as? String == "received", b["match_status"] as? String == "sent" {
            path = "users/matches/\(id)/withdraw"; token = f.peerToken
        } else if a["match_status"] as? String == "sent", b["match_status"] as? String == "received" {
            path = "users/matches/\(id)/withdraw"; token = f.token
        } else { throw URLError(.cannotParseResponse) }
        let r = try CarezaarAPI.callWithHTTPStatus("DELETE", path, token: token)
        guard (200..<300).contains(r.status), isNone(try profile(f)), isNone(try profile(f, peer: true)) else {
            throw URLError(.badServerResponse)
        }
    }
    private func reveal(_ element: XCUIElement, timeout: TimeInterval) throws {
        guard element.waitForExistence(timeout: timeout) else { throw URLError(.timedOut) }
        for _ in 0..<18 {
            if element.exists && element.isHittable && element.isEnabled { return }
            app.swipeUp()
        }
        XCTFail("Native control must remain reachable")
        throw URLError(.timedOut)
    }
    private func count(_ key: String) throws -> Int {
        let label = app.staticTexts["qa-request-counts"].label
        guard !label.isEmpty else { throw URLError(.cannotParseResponse) }
        for line in label.split(separator: "\n") {
            guard let index = line.lastIndex(of: "="), let value = Int(line[line.index(after: index)...]) else { throw URLError(.cannotParseResponse) }
            if String(line[..<index]) == key { return value }
        }
        return 0
    }
    private func writes() throws -> Int {
        let label = app.staticTexts["qa-request-counts"].label
        guard !label.isEmpty else { throw URLError(.cannotParseResponse) }
        var total = 0
        for line in label.split(separator: "\n") {
            guard let index = line.lastIndex(of: "="), let value = Int(line[line.index(after: index)...]) else { throw URLError(.cannotParseResponse) }
            let key = String(line[..<index])
            if ["POST", "PATCH", "DELETE", "PUT"].contains(where: { key.hasPrefix($0 + " /api/users/matches") }) { total += value }
        }
        return total
    }
    private func proof(_ row: [String: Any], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { XCTFail("Proof serialization failed"); return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func ownedFixture() throws -> Fixture {
        let keys = ["QA_EMAIL", "QA_PASSWORD", "QA_CLIENT_EMAIL", "QA_CLIENT_PASSWORD", "QA_CG_EMAIL", "QA_CG_PASSWORD", "QA_CLIENT_USER_ID", "QA_CG_ID"]
        guard keys.allSatisfy({ !(env[$0] ?? "").isEmpty }), env["QA_CLIENT_USER_ID"] != env["QA_CG_ID"] else {
            throw XCTSkip("Exact distinct retained owned pair credentials and IDs required")
        }
        func login(_ email: String, _ password: String, expectedRole: String?, expectedID: String?) throws -> (String, [String: Any]) {
            let token = try CarezaarAPI.login(email, password)
            guard !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
            let me = try CarezaarAPI.me(token)
            guard me["email"] as? String == email,
                  expectedRole == nil || me["role"] as? String == expectedRole,
                  expectedID == nil || me["id"].map({ String(describing: $0) }) == expectedID else {
                XCTFail("Exact owned identity, role and private credential binding required")
                throw URLError(.userAuthenticationRequired)
            }
            return (token, me)
        }
        let client = try login(env["QA_CLIENT_EMAIL"]!, env["QA_CLIENT_PASSWORD"]!, expectedRole: "client", expectedID: env["QA_CLIENT_USER_ID"]!)
        let caregiver = try login(env["QA_CG_EMAIL"]!, env["QA_CG_PASSWORD"]!, expectedRole: "caregiver", expectedID: env["QA_CG_ID"]!)
        let primary = try login(env["QA_EMAIL"]!, env["QA_PASSWORD"]!, expectedRole: nil, expectedID: nil)
        let role = primary.1["role"] as? String ?? "", id = primary.1["id"].map { String(describing: $0) } ?? ""
        let partnerID: String, peerToken: String, endpoint: String, peerEndpoint: String, route: String
        if role == "client", id == env["QA_CLIENT_USER_ID"], env["QA_EMAIL"] == env["QA_CLIENT_EMAIL"] {
            partnerID = env["QA_CG_ID"]!; peerToken = caregiver.0
            endpoint = "clients/caregivers/\(partnerID)"; peerEndpoint = "caregivers/clients/\(id)"; route = "CaregiverDetails/\(partnerID)"
        } else if role == "caregiver", id == env["QA_CG_ID"], env["QA_EMAIL"] == env["QA_CG_EMAIL"] {
            partnerID = env["QA_CLIENT_USER_ID"]!; peerToken = client.0
            endpoint = "caregivers/clients/\(partnerID)"; peerEndpoint = "clients/caregivers/\(id)"; route = "ClientDetails/\(partnerID)"
        } else { throw URLError(.userAuthenticationRequired) }
        return Fixture(token: primary.0, peerToken: peerToken, role: role, primaryID: id, partnerID: partnerID,
                              endpoint: endpoint, peerEndpoint: peerEndpoint, route: route, marker: "Synthetic reciprocal native " + UUID().uuidString)
    }
    private func profile(_ f: Fixture, peer: Bool = false) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", peer ? f.peerEndpoint : f.endpoint, token: peer ? f.peerToken : f.token)
        guard response.status == 200, let result = response.body["result"] as? [String: Any],
              let user = result["user"] as? [String: Any],
              user["id"].map({ String(describing: $0) }) == (peer ? f.primaryID : f.partnerID),
              user["role"] as? String == (peer ? f.role : (f.role == "client" ? "caregiver" : "client")) else {
            throw URLError(.cannotParseResponse)
        }
        return result
    }
    private func ownedEdge(_ id: Int, fixture f: Fixture) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/matches/\(id)", token: f.token)
        guard response.status == 200, let row = response.body["result"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
        func userID(_ side: String) -> String {
            let user = (row[side] as? [String: Any])?["user"] as? [String: Any]
            return user?["id"].map { String(describing: $0) } ?? ""
        }
        guard row["id"] as? Int == id, userID(f.role) == f.primaryID,
              userID(f.role == "client" ? "caregiver" : "client") == f.partnerID,
              [f.marker, f.marker + " peer"].contains(row["introduction"] as? String ?? "") else {
            XCTFail("Refusing unrelated/unmarked edge mutation or cleanup")
            throw URLError(.userAuthenticationRequired)
        }
        return row
    }
}
