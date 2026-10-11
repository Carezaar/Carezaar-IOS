import XCTest

/// P23-018: controlled native transport failure after a real valid profile.
/// Existing offline hook affects all app transports in its window, including
/// poll reads. This is action-phase isolation, not an endpoint-only fault.
final class MatchActionBoundaryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private struct LostAckFixture {
        let token: String, peerToken: String, role: String, primaryID: String, partnerID: String
        let endpoint: String, peerEndpoint: String, route: String, marker: String
    }
    private var lostAckCleanup: LostAckFixture?
    private var otherSessionCleanup: LostAckFixture?
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() {
        app?.terminate()
        if let f = lostAckCleanup {
            do { try restoreLostAckNone(f) }
            catch { XCTFail("Lost-ack owned request cleanup remains unverified; no other relationship may be removed") }
        }
        if let f = otherSessionCleanup {
            do { try restoreOtherSessionNone(f) }
            catch { XCTFail("Other-session owned peer request cleanup remains unverified; no unrelated edge may be removed") }
        }
        super.tearDown()
    }

    func testOwnedRequestCommittedLostAcknowledgementReconcilesSentWithoutReplay() throws {
        let f = try lostAckFixture()
        let before = try lostAckProfile(f)
        let peerBefore = try lostAckProfile(f, peer: true)
        guard before["match_status"] as? String == "none", peerBefore["match_status"] as? String == "none",
              before["match_id"] == nil || before["match_id"] is NSNull,
              peerBefore["match_id"] == nil || peerBefore["match_id"] is NSNull else {
            throw XCTSkip("P23-017 lost acknowledgement requires exact owned pair NONE; no existing edge is cleared")
        }
        let contents = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: f.token)
        guard contents.status == 200, let rows = contents.body["result"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        func managed(_ key: String, fallback: String) throws -> String {
            guard let row = rows.first(where: { $0["slug"] as? String == key }),
                  let translations = row["translations"] as? [[String: Any]],
                  let item = translations.first(where: { ($0["language_id"] as? Int) == 1 }) else { return fallback }
            let value = try XCTUnwrap(item["name"] as? String)
            XCTAssertFalse(value.isEmpty)
            return value
        }
        let changed = try managed("match_changed_message", fallback: "This match has changed")
        let pending = try managed("match_pending_acceptance", fallback: "Pending Acceptance")
        let introduction = try managed("match_introduction_title", fallback: "Introduction")
        app.launchEnvironment = ["QA_EMAIL": env["QA_EMAIL"]!, "QA_PASSWORD": env["QA_PASSWORD"]!,
            "QA_CLIENT_USER_ID": env["QA_CLIENT_USER_ID"]!, "QA_CG_ID": env["QA_CG_ID"]!]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", f.route,
            "--qa-lose-owned-match-ack", "POST", "users/matches", f.partnerID,
            "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let request = app.buttons["match-request"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            request.exists && request.isEnabled && request.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 45), .completed)
        XCTAssertEqual(try count("GET /api/" + f.endpoint), 1)
        XCTAssertEqual(try relationshipWrites(), 0)
        request.tap()
        let field = app.textFields[introduction].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10) && field.isHittable)
        field.tap(); field.typeText(f.marker)
        XCTAssertEqual(field.value as? String, f.marker)
        let confirm = app.buttons["match-request-confirm"]
        XCTAssertTrue(confirm.exists && confirm.isHittable)
        lostAckCleanup = f
        confirm.tap()
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", changed)).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 25), "Actual committed request with lost acknowledgement must reconcile through standard changed feedback")
        XCTAssertTrue(toast.exists)
        let toastProof = XCTAttachment(screenshot: toast.screenshot())
        toastProof.name = "P23-017-lost-ack-managed-changed-control"; toastProof.lifetime = .keepAlways; add(toastProof)
        let withdraw = app.buttons["match-withdraw"]
        XCTAssertTrue(withdraw.waitForExistence(timeout: 10) && withdraw.isHittable)
        XCTAssertTrue(app.staticTexts[pending].exists)
        XCTAssertFalse(request.exists)
        XCTAssertEqual(try count("POST /api/users/matches"), 1)
        XCTAssertEqual(try relationshipWrites(), 1)
        XCTAssertEqual(try count("QA lost-owned-match-ack"), 1, "Hook must prove one actual successful response was dropped")
        XCTAssertEqual(try count("GET /api/" + f.endpoint), 3, "Initial load, action preflight and post-loss reconciliation are actual native reads")
        let sent = try lostAckProfile(f), received = try lostAckProfile(f, peer: true)
        XCTAssertEqual(sent["match_status"] as? String, "sent")
        XCTAssertEqual(received["match_status"] as? String, "received")
        let edgeID = try XCTUnwrap(sent["match_id"] as? Int)
        XCTAssertGreaterThan(edgeID, 0)
        XCTAssertEqual(received["match_id"] as? Int, edgeID)
        _ = try lostAckOwnedEdge(edgeID, fixture: f)
        let actionProof = XCTAttachment(screenshot: withdraw.screenshot())
        actionProof.name = "P23-017-lost-ack-sent-withdraw-control"; actionProof.lifetime = .keepAlways; add(actionProof)
        app.terminate(); app.launchEnvironment = [:]
        app.launchArguments = ["--qa-request-counts", "--qa-push", f.route,
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let revisited = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            withdraw.exists && withdraw.isHittable && !request.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [revisited], timeout: 45), .completed)
        XCTAssertTrue(app.staticTexts[pending].exists)
        XCTAssertEqual(try count("POST /api/auth/login"), 0, "Ordinary revisit uses persisted owned session")
        XCTAssertEqual(try relationshipWrites(), 0, "Revisit must not replay the committed request")
        XCTAssertEqual(try count("GET /api/" + f.endpoint), 1)
        let after = try lostAckProfile(f)
        XCTAssertEqual(after["match_status"] as? String, "sent")
        XCTAssertEqual(after["match_id"] as? Int, edgeID)
        _ = try lostAckOwnedEdge(edgeID, fixture: f)
        let record: [String: Any] = ["caseID": "P23-017", "ownedPairStartedNone": true,
            "realRequestPOSTsBeforeRevisit": 1, "actualSuccessfulAcknowledgementsDropped": 1,
            "nativeProfileReadsBeforeRevisit": 3, "managedChangedFeedbackObserved": true,
            "backendSentReceivedSameOwnedEdge": true, "nativeSentActionObserved": true,
            "revisitMutationRequests": try relationshipWrites(), "requestBodyCaptured": false,
            "faultScope": "one-actual-2xx-owned-request-acknowledgement",
            "scenarioOtherSessionRelationshipChange": false, "scenarioLostAcknowledgement": true]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "P23-017-real-owned-request-lost-ack-reconciliation"; attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
        try restoreLostAckNone(f)
        lostAckCleanup = nil
    }

    func testOwnedOtherSessionRequestDuringNativeDialogReconcilesReceivedWithoutWrites() throws {
        let base = try lostAckFixture()
        let f = LostAckFixture(token: base.token, peerToken: base.peerToken, role: base.role,
            primaryID: base.primaryID, partnerID: base.partnerID, endpoint: base.endpoint,
            peerEndpoint: base.peerEndpoint, route: base.route,
            marker: "Synthetic other session request " + UUID().uuidString)
        let initial = try lostAckProfile(f), peerInitial = try lostAckProfile(f, peer: true)
        guard initial["match_status"] as? String == "none", peerInitial["match_status"] as? String == "none",
              initial["match_id"] == nil || initial["match_id"] is NSNull,
              peerInitial["match_id"] == nil || peerInitial["match_id"] is NSNull else {
            throw XCTSkip("Original P23-017 requires exact owned pair NONE; existing relationships are never cleared")
        }
        let contents = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: f.token)
        guard contents.status == 200, let rows = contents.body["result"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        func managed(_ key: String, fallback: String) throws -> String {
            guard let row = rows.first(where: { $0["slug"] as? String == key }),
                  let translations = row["translations"] as? [[String: Any]],
                  let english = translations.first(where: { $0["language_id"] as? Int == 1 }) else { return fallback }
            let value = try XCTUnwrap(english["name"] as? String)
            XCTAssertFalse(value.isEmpty); return value
        }
        let introduction = try managed("match_introduction_title", fallback: "Introduction")
        let changed = try managed("match_changed_message", fallback: "This match has changed")
        let acceptLabel = try managed("match_accept_title", fallback: "Accept")
        let rejectLabel = try managed("match_reject_title", fallback: "Reject")
        app.launchEnvironment = ["QA_EMAIL": env["QA_EMAIL"]!, "QA_PASSWORD": env["QA_PASSWORD"]!]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", f.route,
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let request = app.buttons["match-request"]
        try revealOwnedRequest(request, timeout: 45)
        XCTAssertEqual(try count("GET /api/" + f.endpoint), 1)
        XCTAssertEqual(try relationshipWrites(), 0)
        request.tap()
        let field = app.textFields[introduction].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10) && field.isHittable)
        field.tap(); field.typeText("Synthetic primary cancelled by state change")
        let confirm = app.buttons["match-request-confirm"]
        XCTAssertTrue(confirm.exists && confirm.isHittable && confirm.isEnabled)
        XCTAssertEqual(try count("GET /api/" + f.endpoint), 1, "Native action preflight has not started before Confirm")
        // The second verified owned session changes the real relationship while
        // the native action dialog is open, before its fresh preflight begins.
        otherSessionCleanup = f
        let created = try CarezaarAPI.callWithHTTPStatus("POST", "users/matches",
            form: ["partner_id": f.primaryID, "introduction": f.marker], token: f.peerToken)
        guard (200..<300).contains(created.status) else { throw URLError(.badServerResponse) }
        let primaryChanged = try lostAckProfile(f), peerChanged = try lostAckProfile(f, peer: true)
        XCTAssertEqual(primaryChanged["match_status"] as? String, "received")
        XCTAssertEqual(peerChanged["match_status"] as? String, "sent")
        let edgeID = try XCTUnwrap(peerChanged["match_id"] as? Int)
        XCTAssertGreaterThan(edgeID, 0)
        XCTAssertEqual(primaryChanged["match_id"] as? Int, edgeID)
        _ = try lostAckOwnedEdge(edgeID, fixture: f)
        XCTAssertTrue(field.exists && confirm.exists && confirm.isHittable,
                      "Native dialog must still be open after the other session's verified change")
        XCTAssertEqual(try relationshipWrites(), 0)
        confirm.tap()
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", changed)).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 20))
        XCTAssertTrue(toast.exists)
        let toastProof = XCTAttachment(screenshot: toast.screenshot())
        toastProof.name = "P23-017-other-session-standard-changed-control"; toastProof.lifetime = .keepAlways; add(toastProof)
        let accept = app.buttons["match-accept"], reject = app.buttons["match-reject"]
        let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            accept.exists && accept.isHittable && reject.exists && reject.isHittable && !request.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 20), .completed)
        XCTAssertEqual(accept.label, acceptLabel); XCTAssertEqual(reject.label, rejectLabel)
        XCTAssertFalse(app.buttons["match-withdraw"].exists)
        XCTAssertFalse(app.buttons["match-unmatch"].exists)
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try count("GET /api/" + f.endpoint), 2, "Exactly load and actual fresh Confirm preflight")
        XCTAssertEqual(try count("POST /api/users/matches"), 0)
        XCTAssertEqual(try relationshipWrites(), 0)
        for control in [accept, reject] {
            let crop = XCTAttachment(screenshot: control.screenshot())
            crop.name = "P23-017-other-session-" + control.identifier + "-only"; crop.lifetime = .keepAlways; add(crop)
        }
        _ = try lostAckOwnedEdge(edgeID, fixture: f)
        app.terminate(); app.launchEnvironment = [:]
        app.launchArguments = ["--qa-request-counts", "--qa-push", f.route,
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let reopened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            accept.exists && accept.isHittable && reject.exists && reject.isHittable && !request.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 45), .completed)
        XCTAssertEqual(accept.label, acceptLabel); XCTAssertEqual(reject.label, rejectLabel)
        XCTAssertEqual(try count("POST /api/auth/login"), 0)
        XCTAssertEqual(try count("GET /api/" + f.endpoint), 1)
        XCTAssertEqual(try relationshipWrites(), 0, "Ordinary revisit must not replay the aborted action")
        XCTAssertEqual(try lostAckProfile(f)["match_status"] as? String, "received")
        XCTAssertEqual(try lostAckProfile(f, peer: true)["match_status"] as? String, "sent")
        _ = try lostAckOwnedEdge(edgeID, fixture: f)
        let record: [String: Any] = ["caseID": "P23-017", "scenarioOtherSessionRelationshipChange": true,
            "scenarioLostAcknowledgement": false, "otherSessionChangedWhileNativeDialogOpen": true,
            "changeOccurredBeforeNativeConfirmPreflight": true, "concurrentPendingPreflightClaimed": false,
            "nativeRequestPOSTs": 0, "nativeRelationshipWrites": 0, "actualNativeProfileReadsBeforeRevisit": 2,
            "backendReceivedSentSameMarkedOwnedEdge": true, "managedChangedFeedbackObserved": true,
            "nativeReceivedActionSetObserved": true, "revisitMutationRequests": try relationshipWrites()]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "P23-017-real-owned-other-session-action-change"; attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
        try restoreOtherSessionNone(f)
        otherSessionCleanup = nil
    }

    private func restoreOtherSessionNone(_ f: LostAckFixture) throws {
        let primary = try lostAckProfile(f), peer = try lostAckProfile(f, peer: true)
        if primary["match_status"] as? String == "none", peer["match_status"] as? String == "none" { return }
        guard primary["match_status"] as? String == "received", peer["match_status"] as? String == "sent",
              let id = peer["match_id"] as? Int, id > 0, primary["match_id"] as? Int == id else {
            throw URLError(.cannotParseResponse)
        }
        _ = try lostAckOwnedEdge(id, fixture: f)
        let response = try CarezaarAPI.callWithHTTPStatus("DELETE", "users/matches/\(id)/withdraw", token: f.peerToken)
        guard (200..<300).contains(response.status) else { throw URLError(.badServerResponse) }
        XCTAssertEqual(try lostAckProfile(f)["match_status"] as? String, "none")
        XCTAssertEqual(try lostAckProfile(f, peer: true)["match_status"] as? String, "none")
    }

    private func revealOwnedRequest(_ request: XCUIElement, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        XCTAssertTrue(request.waitForExistence(timeout: timeout))
        for upward in [true, false] {
            for _ in 0..<24 {
                if request.exists && request.isEnabled && request.isHittable { return }
                guard Date() < deadline else { break }
                let scroll = try XCTUnwrap(app.scrollViews.allElementsBoundByIndex
                    .filter { $0.exists && $0.frame.width > app.frame.width * 0.5 && $0.frame.height > 60 }
                    .max(by: { $0.frame.height < $1.frame.height }))
                scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.75 : 0.25))
                    .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.25 : 0.75)), withVelocity: .slow, thenHoldForDuration: 0.1)
            }
        }
        XCTAssertTrue(request.exists && request.isEnabled && request.isHittable)
        guard request.exists && request.isEnabled && request.isHittable else { throw URLError(.timedOut) }
    }

    private func lostAckFixture() throws -> LostAckFixture {
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
        return LostAckFixture(token: primary.0, peerToken: peerToken, role: role, primaryID: id, partnerID: partnerID,
                              endpoint: endpoint, peerEndpoint: peerEndpoint, route: route, marker: "Synthetic lost acknowledgement " + UUID().uuidString)
    }
    private func lostAckProfile(_ f: LostAckFixture, peer: Bool = false) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", peer ? f.peerEndpoint : f.endpoint, token: peer ? f.peerToken : f.token)
        guard response.status == 200, let result = response.body["result"] as? [String: Any],
              let user = result["user"] as? [String: Any],
              user["id"].map({ String(describing: $0) }) == (peer ? f.primaryID : f.partnerID),
              user["role"] as? String == (peer ? f.role : (f.role == "client" ? "caregiver" : "client")) else {
            throw URLError(.cannotParseResponse)
        }
        return result
    }
    private func lostAckOwnedEdge(_ id: Int, fixture f: LostAckFixture) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/matches/\(id)", token: f.token)
        guard response.status == 200, let row = response.body["result"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
        func userID(_ side: String) -> String {
            let user = (row[side] as? [String: Any])?["user"] as? [String: Any]
            return user?["id"].map { String(describing: $0) } ?? ""
        }
        guard row["id"] as? Int == id, userID(f.role) == f.primaryID,
              userID(f.role == "client" ? "caregiver" : "client") == f.partnerID,
              row["introduction"] as? String == f.marker else {
            XCTFail("Refusing unrelated/unmarked edge mutation or cleanup")
            throw URLError(.userAuthenticationRequired)
        }
        return row
    }
    private func restoreLostAckNone(_ f: LostAckFixture) throws {
        let current = try lostAckProfile(f)
        if current["match_status"] as? String == "none" {
            XCTAssertEqual(try lostAckProfile(f, peer: true)["match_status"] as? String, "none")
            return
        }
        guard current["match_status"] as? String == "sent", let id = current["match_id"] as? Int, id > 0 else {
            throw URLError(.cannotParseResponse)
        }
        _ = try lostAckOwnedEdge(id, fixture: f)
        let peer = try lostAckProfile(f, peer: true)
        guard peer["match_status"] as? String == "received", peer["match_id"] as? Int == id else {
            throw URLError(.cannotParseResponse)
        }
        let response = try CarezaarAPI.callWithHTTPStatus("DELETE", "users/matches/\(id)/withdraw", token: f.token)
        guard (200..<300).contains(response.status) else { throw URLError(.cannotParseResponse) }
        XCTAssertEqual(try lostAckProfile(f)["match_status"] as? String, "none")
        XCTAssertEqual(try lostAckProfile(f, peer: true)["match_status"] as? String, "none")
    }

    func testOwnedNoneMatchFailedPreflightRetryRecoversWithoutMutationReplay() throws {
        guard let email = env["QA_EMAIL"], !email.isEmpty,
              let password = env["QA_PASSWORD"], !password.isEmpty,
              let clientID = env["QA_CLIENT_USER_ID"], !clientID.isEmpty,
              let caregiverID = env["QA_CG_ID"], !caregiverID.isEmpty, clientID != caregiverID else {
            throw XCTSkip("Distinct retained owned pair IDs and primary credentials required")
        }
        let token = try CarezaarAPI.login(email, password)
        guard !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let me = try CarezaarAPI.me(token)
        let id = me["id"].map { String(describing: $0) } ?? ""
        let role = me["role"] as? String
        let endpoint: String, route: String, partnerID: String, partnerRole: String
        if id == clientID && role == "client" {
            partnerID = caregiverID; partnerRole = "caregiver"
            endpoint = "clients/caregivers/\(partnerID)"; route = "CaregiverDetails/\(partnerID)"
        } else if id == caregiverID && role == "caregiver" {
            partnerID = clientID; partnerRole = "client"
            endpoint = "caregivers/clients/\(partnerID)"; route = "ClientDetails/\(partnerID)"
        } else {
            XCTFail("Exact owned primary identity and role required")
            throw URLError(.userAuthenticationRequired)
        }
        func profile() throws -> [String: Any] {
            let response = try CarezaarAPI.callWithHTTPStatus("GET", endpoint, token: token)
            guard (200..<300).contains(response.status),
                  let result = response.body["result"] as? [String: Any],
                  let user = result["user"] as? [String: Any],
                  user["id"].map({ String(describing: $0) }) == partnerID,
                  user["role"] as? String == partnerRole else {
                XCTFail("Read must identify the exact owned counterpart")
                throw URLError(.cannotParseResponse)
            }
            return result
        }
        let before = try profile()
        guard before["match_status"] as? String == "none",
              before["match_id"] == nil || before["match_id"] is NSNull else {
            throw XCTSkip("P23-018 requires owned pair NONE; this read-only test never resets a relation")
        }
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: token)
        guard response.status == 200, let rows = response.body["result"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        func managed(_ slug: String, fallback: String) throws -> String {
            guard let row = rows.first(where: { $0["slug"] as? String == slug }),
                  let translations = row["translations"] as? [[String: Any]],
                  let translation = translations.first(where: {
                      ($0["language_id"] as? NSNumber)?.intValue == 1 || $0["language_id"] as? String == "1"
                  }) else { return fallback }
            let value = try XCTUnwrap(translation["name"] as? String)
            XCTAssertFalse(value.isEmpty, "Present managed English copy must not be empty")
            return value
        }
        let title = try managed("match_check_failed_title", fallback: "Couldn't check this match")
        let message = try managed("match_check_failed_message", fallback: "Please check your connection and try again.")
        let retryLabel = try managed("general_try_again", fallback: "Try Again")
        app.launchEnvironment = ["QA_EMAIL": email, "QA_PASSWORD": password]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", route,
                               "--qa-offline", "60", "150", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        let launched = Date()
        app.launch()
        let request = app.buttons["match-request"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            request.exists && request.isHittable && request.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 40), .completed)
        guard request.exists, request.isHittable, request.isEnabled,
              Date().timeIntervalSince(launched) < 45 else {
            XCTFail("Initial valid profile must load before the bounded fault-clock prerequisite")
            throw URLError(.timedOut)
        }
        let profileKey = "GET /api/\(endpoint)"
        XCTAssertEqual(try count(profileKey), 1)
        XCTAssertEqual(try relationshipWrites(), 0)
        request.tap()
        let confirm = app.buttons["match-request-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10) && confirm.isHittable)
        // The first app transport initialized its fault clock within [0,45]s
        // of this launch. At test elapsed [110,120] its clock lies in [65,120],
        // strictly inside the configured [60,150] window. Abort on late timing.
        try wait(until: 110, launched: launched)
        guard Date().timeIntervalSince(launched) < 120, confirm.exists, confirm.isHittable else {
            XCTFail("Never confirm outside the proven offline interval")
            throw URLError(.timedOut)
        }
        confirm.tap()
        let dialog = app.alerts[title]
        XCTAssertTrue(dialog.waitForExistence(timeout: 12), "Real failed action preflight must show managed check dialog")
        XCTAssertTrue(dialog.staticTexts[message].exists)
        let retry = dialog.buttons[retryLabel]
        XCTAssertTrue(retry.exists && retry.isHittable)
        XCTAssertTrue(request.exists, "Failed read must retain the original action")
        XCTAssertEqual(try relationshipWrites(), 0)
        let failedCount = try count(profileKey)
        XCTAssertGreaterThan(failedCount, 1)
        let proof = XCTAttachment(screenshot: retry.screenshot())
        proof.name = "P23-018-managed-retry-control"; proof.lifetime = .keepAlways; add(proof)
        guard Date().timeIntervalSince(launched) < 135 else {
            XCTFail("Offline retry must start with sufficient fault-window margin")
            throw URLError(.timedOut)
        }
        retry.tap()
        let failedAgain = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            dialog.exists && dialog.buttons[retryLabel].exists &&
                ((try? self.count(profileKey)) ?? failedCount) > failedCount
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [failedAgain], timeout: 10), .completed)
        XCTAssertTrue(request.exists)
        XCTAssertEqual(try relationshipWrites(), 0)
        // By test elapsed 200 the latest possible clock initialization (45s)
        // places the app beyond its 150s fault end, without changing app flags.
        try wait(until: 200, launched: launched)
        let recoveryBaseline = try count(profileKey)
        XCTAssertTrue(dialog.exists && retry.exists && retry.isHittable)
        retry.tap()
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 20))
        XCTAssertTrue(request.exists && request.isHittable && request.isEnabled)
        XCTAssertEqual(try count(profileKey), recoveryBaseline + 1, "Recovery Try Again performs one real read")
        Thread.sleep(forTimeInterval: 2)
        let writes = try relationshipWrites()
        XCTAssertEqual(writes, 0, "Retry must not replay a relationship mutation")
        let after = try profile()
        XCTAssertEqual(after["match_status"] as? String, "none")
        XCTAssertTrue(after["match_id"] == nil || after["match_id"] is NSNull)
        let record: [String: Any] = ["caseID": "P23-018", "ownedIdentityVerified": true,
            "initialNoneVerified": true, "initialProfileGETs": 1,
            "failedPreflightGETAttempts": failedCount - 1, "recoveryGETs": 1,
            "relationshipMutationRequests": writes, "originalActionRetained": request.exists,
            "backendRelationshipUnchanged": after["match_status"] as? String == "none",
            "faultScope": "global-app-transport-during-action-phase", "noRelationStaging": true]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "P23-018-native-read-only-recovery"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func wait(until elapsed: TimeInterval, launched: Date) throws {
        while Date().timeIntervalSince(launched) < elapsed {
            Thread.sleep(forTimeInterval: max(0.01, min(1, elapsed - Date().timeIntervalSince(launched))))
        }
    }
    private func ledger() throws -> [String: Int] {
        let element = app.staticTexts["qa-request-counts"]
        guard element.exists, !element.label.isEmpty else { throw URLError(.cannotParseResponse) }
        var result: [String: Int] = [:]
        for line in element.label.split(separator: "\n") {
            guard let equal = line.lastIndex(of: "="), let value = Int(line[line.index(after: equal)...]) else {
                throw URLError(.cannotParseResponse)
            }
            result[String(line[..<equal])] = value
        }
        return result
    }
    private func count(_ key: String) throws -> Int { try ledger()[key] ?? 0 }
    private func relationshipWrites() throws -> Int {
        try ledger().filter { entry in
            ["POST", "PATCH", "DELETE", "PUT"].contains(where: { entry.key.hasPrefix($0 + " /api/users/matches") })
        }.values.reduce(0, +)
    }
}
