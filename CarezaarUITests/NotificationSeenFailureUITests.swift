// Actual owned-session HTTP500 transport regression. No login or backend seen mutation in RED mode.
import XCTest
import Foundation
import Darwin

final class NotificationSeenFailureUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    enum Stop: Error { case guardFailed(String) }
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app?.terminate(); super.tearDown() }

    /// Run against unchanged NotificationsView.select first. Expected strict RED:
    /// local unread disappears and no managed error is displayed after real HTTP500.
    /// This method forwards ZERO seen PATCHes and never retries the mutation.
    func testSeenHTTP500KeepsUnreadShowsManagedErrorAndAllowsRetry() throws {
        try failureThenOptionalHealthyRetry(healthy: false)
    }
    /// Separate allocation after actual RED and reviewed production fix. The private
    /// proxy plan either authorizes exactly one owned unread seen PATCH, or returns
    /// controlled HTTP200 using an existing already-seen record with zero writes.
    func testSeenHTTP500ThenOneExplicitHealthyRetry() throws {
        try failureThenOptionalHealthyRetry(healthy: true)
    }
    private func require(_ value: Bool, _ reason: String) throws {
        if !value { throw Stop.guardFailed(reason) }
    }
    private func wait(_ reason: String, seconds: TimeInterval = 15, _ body: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in body() }, object: nil)
        try require(XCTWaiter.wait(for: [expectation], timeout: seconds) == .completed, reason)
    }
    private func unique(_ query: XCUIElementQuery) throws -> XCUIElement {
        let element = query.element(boundBy: 0)
        try require(element.waitForExistence(timeout: 15) && query.count == 1, "unique-native-control-required")
        return element
    }
    private func ledger() throws -> [String: Int] {
        let element = app.staticTexts["qa-request-counts"]
        try require(element.exists, "real-native-transport-ledger-required")
        var result: [String: Int] = [:]
        for line in element.label.split(separator: "\n") {
            guard let split = line.lastIndex(of: "="), let count = Int(line[line.index(after: split)...]), count >= 0 else { throw Stop.guardFailed("invalid-ledger") }
            let key = String(line[..<split]);try require(result[key] == nil, "duplicate-ledger-route")
            result[key] = count
        }
        return result
    }
    private func proof(_ name: String, _ data: [String: Any]) throws {
        try privateBytes(name + "-private.json", JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]))
    }
    private func privateBytes(_ name: String, _ bytes: Data) throws {
        let directory = URL(fileURLWithPath: try XCTUnwrap(env["QA_NOTIFICATION_PROOF_DIR"]))
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o700, "private-proof-directory-required")
        let path = directory.appendingPathComponent(name)
        let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        try require(fd >= 0, "exclusive-private-proof-required")
        defer { close(fd) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                try require(count > 0, "private-proof-write-failed");offset += count
            }
        }
        try require(fsync(fd) == 0, "private-proof-fsync-failed")
    }
    private func control() throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(env["QA_NOTIFICATION_CONTROL_URL"])))
        try require(url.scheme == "http" && url.host == "127.0.0.1" && url.path == "/__qa__/state", "exact-loopback-control-only")
        var request = URLRequest(url: url);request.timeoutInterval = 3
        request.setValue(try XCTUnwrap(env["QA_NOTIFICATION_CONTROL_NONCE"]), forHTTPHeaderField: "X-QA-Control")
        var result: Result<[String: Any], Error> = .failure(Stop.guardFailed("control-response-missing"))
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { bytes, response, error in
            defer { done.signal() }
            if let error { result = .failure(error); return }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let bytes,
                  let value = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return }
            result = .success(value)
        }
        task.resume()
        guard done.wait(timeout: .now() + 4) == .success else { task.cancel();throw Stop.guardFailed("control-timeout") }
        return try result.get()
    }
    private func unread(_ row: XCUIElement) -> Bool {
        // Real Button AX may combine its labelled dot into the row label.
        // Root must review the pre-tap AX witness; fixture partner/subject labels
        // must not themselves contain the standalone word Unread.
        row.label.range(of: #"\bUnread\b"#, options: .regularExpression) != nil
            || row.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Unread")).count == 1
    }
    private func dismissDetails() throws {
        let backdrop = app.buttons["notification-dismiss-backdrop"]
        try require(backdrop.exists && backdrop.isHittable && backdrop.frame.width > 0 && backdrop.frame.height > 0,
                    "actual-detail-backdrop-required")
        // Same observed backdrop gesture as existing NotificationFallbackUITests;
        // root reviews this geometry before allocation, never taps Show.
        backdrop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        try require(app.scrollViews["notification-detail"].waitForNonExistence(timeout: 10), "detail-not-dismissed")
    }
    private func failureThenOptionalHealthyRetry(healthy: Bool) throws {
        guard env["QA_NOTIFICATION_SEEN_REVIEWED"] == "1" else { throw XCTSkip("Root-reviewed exact existing notification allocation required") }
        let base = try XCTUnwrap(env["QA_NOTIFICATION_API_BASE_URL"])
        let url = try XCTUnwrap(URL(string: base))
        try require(url.scheme == "http" && url.host == "127.0.0.1" && (url.path == "/api" || url.path == "/api/") && base.hasSuffix("/api/") && url.query == nil && url.fragment == nil, "strict-loopback-API-fixture-required")
        let error = try XCTUnwrap(env["QA_NOTIFICATION_MANAGED_ERROR"])
        let title = try XCTUnwrap(env["QA_NOTIFICATION_MANAGED_TITLE"])
        let controlled = env["QA_NOTIFICATION_CONTROLLED_SESSION"] == "1"
        let ownerPath = try XCTUnwrap(env["QA_NOTIFICATION_OWNER_FILE"])
        let ownerFixture: [String: Any]
        if controlled {
            let url = URL(fileURLWithPath: ownerPath)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let parent = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            try require(url.resolvingSymlinksInPath().path == url.standardizedFileURL.path
                && attrs[.type] as? FileAttributeType == .typeRegular
                && (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600
                && (parent[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                        "private-regular-local-synthetic-record")
            ownerFixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        } else { ownerFixture = try NativeLifecycleFixture.read(ownerPath) }
        guard let expectedOwnerEmail = ownerFixture["email"] as? String else { throw Stop.guardFailed("owner-email-required") }
        if controlled {
            try require(ownerFixture["synthetic"] as? Bool == true && ownerFixture["localTransportOnly"] as? Bool == true
                && expectedOwnerEmail.hasSuffix("@example.invalid"), "explicit-controlled-synthetic-session-only")
        } else {
            let provenance = try XCTUnwrap(ownerFixture["native_provenance"] as? [String: Any])
            try require(ownerFixture["role"] as? String == "client" && provenance["purpose"] as? String == "carezaar-native-final-qa"
                && provenance["stage"] as? String == "signupComplete" && provenance["provider_ownership_verified"] as? Bool == true,
                        "exact-completed-owned-client-purpose")
        }
        app.launchEnvironment = ["CAREZAAR_API_BASE_URL": base]
        app.launchArguments = ["--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        if controlled { app.launchArguments.append("--qa-seed-invalid-session") }
        app.launch()
        // An already saved exact-owner session is required for this narrow RED.
        // No hidden login, no local token clear, no account/session allocation.
        let messages = app.buttons["Messages"]
        try require(messages.waitForExistence(timeout: 30), "ordinary-owned-Main-required-no-login-fallback")
        if controlled {
            // Normal dismissal on the fresh disposable fixture device only; no permission acceptance claim.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let prompt = springboard.alerts.matching(NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "Carezaar", "notification")).firstMatch
            if prompt.waitForExistence(timeout: 8) {
                let deny = prompt.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"]))
                try require(deny.count == 1 && deny.firstMatch.isHittable, "one-normal-synthetic-notification-prompt-denial")
                deny.firstMatch.tap()
            }
        }
        try wait("foreground-and-ANYbusy-gone-before-one-Profile-tap", seconds: 30) {
            self.app.state == .runningForeground && messages.isHittable
                && self.app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait...")).count == 0
                && self.app.alerts.count == 0
        }
        let profile = app.buttons.matching(NSPredicate(format: "label == %@", "Profile")).allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.minY > self.app.frame.maxY - 110 }
        try require(profile.count == 1, "one-real-bottom-Profile-tab")
        profile[0].tap()
        let owners = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value == %@", "Email Address", expectedOwnerEmail))
        try wait("selected-Profile-and-exact-native-owner-email", seconds: 30) {
            profile[0].isSelected && owners.count == 1 && owners.firstMatch.isHittable && self.app.frame.contains(owners.firstMatch.frame)
        }
        let bell = try unique(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)))
        try require(bell.isHittable, "native-bell-not-hittable");bell.tap()
        try require(app.navigationBars[title].waitForExistence(timeout: 30), "actual-Notifications-not-open")
        var captured: [String: Any] = [:]
        try wait("actual-owned-first-page-captured", seconds: 30) {
            captured = (try? self.control()) ?? [:]
            return captured["exactOwnerVerified"] as? Bool == true && captured["firstPageCaptured"] as? Bool == true
        }
        guard let id = captured["notificationID"] as? Int, id > 0 else { throw Stop.guardFailed("actual-existing-owned-notification-ID") }
        let row = app.buttons["notification-row-\(id)"]
        try wait("exact-existing-unread-row-ready", seconds: 30) { row.exists && row.isHittable && self.unread(row) }
        try privateBytes("before-tap-owned-unread-row-private.png", row.screenshot().pngRepresentation)
        let start = try control()
        try require(start["exactOwnerVerified"] as? Bool == true && start["seenAttempts"] as? Int == 0
            && start["actualSeenForwarded"] as? Int == 0 && start["violations"] as? Int == 0, "strict-existing-owned-proxy-not-ready")
        try require(!healthy || ["owned-unread-healthy", "controlled-existing-seen"].contains(start["mode"] as? String ?? ""), "healthy-retry-not-authorized")
        let before = try ledger();let route = "PATCH /api/users/notifications/\(id)/see"
        try require(before.keys.allSatisfy { $0.hasPrefix("GET ") }, "unexpected-write-before-notification-tap")
        try proof("first-row-tap-intent", ["method": "PATCH", "existingOwnedRecord": true, "expectedActualForwarded": 0])
        row.tap()
        try require(app.scrollViews["notification-detail"].waitForExistence(timeout: 10), "actual-row-select-did-not-open-details")
        var response: [String: Any] = [:]
        for _ in 0..<20 {
            response = try control()
            if response["fault500ResponseWritten"] as? Int == 1 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try require(response["fault500ResponseWritten"] as? Int == 1 && response["fault500"] as? Int == 1 && response["seenAttempts"] as? Int == 1
            && response["actualSeenForwarded"] as? Int == 0 && response["violations"] as? Int == 0,
            "one-real-http500-zero-forwarding-required")
        var observedManagedError = app.staticTexts[error].exists
        try dismissDetails()
        for _ in 0..<10 {
            if app.staticTexts[error].exists { observedManagedError = true;break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let observedUnread = unread(row)
        try privateBytes("after-http500-owned-row-private.png", row.screenshot().pngRepresentation)
        try privateBytes("after-http500-screen-private.png", app.screenshot().pngRepresentation)
        let writes = try ledger().filter { !$0.key.hasPrefix("GET ") }
        try proof("http500-observed-state", ["realHTTP500": true, "actualSeenForwarded": 0,
            "rowUnread": observedUnread, "managedErrorVisible": observedManagedError,
            "rowRetryHittable": row.isHittable && row.isEnabled, "unexpectedTechnicalCopy": app.staticTexts["QA_INTERNAL_SEEN_FAILURE_SENTINEL"].exists,
            "nativeWriteCounts": writes, "proxyState": response])
        try require(writes == [route: 1], "one-exact-PATCH-attempt-and-no-other-write")
        try require(observedUnread, "RED-seen-HTTP500-must-not-mark-row-read")
        try require(observedManagedError, "RED-seen-HTTP500-must-show-managed-error")
        try require(row.isHittable && row.isEnabled && app.navigationBars[title].exists, "same-row-safe-retry-must-remain-available")
        try require(!app.staticTexts["QA_INTERNAL_SEEN_FAILURE_SENTINEL"].exists, "raw-technical-error-must-not-leak")
        Thread.sleep(forTimeInterval: 2)
        let quiet = try control()
        try require(quiet["seenAttempts"] as? Int == 1 && quiet["actualSeenForwarded"] as? Int == 0, "no-automatic-seen-retry")
        guard healthy else { return } // Strict RED allocation ends with zero server writes.
        try proof("explicit-user-retry-intent", ["maximumAdditionalNativePATCH": 1, "sameExistingOwnedRecord": true])
        row.tap()
        var after: [String: Any] = [:]
        for _ in 0..<30 {
            after = try control()
            if after["seenAttempts"] as? Int == 2 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try require(after["seenAttempts"] as? Int == 2 && after["fault500"] as? Int == 1 && after["violations"] as? Int == 0, "one-deliberate-retry-only")
        try dismissDetails()
        try wait("healthy-ack-must-clear-unread") { !self.unread(row) }
        let finalWrites = try ledger().filter { !$0.key.hasPrefix("GET ") }
        try require(finalWrites == [route: 2], "exactly-two-native-PATCH-attempts-only")
        try require((after["actualSeenForwarded"] as? Int == 1 && after["controlledHealthy200"] as? Int == 0)
            || (after["actualSeenForwarded"] as? Int == 0 && after["controlledHealthy200"] as? Int == 1),
            "healthy-retry-must-have-exactly-one-authorized-real-or-controlled-ack")
        try privateBytes("after-healthy-retry-row-private.png", row.screenshot().pngRepresentation)
        try proof("healthy-retry-observed-state", ["rowUnread": unread(row), "proxyState": after, "nativeWriteCounts": finalWrites])
    }
}
