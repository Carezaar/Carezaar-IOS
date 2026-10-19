import XCTest
import Foundation

/// Synthetic HTTPS document fixture only. This never registers an account,
/// accepts consent, submits credentials or changes the production legal URLs.
final class LegalRemoteUITests: XCTestCase {
    private let app = XCUIApplication()
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private let fixtureMarker = "carezaar-legal-fixture-20261018"
    private var controlURL: URL!

    override func setUp() { continueAfterFailure = false }
    override func tearDown() {
        if (testRun?.totalFailureCount ?? 0) > 0 {
            capture("failure-screen")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "legal-fixture-failure-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        app.terminate(); super.tearDown()
    }

    func testConfiguredHTTPSLegalPDFReloadsCurrentBytesAndRecoversWithoutStaleFallback() throws {
        guard environment["QA_LEGAL_FIXTURE_MARKER"] == fixtureMarker,
              environment["QA_LEGAL_TERMS_URL"] == "https://127.0.0.1:4440/terms.pdf",
              environment["QA_LEGAL_PRIVACY_URL"] == "https://127.0.0.1:4440/privacy",
              let control = environment["QA_LEGAL_CONTROL_URL"],
              ["http://127.0.0.1:4441", "https://127.0.0.1:4440/__control"].contains(control),
              let address = URL(string: control) else {
            throw XCTSkip("Explicit task-only legal fixture marker, exact configured HTTPS URLs and local control address required")
        }
        controlURL = address
        _ = try command("POST", "/reset", ["revision": 1, "delayMilliseconds": 4000])
        app.launchArguments = ["--qa-signout", "--qa-push", "SignUpCredentials/client",
                               "-carezaar.languageCode", "en", "-carezaar.languageId", "1"]
        XCTAssertFalse(app.launchArguments.contains("--qa-legal-url"), "This test must exercise built Info.plist configuration")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "signup-consent-text").firstMatch.waitForExistence(timeout: 60))

        try openDocument("Terms of Use")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "legal-document-loading").firstMatch.waitForExistence(timeout: 5),
                      "Delayed real HTTPS response must expose loading state")
        try assertMarker("Carezaar legal fixture revision 1", stage: "pdf-revision-1")
        try closeDocument()
        let firstCount = try requestCount("/terms.pdf")
        XCTAssertGreaterThan(firstCount, 0)

        _ = try command("POST", "/state", ["revision": 2, "delayMilliseconds": 0])
        try openDocument("Terms of Use")
        try assertMarker("Carezaar legal fixture revision 2", stage: "pdf-same-url-revision-2")
        XCTAssertFalse(markerElement("Carezaar legal fixture revision 1").exists)
        XCTAssertGreaterThan(try requestCount("/terms.pdf"), firstCount, "Reopening must request the same PDF URL again despite long-lived server cache headers")
        try closeDocument()

        try openDocument("Privacy Policy")
        try assertMarker("Carezaar privacy fixture revision 2", stage: "privacy-configured-https")
        XCTAssertGreaterThan(try requestCount("/privacy"), 0, "Privacy must use its separately configured server URL")
        try closeDocument()

        _ = try command("POST", "/state", ["fail": true])
        try openDocument("Terms of Use")
        let failure = app.staticTexts["legal-document-unavailable"]
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        XCTAssertFalse(markerElement("Carezaar legal fixture revision 2").exists, "Failed remote opening must not silently show an earlier PDF")
        capture("remote-http-failure")
        _ = try command("POST", "/state", ["fail": false, "revision": 3])
        let retry = app.buttons["legal-document-retry"]
        XCTAssertTrue(retry.exists && retry.isHittable)
        retry.tap()
        try assertMarker("Carezaar legal fixture revision 3", stage: "remote-retry-current-pdf")
        try closeDocument()

        _ = try command("POST", "/state", ["revision": 4, "delayMilliseconds": 7000])
        try openDocument("Terms of Use")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "legal-document-loading").firstMatch.waitForExistence(timeout: 5))
        try closeDocument()
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let state = try? self.command("GET", "/state"), let rows = state["requests"] as? [[String: Any]] else { return false }
            return rows.contains { ($0["path"] as? String) == "/terms.pdf" && ($0["revision"] as? Int) == 4
                && ($0["closedBeforeEnd"] as? Bool) == true }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 10), .completed,
                       "Closing while loading must stop the actual remote document request")
        _ = try command("POST", "/state", ["revision": 5, "delayMilliseconds": 0])
        try openDocument("Terms of Use")
        try assertMarker("Carezaar legal fixture revision 5", stage: "reopen-after-cancel-current-pdf")
        XCTAssertFalse(markerElement("Carezaar legal fixture revision 4").exists)
        try closeDocument()

        let state = try command("GET", "/state")
        let requests = try XCTUnwrap(state["requests"] as? [[String: Any]])
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { ($0["authorizationPresent"] as? Bool) == false })
        XCTAssertTrue(requests.allSatisfy { ($0["cacheControl"] as? String)?.contains("no-cache") == true
            && ($0["cacheControl"] as? String)?.contains("no-store") == true
            && ($0["pragma"] as? String) == "no-cache" }, "Every observed WK request must carry explicit cache bypass headers")
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "legal-remote-fixture-request-ledger"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func markerElement(_ marker: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", marker, marker)).firstMatch
    }
    private func assertMarker(_ marker: String, stage: String) throws {
        let present = markerElement(marker).waitForExistence(timeout: 20)
        capture(stage)
        XCTAssertTrue(present, "The actual WK document must expose the current synthetic revision text; raster review is separate")
        XCTAssertTrue(app.webViews["legal-document"].exists)
        XCTAssertFalse(app.staticTexts["legal-document-unavailable"].exists)
    }
    private func openDocument(_ name: String) throws {
        let link = app.links[name].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        if !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.isHittable && !link.frame.isEmpty, "Native legal link needs an actual accessible hit region")
        link.tap()
        XCTAssertTrue(app.navigationBars.buttons["OK"].waitForExistence(timeout: 10))
    }
    private func closeDocument() throws {
        let close = app.navigationBars.buttons["OK"].firstMatch
        XCTAssertTrue(close.exists && close.isHittable)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.webViews["legal-document"].exists)
    }
    private func requestCount(_ path: String) throws -> Int {
        let state = try command("GET", "/state")
        return (state["requests"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == path }.count
    }
    private final class Reply: @unchecked Sendable { var data: Data?; var response: URLResponse?; var error: Error? }
    private func command(_ method: String, _ path: String, _ body: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: controlURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        request.httpMethod = method
        request.setValue(fixtureMarker, forHTTPHeaderField: "X-Carezaar-Fixture")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let reply = Reply(), completed = expectation(description: "Task-owned local legal fixture control")
        URLSession.shared.dataTask(with: request) { data, response, error in
            reply.data = data; reply.response = response; reply.error = error; completed.fulfill()
        }.resume()
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 10), .completed)
        if let error = reply.error { throw error }
        XCTAssertEqual((reply.response as? HTTPURLResponse)?.statusCode, 200)
        let data = try XCTUnwrap(reply.data)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(value["marker"] as? String, fixtureMarker)
        return value
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "legal-remote-" + name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
