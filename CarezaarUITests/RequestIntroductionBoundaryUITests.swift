import XCTest
import Foundation

/// Bounded introduction/form portions of P23-001/P23-006 and P23-014/P23-015.
/// Brief §12.3 preserves the full first literal line; old web 80-character slicing
/// is explicitly NOT an expectation. Raster ellipsis still requires root review.
/// No P09 network, P10 lifecycle, P11 permissions or history coverage is inferred.
final class RequestIntroductionBoundaryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private let marker = "Synthetic intro " + UUID().uuidString
    private var cleanupFixture: Fixture?
    private var stagedID: Int?
    private var stagedIntroduction: String?

    private struct Fixture {
        let primaryToken: String, peerToken: String
        let role: String, primaryID: String, peerID: String, peerName: String
        let labels: [String: String]
        var profileEndpoint: String { "\(role == "client" ? "clients/caregivers" : "caregivers/clients")/\(peerID)" }
        var peerEndpoint: String { "\(role == "client" ? "caregivers/clients" : "clients/caregivers")/\(primaryID)" }
        var listEndpoint: String { "\(role == "client" ? "clients" : "caregivers")/matches" }
        func label(_ slug: String, _ fallback: String) -> String {
            guard let value = labels[slug], !value.isEmpty else { return fallback }; return value
        }
    }

    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() {
        app?.terminate()
        if let f = cleanupFixture {
            do {
                // A server may commit POST before its response is lost or
                // decoded. Missing local ID is not evidence of no mutation.
                if let id = try stagedID ?? reconcileOwnedIncomingForCleanup(f) {
                    try withdrawOwnedIncoming(id, fixture: f)
                }
            }
            catch { XCTFail("Owned introduction cleanup failed; inspect retained pair before next allocation") }
        }
        super.tearDown()
    }

    func testOwnedRequestOptionalEmptyCancelAndLongFirstLineFullIntroductionModal() throws {
        let f = try preflight()
        let initial = try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)
        let other = try profile(f.peerEndpoint, token: f.peerToken, expectedUser: f.primaryID)
        guard initial["match_status"] as? String == "none", other["match_status"] as? String == "none" else {
            throw XCTSkip("Introduction boundaries require exact owned pair initially NONE; preserve existing relationship")
        }
        launch((f.role == "client" ? "CaregiverDetails/" : "ClientDetails/") + f.peerID)
        let request = app.buttons["match-request"]
        XCTAssertTrue(request.waitForExistence(timeout: 45))
        try tapWhenReady(request)
        let title = f.label("match_match_button", "Request a Match")
        let heading = app.staticTexts["match-request-heading"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertEqual(heading.label, title)
        let question = f.label("match_match_message", "Are you sure you want to match with this user? They should accept your request.")
        let questionText = app.staticTexts.matching(NSPredicate(format: "label == %@", question)).firstMatch
        XCTAssertTrue(questionText.exists, "Exact independent managed request confirmation required")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.exists)
        XCTAssertEqual(field.label, f.label("match_introduction_title", "Introduction"))
        let placeholder = f.label("match_introduction_message", "You can introduce yourself here (Optional)")
        XCTAssertTrue((field.value as? String) == placeholder || (field.value as? String) == "",
                      "Optional introduction starts empty, without a synthetic default")
        let confirm = app.buttons["match-request-confirm"]
        XCTAssertTrue(confirm.exists && confirm.isEnabled)
        XCTAssertEqual(confirm.label, f.label("match_match_title", "Match"))
        controlProof(questionText, "managed-request-question-only")
        let cancel = app.buttons["match-request-dismiss"]
        XCTAssertEqual(cancel.label, f.label("general_cancel", "Cancel"))
        XCTAssertTrue(cancel.exists && cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        XCTAssertFalse(heading.exists)
        XCTAssertEqual(count("POST /api/users/matches"), 0, "Cancel of optional empty introduction must not submit")
        XCTAssertEqual(try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)["match_status"] as? String, "none")
        XCTAssertEqual(try profile(f.peerEndpoint, token: f.peerToken, expectedUser: f.primaryID)["match_status"] as? String, "none")
        try record("optional-empty-request-cancel-\(f.role)", ["role": f.role,
            "exactManagedQuestionObserved": true, "emptyOptionalIntroductionConfirmEnabled": true,
            "cancelNativePOSTs": 0, "bothProfilesRemainNone": true,
            "emptyIntroductionSubmissionCovered": false])

        // A late first-line sentinel lies beyond the old 80-character boundary.
        // The many following short lines force real scrolling on both devices.
        let firstLine = marker + " " + String(repeating: "A", count: 100) + " AFTER80_SENTINEL"
        let lines = (1...30).map { String(format: "Synthetic full line %02d", $0) }
        let full = ([firstLine] + lines + ["FULL_INTRODUCTION_END"]).joined(separator: "\n")
        XCTAssertGreaterThan(firstLine.count, 80)
        XCTAssertLessThanOrEqual(full.count, 1000)
        cleanupFixture = f
        stagedIntroduction = full
        let created = try CarezaarAPI.callWithHTTPStatus("POST", "users/matches",
            form: ["partner_id": f.primaryID, "introduction": full], token: f.peerToken)
        XCTAssertTrue((200..<300).contains(created.status))
        stagedID = try XCTUnwrap((created.body["result"] as? [String: Any])?["id"] as? Int)
        let id = try XCTUnwrap(stagedID)
        _ = try ownedIncoming(id, fixture: f)

        // Require exact pending record on the same first page native loads.
        let list = try CarezaarAPI.callWithHTTPStatus("GET", "users/matches?type=requests&page=1&perPage=10", token: f.primaryToken)
        XCTAssertEqual(list.status, 200)
        let rows = try XCTUnwrap(list.body["result"] as? [[String: Any]])
        guard rows.contains(where: { $0["id"] as? Int == id }) else {
            throw XCTSkip("Exact owned request excluded from native first page; no fabricated preview")
        }
        launch("ManageMatches")
        let requests = app.buttons[f.label("match_tab_requests", "Requests")].firstMatch
        XCTAssertTrue(requests.waitForExistence(timeout: 45))
        try tapWhenReady(requests)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in requests.isSelected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
        let preview = app.buttons["match-introduction-\(id)"]
        XCTAssertTrue(preview.waitForExistence(timeout: 30))
        let introTitle = f.label("match_introduction_title", "Introduction")
        XCTAssertEqual(preview.label, introTitle + ": " + firstLine,
                       "AX must preserve complete literal first line, including characters beyond 80")
        XCTAssertFalse(preview.label.contains("\n"))
        XCTAssertFalse(preview.label.contains(lines[0]))
        // Identifier subscripting rejects strings longer than 128 characters;
        // these are exact labels, so use a bound equality predicate instead.
        let textLine = preview.staticTexts.matching(NSPredicate(format: "label == %@", firstLine)).firstMatch
        XCTAssertTrue(textLine.exists, "Actual preview text must retain full first literal line")
        controlProof(preview, "long-first-line-preview-raster-review-\(f.role)")
        // SwiftUI may give the Text AX node the containing 44pt hit rectangle;
        // that rectangle cannot establish the number of rendered glyph lines.
        // Check containment/reachability here and retain the crop for actual
        // single-line/ellipsis raster review instead of imposing a font cutoff.
        XCTAssertGreaterThanOrEqual(preview.frame.height, 44)
        XCTAssertTrue(preview.frame.insetBy(dx: -1, dy: -1).contains(textLine.frame),
                      "Full-label preview text AX frame must remain inside its actual control")
        let previewControlHeight = Double(preview.frame.height)
        let previewTextAXHeight = Double(textLine.frame.height)
        let beforeProfileGET = count("GET /api/" + f.profileEndpoint)
        try tapWhenReady(preview)
        let modal = app.scrollViews["match-introduction-detail"]
        XCTAssertTrue(modal.waitForExistence(timeout: 10))
        XCTAssertTrue(modal.staticTexts.matching(NSPredicate(format: "label == %@", f.peerName)).firstMatch.exists,
                      "Full modal must contain exact owned partner name")
        let fullText = modal.staticTexts.matching(NSPredicate(format: "label == %@", full)).firstMatch
        XCTAssertTrue(fullText.exists, "Full exact backend introduction must remain accessible without slicing")
        XCTAssertGreaterThan(fullText.frame.height, modal.frame.height / 2)
        let initialY = fullText.frame.minY
        for _ in 0..<18 {
            if fullText.frame.maxY <= modal.frame.maxY - 4 && fullText.frame.maxY > modal.frame.minY { break }
            modal.swipeUp(velocity: .slow)
        }
        XCTAssertLessThan(fullText.frame.minY, initialY - 20, "Actual modal content must scroll")
        XCTAssertLessThanOrEqual(fullText.frame.maxY, modal.frame.maxY + 2, "Full introduction end must reach visible viewport")
        XCTAssertGreaterThan(fullText.frame.maxY, modal.frame.minY)
        XCTAssertEqual(count("GET /api/" + f.profileEndpoint), beforeProfileGET,
                       "Introduction preview must not navigate/fetch partner profile")
        XCTAssertFalse(app.buttons["match-accept"].exists)
        let close = modal.buttons[f.label("general_cancel", "Cancel")]
        for _ in 0..<18 {
            if close.exists && close.isHittable && modal.frame.contains(close.frame) { break }
            modal.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(close.exists && close.isHittable && modal.frame.contains(close.frame))
        controlProof(close, "full-introduction-close-control-only")
        close.tap()
        XCTAssertFalse(modal.exists)
        XCTAssertTrue(preview.exists)
        XCTAssertEqual(count("POST /api/users/matches"), 0)
        _ = try ownedIncoming(id, fixture: f)
        try record("full-first-line-introduction-modal-\(f.role)", ["role": f.role,
            "firstLiteralLineCharacters": firstLine.count, "firstLineLateSentinelPreservedInAX": true,
            "oldWeb80CharacterSlicingExpected": false, "currentBriefSection": "12.3",
            "previewTextAXContainedInControl": true,
            "previewControlHeight": previewControlHeight, "previewTextAXHeight": previewTextAXHeight,
            "renderedLineCountInferredFromAXHeight": false, "visualEllipsisRequiresRasterReview": true,
            "fullBackendBodyAndModalAXExactlyEqual": true, "modalScrolledToEndAndClosed": true,
            "noProfileNavigationGET": true, "pendingStateUnchanged": true,
            "photoRasterAndLiveVoiceOverCoverageClaimed": false])
        try withdrawOwnedIncoming(id, fixture: f)
        stagedID = nil; cleanupFixture = nil
    }

    private func ownedIncoming(_ id: Int, fixture f: Fixture) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/matches/\(id)", token: f.primaryToken)
        XCTAssertEqual(response.status, 200)
        let row = try XCTUnwrap(response.body["result"] as? [String: Any])
        func identity(_ side: String) -> String {
            ((row[side] as? [String: Any])?["user"] as? [String: Any])?["id"].map { String(describing: $0) } ?? ""
        }
        guard row["id"] as? Int == id, stagedID == id,
              identity(f.role) == f.primaryID,
              identity(f.role == "client" ? "caregiver" : "client") == f.peerID,
              row["introduction"] as? String == stagedIntroduction,
              (row["introduction"] as? String)?.hasPrefix(marker) == true else {
            XCTFail("Refusing to touch an edge outside exact owned pair and this run's marked introduction")
            throw URLError(.userAuthenticationRequired)
        }
        let primary = try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)
        let peer = try profile(f.peerEndpoint, token: f.peerToken, expectedUser: f.primaryID)
        guard primary["match_status"] as? String == "received",
              peer["match_status"] as? String == "sent",
              primary["match_id"] as? Int == id, peer["match_id"] as? Int == id,
              primary["is_match"] as? Bool == false, peer["is_match"] as? Bool == false else {
            throw URLError(.userAuthenticationRequired)
        }
        return row
    }

    /// Reconciliation reads only the exact authorized pair, then adopts an ID
    /// solely when both public profiles and the full marked edge agree.
    private func reconcileOwnedIncomingForCleanup(_ f: Fixture) throws -> Int? {
        guard let expected = stagedIntroduction, expected.hasPrefix(marker) else {
            throw URLError(.userAuthenticationRequired)
        }
        let primary = try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)
        let peer = try profile(f.peerEndpoint, token: f.peerToken, expectedUser: f.primaryID)
        if primary["match_status"] as? String == "none", peer["match_status"] as? String == "none",
           primary["is_match"] as? Bool == false, peer["is_match"] as? Bool == false { return nil }
        guard primary["match_status"] as? String == "received",
              peer["match_status"] as? String == "sent",
              primary["is_match"] as? Bool == false, peer["is_match"] as? Bool == false,
              let id = primary["match_id"] as? Int, id > 0, peer["match_id"] as? Int == id else {
            throw URLError(.userAuthenticationRequired)
        }
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/matches/\(id)", token: f.primaryToken)
        guard response.status == 200, let row = response.body["result"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        func identity(_ side: String) -> String {
            ((row[side] as? [String: Any])?["user"] as? [String: Any])?["id"].map { String(describing: $0) } ?? ""
        }
        guard row["id"] as? Int == id,
              identity(f.role) == f.primaryID,
              identity(f.role == "client" ? "caregiver" : "client") == f.peerID,
              row["introduction"] as? String == expected else {
            throw URLError(.userAuthenticationRequired)
        }
        stagedID = id
        return id // withdrawOwnedIncoming revalidates all guards before DELETE
    }

    private func withdrawOwnedIncoming(_ id: Int, fixture f: Fixture) throws {
        _ = try ownedIncoming(id, fixture: f)
        let status = try deleteOwnedEdge("users/matches/\(id)/withdraw", token: f.peerToken)
        XCTAssertTrue((200..<300).contains(status))
        XCTAssertEqual(try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)["match_status"] as? String, "none")
        XCTAssertEqual(try profile(f.peerEndpoint, token: f.peerToken, expectedUser: f.primaryID)["match_status"] as? String, "none")
    }
    private func launch(_ route: String) {
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", route,
            "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
    }
    private func tapWhenReady(_ element: XCUIElement) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && element.isHittable && !self.app.staticTexts["Please wait..."].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    private func count(_ key: String) -> Int {
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.exists)
        let prefix = key + "="
        return ledger.label.split(separator: "\n").first { $0.hasPrefix(prefix) }.flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
    }
    private func controlProof(_ element: XCUIElement, _ name: String) {
        let proof = XCTAttachment(screenshot: element.screenshot())
        proof.name = name; proof.lifetime = .keepAlways; add(proof)
    }
    private func record(_ name: String, _ values: [String: Any]) throws {
        let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        proof.name = name; proof.lifetime = .keepAlways; add(proof)
    }

    private func preflight() throws -> Fixture {
        let required = ["QA_EMAIL", "QA_PASSWORD", "QA_CLIENT_EMAIL", "QA_CLIENT_PASSWORD",
                        "QA_CG_EMAIL", "QA_CG_PASSWORD", "QA_CLIENT_USER_ID", "QA_CG_ID"]
        guard required.allSatisfy({ !(env[$0] ?? "").isEmpty }) else {
            throw XCTSkip("Explicit primary plus both retained owned role credentials/IDs required")
        }
        let clientID = env["QA_CLIENT_USER_ID"]!, caregiverID = env["QA_CG_ID"]!
        XCTAssertTrue(clientID != caregiverID)
        func auth(_ email: String, _ password: String, role: String, id: String) throws -> (String, [String: Any]) {
            let token = try CarezaarAPI.login(email, password)
            let user = try CarezaarAPI.me(token)
            guard !token.isEmpty, user["role"] as? String == role,
                  user["id"].map({ String(describing: $0) }) == id,
                  user["email"] as? String == email else {
                XCTFail("Mutation fixture failed exact private role/email/user-ID authorization")
                throw URLError(.userAuthenticationRequired)
            }
            return (token, user)
        }
        let client = try auth(env["QA_CLIENT_EMAIL"]!, env["QA_CLIENT_PASSWORD"]!, role: "client", id: clientID)
        let caregiver = try auth(env["QA_CG_EMAIL"]!, env["QA_CG_PASSWORD"]!, role: "caregiver", id: caregiverID)
        let primaryToken = try CarezaarAPI.login(env["QA_EMAIL"]!, env["QA_PASSWORD"]!)
        let primary = try CarezaarAPI.me(primaryToken)
        let role = primary["role"] as? String ?? ""
        let id = primary["id"].map { String(describing: $0) } ?? ""
        guard !primaryToken.isEmpty,
              (role == "client" && id == clientID && primary["email"] as? String == env["QA_CLIENT_EMAIL"])
                || (role == "caregiver" && id == caregiverID && primary["email"] as? String == env["QA_CG_EMAIL"]),
              primary["email"] as? String == env["QA_EMAIL"] else {
            XCTFail("Primary runner is outside the exact owned pair")
            throw URLError(.userAuthenticationRequired)
        }
        let peer = role == "client" ? caregiver : client
        let name = [peer.1["first_name"] as? String, peer.1["last_name"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertFalse(name.isEmpty)
        let contents = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: primaryToken)
        XCTAssertEqual(contents.status, 200)
        let rows = try XCTUnwrap(contents.body["result"] as? [[String: Any]])
        var labels = [String: String]()
        for row in rows {
            guard let slug = row["slug"] as? String, let translation = (row["translations"] as? [[String: Any]])?.first(where: {
                ($0["language_id"] as? NSNumber)?.intValue == 1 || ($0["language_id"] as? String) == "1"
            }), let name = translation["name"] as? String else { continue }
            labels[slug] = name
        }
        return Fixture(primaryToken: primaryToken, peerToken: peer.0, role: role, primaryID: id,
                       peerID: role == "client" ? caregiverID : clientID, peerName: name, labels: labels)
    }

    private func profile(_ endpoint: String, token: String, expectedUser: String) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", endpoint, token: token)
        XCTAssertEqual(response.status, 200)
        let row = try XCTUnwrap(response.body["result"] as? [String: Any])
        let user = try XCTUnwrap(row["user"] as? [String: Any])
        XCTAssertTrue(user["id"].map { String(describing: $0) } == expectedUser,
                      "Relationship reference must resolve only to the exact owned counterpart")
        return row
    }

    private func deleteOwnedEdge(_ path: String, token: String) throws -> Int {
        var request = URLRequest(url: URL(string: path, relativeTo: CarezaarAPI.base)!)
        request.httpMethod = "DELETE"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        var result: Result<Int, Error> = .failure(URLError(.unknown))
        URLSession.shared.dataTask(with: request) { _, response, error in
            defer { done.signal() }
            if let error { result = .failure(error); return }
            guard let response = response as? HTTPURLResponse else {
                result = .failure(URLError(.badServerResponse)); return
            }
            result = .success(response.statusCode)
        }.resume()
        done.wait()
        return try result.get()
    }
}
