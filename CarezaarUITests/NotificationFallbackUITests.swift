import XCTest
import Foundation

/// P14-005/006 native missing-target fallback, runtime PENDING.
/// Only reads an existing first-page notification of the exact retained owner.
/// Row taps may mark that owner's notification seen; no notification/relationship
/// is created. The Debug hook strips targets from one real HTTP200 list row.
final class NotificationFallbackUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app?.terminate(); super.tearDown() }

    func testOwnedNotificationMissingPersonShowDismissesWithoutDestinationGET() throws {
        try verifyFallback(kind: "person")
    }
    func testOwnedChatNotificationMissingTargetsShowDismissesWithoutDestinationGET() throws {
        try verifyFallback(kind: "chat")
    }

    func testNotificationDetailsContainOnlyContentAndShowAndBackdropDismisses() throws {
        let f = try fixture(kind: "person")
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", "Notifications",
            "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let row = app.buttons["notification-row-\(f.id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in row.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        row.tap()
        let detail = app.scrollViews["notification-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        XCTAssertFalse(detail.staticTexts[f.title].exists, "R11 removes the Notifications modal title")
        XCTAssertEqual(detail.buttons.count, 1, "R11 allows only Show; no explicit close control")
        XCTAssertTrue(detail.staticTexts[f.subject].exists)
        XCTAssertEqual(detail.buttons["notification-show"].label, f.show)
        let backdrop = app.buttons["notification-dismiss-backdrop"]
        XCTAssertTrue(backdrop.exists && backdrop.isHittable)
        backdrop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.exists && row.isHittable)
        XCTAssertEqual(destinationGETs(), 0)
    }

    private func verifyFallback(kind: String) throws {
        let f = try fixture(kind: kind) // identity proof precedes any UI seen PATCH
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts",
            "--qa-push", "Notifications", "--qa-notification-missing-target", String(f.id), kind,
            "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let row = app.buttons["notification-row-\(f.id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "Exact preflight-owned first-page notification must load")
        let hook = app.staticTexts["qa-notification-fallback"]
        XCTAssertTrue(hook.exists, "Debug actual-200 response mutation attestation missing")
        XCTAssertTrue(hook.label.contains("id=\(f.id) kind=\(kind) partner=nil chat=nil"))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            row.isHittable && !self.app.staticTexts["Please wait..."].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        XCTAssertEqual(destinationGETs(), 0)
        let detail = app.scrollViews["notification-detail"]
        let show = app.buttons["notification-show"]
        row.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        XCTAssertTrue(detail.staticTexts[f.subject].exists, "Exact independently translated subject required")
        XCTAssertFalse(detail.staticTexts[f.title].exists)
        XCTAssertEqual(show.label, f.show)
        XCTAssertTrue(show.isEnabled)
        let backdrop = app.buttons["notification-dismiss-backdrop"]
        XCTAssertTrue(backdrop.exists && backdrop.isHittable)
        backdrop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 10))
        XCTAssertTrue(row.exists && row.isHittable)
        XCTAssertEqual(destinationGETs(), 0)
        row.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        XCTAssertTrue(show.exists && show.isEnabled && show.isHittable)
        controlProof(show, "notification-missing-\(kind)-show-only")
        show.tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 10), "Missing destination must dismiss the modal")
        XCTAssertTrue(app.navigationBars[f.title].exists && row.exists && row.isHittable)
        let noLateRoute = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.destinationGETs() != 0 || self.app.scrollViews["notification-detail"].exists
        }, object: nil)
        noLateRoute.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [noLateRoute], timeout: 3), .completed)
        XCTAssertEqual(destinationGETs(), 0)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "unavailable")).firstMatch.exists)
        XCTAssertLessThanOrEqual(count("PATCH /api/users/notifications/\(f.id)/see"), f.wasSeen ? 0 : 1)
        let data = try JSONSerialization.data(withJSONObject: ["role": f.role, "kind": kind,
            "exactOwnedPreflight": true, "existingFirstPageNotification": true,
            "actualHTTP200ScopedTargetRemoval": true, "outsideDismissStayedOnNotifications": true,
            "showDismissedMissingTarget": true, "destinationGETs": destinationGETs(),
            "physicalNetworkOrDeletedBackendPerson": false], options: [.sortedKeys])
        let proof = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        proof.name = "owned-notification-missing-\(kind)-native-fallback"; proof.lifetime = .keepAlways; add(proof)
    }

    private struct Fixture {
        let id: Int, role: String, subject: String, title: String, show: String, cancel: String
        let wasSeen: Bool
    }
    private func fixture(kind: String) throws -> Fixture {
        guard let email = env["QA_EMAIL"], let password = env["QA_PASSWORD"],
              let clientID = env["QA_CLIENT_USER_ID"], let caregiverID = env["QA_CG_ID"] else {
            throw XCTSkip("Exact retained owner credentials and role IDs required")
        }
        let token = try CarezaarAPI.login(email, password)
        let me = try CarezaarAPI.me(token)
        let role = me["role"] as? String ?? ""
        let id = me["id"].map { String(describing: $0) } ?? ""
        guard !token.isEmpty, me["email"] as? String == email,
              (role == "client" && id == clientID) || (role == "caregiver" && id == caregiverID) else {
            XCTFail("Notification fixture is not the exact retained owner")
            throw URLError(.userAuthenticationRequired)
        }
        func reference(_ path: String) throws -> [[String: Any]] {
            let response = try CarezaarAPI.callWithHTTPStatus("GET", path, token: token)
            XCTAssertEqual(response.status, 200)
            return try XCTUnwrap(response.body["result"] as? [[String: Any]])
        }
        func english(_ row: [String: Any]) -> String? {
            (row["translations"] as? [[String: Any]])?.first(where: {
                ($0["language_id"] as? NSNumber)?.intValue == 1 || ($0["language_id"] as? String) == "1"
            })?["name"] as? String
        }
        let subjects = try reference("base/subjects?ts_cache=0")
        let contents = try reference("base/contents?ts_cache=0")
        func label(_ slug: String) throws -> String {
            let row = try XCTUnwrap(contents.first { $0["slug"] as? String == slug })
            let value = try XCTUnwrap(english(row)); XCTAssertFalse(value.isEmpty); return value
        }
        let rows = try reference("users/notifications?page=1&perPage=10")
        for row in rows {
            guard let notificationID = row["id"] as? Int,
                  let owner = row["user"] as? [String: Any],
                  owner["id"].map({ String(describing: $0) }) == id,
                  let subjectID = row["subject_id"] as? Int,
                  let subject = subjects.first(where: { $0["id"] as? Int == subjectID }),
                  let code = subject["code"] as? String, let text = english(subject), !text.isEmpty,
                  let partner = row["partner"] as? [String: Any],
                  let partnerID = partner["id"].map({ String(describing: $0) }), !partnerID.isEmpty else { continue }
            if kind == "chat" {
                guard code.hasPrefix("chat"), let chat = row["chat"] as? [String: Any], chat["id"] as? Int != nil else { continue }
            } else { guard !code.hasPrefix("chat") else { continue } }
            return Fixture(id: notificationID, role: role, subject: text,
                title: try label("general_notifications"), show: try label("general_show"),
                cancel: try label("general_cancel"), wasSeen: row["seen_at"] != nil && !(row["seen_at"] is NSNull))
        }
        throw XCTSkip("No eligible exact-owned \(kind) notification on actual native first page; no fixture seeded")
    }
    private func count(_ path: String) -> Int {
        let prefix = path + "="
        return app.staticTexts["qa-request-counts"].label.split(separator: "\n").first(where: { $0.hasPrefix(prefix) })
            .flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
    }
    private func destinationGETs() -> Int {
        app.staticTexts["qa-request-counts"].label.split(separator: "\n").reduce(0) { total, line in
            let value = String(line)
            let prefixes = ["GET /api/clients/caregivers/", "GET /api/caregivers/clients/", "GET /api/users/chats/"]
            guard prefixes.contains(where: { value.hasPrefix($0) }), let n = Int(value.split(separator: "=").last ?? "") else { return total }
            return total + n
        }
    }
    private func controlProof(_ control: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: control.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
