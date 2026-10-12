import XCTest

/// Camera capture and camera permission on a physical iPhone (the Simulator has no
/// camera). Each test needs a fresh install, so the permission prompt appears:
/// `testCameraDenied`, then reinstall, then `testCameraAllowedCaptureThenCancel`.
/// Nothing is uploaded: the picture is discarded at the crop screen, and the server's
/// photo is checked to be unchanged.
extension XCUIElement {
    var isHeader: Bool { (value(forKey: "traits") as? UInt64).map { $0 & UInt64(UIAccessibilityTraits.header.rawValue) != 0 } ?? false }
}

final class DeviceCameraTests: XCTestCase {
    var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        #if targetEnvironment(simulator)
        throw XCTSkip("needs a physical iPhone with a camera")
        #endif
    }

    override func tearDown() {
        // Camera content and private profile details must not enter attachments.
        if !name.contains("testCamera"), let run = testRun, run.failureCount > 0 { shot("zz-failure-\(name)") }
        app?.terminate()
    }

    func testCameraDenied() throws {
        let photoBefore = try serverPhoto()
        openCameraChoice()
        XCTAssertTrue(springboard.alerts.firstMatch.waitForExistence(timeout: 15), "no camera permission prompt (is this a fresh install?)")
        let deny = springboard.alerts.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Don")).firstMatch
        shot("cam-1-permission-prompt")
        deny.tap()
        let explanation = app.alerts.firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 10), "denied: no explanation shown")
        XCTAssertTrue(explanation.buttons["Settings"].exists, "denied: no way to Settings")
        XCTAssertTrue(explanation.buttons["Gallery"].exists, "denied: no gallery alternative")
        shot("cam-2-denied-explained")
        explanation.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Save"].firstMatch.waitForExistence(timeout: 10), "denied: the form was lost")
        // Tapping Camera again goes straight to the explanation (no second prompt).
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Photo")).firstMatch.tap()
        app.buttons["Camera"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10), "denied again: no explanation")
        app.alerts.firstMatch.buttons["Cancel"].tap()
        assertNoPhotoWrites()
        XCTAssertTrue(try serverPhoto() == photoBefore, "the server photo changed")
    }

    func testCameraAllowedCaptureThenCancel() throws {
        let photoBefore = try serverPhoto()
        openCameraChoice()
        XCTAssertTrue(springboard.alerts.firstMatch.waitForExistence(timeout: 15), "no camera permission prompt (is this a fresh install?)")
        let allow = springboard.alerts.firstMatch.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Allow", "OK")).firstMatch
        allow.tap()
        let shutter = app.buttons["PhotoCapture"].exists ? app.buttons["PhotoCapture"] : app.buttons["Take Picture"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 20), "the camera did not open")
        shot("cam-3-camera-open")
        shutter.tap()
        let use = app.buttons["Use Photo"]
        XCTAssertTrue(use.waitForExistence(timeout: 20), "no captured-photo preview")
        let retake = app.buttons["Retake"]
        XCTAssertTrue(retake.waitForExistence(timeout: 5), "Captured photo must support retaking")
        retake.tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 10), "Retake did not reopen the camera")
        shutter.tap()
        XCTAssertTrue(use.waitForExistence(timeout: 20), "Retaken photo preview missing")
        use.tap()
        let confirm = app.buttons["Confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "the crop screen did not open for the captured photo")
        app.pinch(withScale: 1.5, velocity: 1)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)))
        XCTAssertTrue(confirm.exists && app.buttons["Cancel"].firstMatch.isHittable,
                      "Crop gestures must preserve usable controls")
        shot("cam-4-crop")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Save"].firstMatch.waitForExistence(timeout: 10), "Cancel did not return to the form")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Remove Photo")).firstMatch.exists && photoBefore == "nil",
                       "a discarded capture was applied")
        assertNoPhotoWrites()
        app.terminate()
        XCTAssertTrue(try serverPhoto() == photoBefore, "the server photo changed after a cancelled capture")
    }

    /// What VoiceOver would read on the new match screens, in order, on the device: every
    /// accessibility element with its label and role, plus Xcode's accessibility audit.
    /// A stand-in for listening with VoiceOver, which needs a person.
    func testMatchScreensAccessibilityOnDevice() throws {
        try XCTSkipIf(true, "Quarantined unsafe legacy fixture: Legacy device match setup mutates relationships without strict owned-pair verification. Use the strict owned-pair simulator match suites; physical camera remains separately gated.")

        let clientToken = try CarezaarAPI.login(env["QA_EMAIL"] ?? "", env["QA_PASSWORD"] ?? "")
        let cgToken = try CarezaarAPI.login(env["QA_CG_EMAIL"] ?? "", env["QA_CG_PASSWORD"] ?? "")
        let clientId = "\(try CarezaarAPI.me(clientToken)["id"] ?? "")"
        let cgId = "\(try CarezaarAPI.me(cgToken)["id"] ?? "")"
        _ = try CarezaarAPI.call("POST", "users/matches", form: ["partner_id": clientId,
            "introduction": "Hello! I'm an experienced caregiver, available weekday mornings. Happy to talk."], token: cgToken)
        defer {
            let p = CarezaarAPI.result((try? CarezaarAPI.call("GET", "caregivers/clients/\(clientId)", token: cgToken)) ?? [:])
            if let id = p["match_id"] as? Int { _ = try? CarezaarAPI.call("DELETE", "users/matches/\(id)", token: cgToken) }
        }
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"] ?? ""
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"] ?? ""
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-push", "CaregiverDetails/\(cgId)"]
        app.launch()
        if springboard.buttons["Allow"].waitForExistence(timeout: 6) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue(app.buttons["match-accept"].waitForExistence(timeout: 40), "received profile")
        var report = "== Profile, request received\n" + readingOrder()
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .trait]) { issue in
            report += "AUDIT \(issue.compactDescription): \(issue.element?.label ?? "-")\n"; return true
        }
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "experienced caregiver")).firstMatch.exists,
                       "received introduction must not appear above profile")
        XCTAssertTrue(app.buttons["match-accept"].label.contains("Accept") && app.buttons["match-reject"].label.contains("Reject"))
        app.buttons["match-accept"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        report += "== Accept confirmation\n" + app.alerts.firstMatch.descendants(matching: .any).allElementsBoundByIndex
            .filter { !$0.label.isEmpty }.map { "\($0.elementType.rawValue) \($0.label)" }.joined(separator: "\n") + "\n"
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "experienced caregiver")).firstMatch.exists,
                      "full introduction must be accessible in Accept confirmation")
        app.alerts.firstMatch.buttons["Accept"].tap()
        let heading = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "have matched")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 40), "It's a Match!")
        sleep(1)
        report += "== It's a Match!\n" + readingOrder()
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .trait]) { issue in
            report += "AUDIT \(issue.compactDescription): \(issue.element?.label ?? "-")\n"; return true
        }
        XCTAssertTrue(heading.isHeader, "the prompt is not announced as a heading")
        print("QA-A11Y-BEGIN\n\(report)QA-A11Y-END")
        let a = XCTAttachment(string: report); a.name = "reading-order"; a.lifetime = .keepAlways; add(a)
    }

    /// Elements in on-screen order (top to bottom, then leading to trailing), as VoiceOver
    /// swipes through them: role and label.
    private func readingOrder() -> String {
        let items = app.descendants(matching: .any).allElementsBoundByIndex.filter {
            !$0.label.isEmpty && $0.isHittable && [.button, .staticText, .image, .textField].contains($0.elementType)
        }
        return items.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            .map { "\($0.elementType == .button ? "Button" : $0.elementType == .staticText ? "Text" : "Other")\($0.isHeader ? " (heading)" : ""): \($0.label)" }
            .joined(separator: "\n") + "\n"
    }

    /// With VoiceOver switched on by a person on the device: drives it with its own
    /// gestures (swipe right = next item, double-tap = activate) and records a screenshot
    /// per step, so the focus ring and Caption Panel text show what VoiceOver spoke.
    func testVoiceOverWalk() throws {
        let steps = Int(env["QA_VO_STEPS"] ?? "6") ?? 6
        app.activate()
        sleep(2)
        shot("vo-00-start")
        for i in 1...steps {
            app.swipeRight()
            usleep(1_500_000)
            shot(String(format: "vo-%02d", i))
        }
    }

    // MARK: Helpers

    private func openCameraChoice() {
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", "ProfileEdit",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let notifications = springboard.buttons["Allow"]
        if notifications.waitForExistence(timeout: 6) { notifications.tap() }
        let upload = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Photo")).firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 40), "profile form")
        // A tap while the form is still loading its profile is ignored; retry.
        let busy = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch
        for _ in 0..<4 where !app.buttons["Camera"].exists {
            _ = busy.waitForNonExistence(timeout: 30)
            upload.tap()
            _ = app.buttons["Camera"].waitForExistence(timeout: 5)
        }
        XCTAssertTrue(app.buttons["Camera"].exists, "Camera / Gallery choice")
        app.buttons["Camera"].tap()
    }

    private func serverPhoto() throws -> String {
        guard let email = env["QA_EMAIL"], !email.isEmpty,
              let password = env["QA_PASSWORD"], !password.isEmpty,
              let clientID = env["QA_CLIENT_USER_ID"], !clientID.isEmpty,
              let caregiverID = env["QA_CG_ID"], !caregiverID.isEmpty else {
            throw XCTSkip("Exact authorized camera fixture identities and credentials required")
        }
        let token = try CarezaarAPI.login(email, password)
        let user = try CarezaarAPI.me(token)
        let role = user["role"] as? String ?? ""
        let id = user["id"].map { String(describing: $0) } ?? ""
        guard !token.isEmpty, (role == "client" && id == clientID) || (role == "caregiver" && id == caregiverID) else {
            XCTFail("Refusing camera test outside the authorized exact role/identity pair")
            throw URLError(.userAuthenticationRequired)
        }
        return "\(user["photo"] ?? "nil")"
    }

    private func assertNoPhotoWrites() {
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.exists, "Native request ledger required to verify capture privacy")
        for route in ["POST /api/users/profile", "PUT /api/users/profile", "PATCH /api/users/profile"] {
            let line = ledger.label.split(separator: "\n").first { $0.hasPrefix(route + "=") }
            let count = line.flatMap { Int($0.dropFirst(route.count + 1)) } ?? 0
            XCTAssertEqual(count, 0, "Cancelled capture must not submit a profile write")
        }
    }

    private func shot(_ name: String) {
        if name.hasPrefix("cam-") {
            let a = XCTAttachment(string: "Physical-camera checkpoint: \(name); image intentionally excluded.")
            a.name = name; a.lifetime = .keepAlways; add(a)
            return
        }
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
