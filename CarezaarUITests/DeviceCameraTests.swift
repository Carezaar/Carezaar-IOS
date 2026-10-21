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

    /// `expectPermissionPrompt` is documentation only: the caller asserts the prompt itself.
    private func openCameraChoice(expectPermissionPrompt: Bool = true) {
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", "ProfileEdit",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let notifications = springboard.buttons["Allow"]
        if notifications.waitForExistence(timeout: 6) { notifications.tap() }
        // With notifications allowed, the app's "New Notification(s)" banner follows the first
        // poll; XCTest's interruption handling tapped it on the iPhone and opened Notifications.
        // Let it finish before using the form.
        let banner = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
        if banner.waitForExistence(timeout: 15) { _ = banner.waitForNonExistence(timeout: 20) }
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

    /// Run after `testCameraAllowedCaptureThenCancel` on the same install (camera already
    /// allowed). Turns Camera off in Settings, checks the app explains instead of opening it,
    /// turns Camera back on and checks the camera opens again. Nothing is captured or saved.
    func testCameraRevokeInSettingsThenReenable() throws {
        let photoBefore = try serverPhoto()
        try setCameraAccess(false)
        openCameraChoice(expectPermissionPrompt: false)
        let explanation = app.alerts.firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 10), "revoked: no explanation shown")
        XCTAssertTrue(explanation.buttons["Settings"].exists && explanation.buttons["Gallery"].exists, "revoked: Settings and Gallery offered")
        shot("cam-5-revoked-explained")
        explanation.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Save"].firstMatch.waitForExistence(timeout: 10), "revoked: the form was lost")
        assertNoPhotoWrites()
        app.terminate()
        try setCameraAccess(true)
        openCameraChoice(expectPermissionPrompt: false)
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 3), "re-enabled: no new permission prompt")
        let shutter = app.buttons["PhotoCapture"].exists ? app.buttons["PhotoCapture"] : app.buttons["Take Picture"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 20), "re-enabled: the camera did not open")
        shot("cam-6-reenabled-camera-open")
        // Nothing was captured; close the app from the live camera (the system camera's own
        // close control is not exposed as "Cancel" on this device) and check the server photo.
        app.terminate()
        XCTAssertTrue(try serverPhoto() == photoBefore, "the server photo changed")
    }

    // MARK: Device network and interruptions (owner approved the test toggling his iPhone)

    private func controlCenterToggle(_ labels: [String]) -> XCUIElement {
        springboard.descendants(matching: .any).matching(NSPredicate(format: "label IN %@ OR identifier IN %@", labels, labels)).firstMatch
    }
    private func openControlCenter() {
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.005))
        start.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.6)))
    }
    private func closeControlCenter() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        app.activate()
    }
    private func set(_ labels: [String], on: Bool) {
        openControlCenter()
        let toggle = controlCenterToggle(labels)
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "Control Center toggle \(labels[0])")
        if ((toggle.value as? String) == "1") != on { toggle.tap() }
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", on ? "1" : "0"), object: toggle)
        _ = XCTWaiter.wait(for: [settled], timeout: 8)
        closeControlCenter()
    }
    private func requestCount(_ key: String) -> Int {
        let ledger = app.staticTexts["qa-request-counts"]
        return ledger.label.split(separator: "\n").first { $0.hasPrefix(key + "=") }.flatMap { Int($0.dropFirst(key.count + 1)) } ?? 0
    }

    /// P09-009 (as available on this phone): the iPhone is on mobile data (Wi-Fi not joined),
    /// so the real network change is mobile data off and on again mid-session. Offline, a list
    /// reload shows the managed connection message; back online it recovers; nothing is written.
    /// Mobile data is switched back on at the end whatever happens.
    func testWiFiToCellularAndAirplaneDuringUseRecovers() throws {
        guard env["QA_DEVICE_NETWORK_TOGGLE"] == "1" else { throw XCTSkip("Owner-approved device network toggling not enabled") }
        func mobileData() -> XCUIElement {
            springboard.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Mobile Data", "Cellular Data")).firstMatch
        }
        func tapMobileData() {
            openControlCenter()
            let tile = mobileData()
            XCTAssertTrue(tile.waitForExistence(timeout: 8), "Mobile Data control in Control Center")
            tile.tap(); sleep(2)
            closeControlCenter(); sleep(4)
        }
        var dataOff = false
        defer {
            if dataOff { tapMobileData() }
        }
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]; app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        if springboard.buttons["Allow"].waitForExistence(timeout: 6) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60), "signed in over mobile data")
        let banner = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
        if banner.waitForExistence(timeout: 10) { _ = banner.waitForNonExistence(timeout: 20) }
        tapMobileData(); dataOff = true
        let list = app.scrollViews.firstMatch
        list.swipeDown(velocity: .slow)
        let failure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Cannot communicate")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 40), "with no network a reload shows the managed connection message")
        shot("net-1-offline-message")
        tapMobileData(); dataOff = false
        sleep(6)
        list.swipeDown(velocity: .slow)
        let card = app.buttons.matching(identifier: "MatchCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 60), "the list recovers once mobile data is back")
        for write in ["POST /api/users/matches", "POST /api/users/chats", "PUT /api/clients/profile", "PUT /api/caregivers/profile", "POST /api/users/profile"] {
            XCTAssertEqual(requestCount(write), 0, "no mutation while the network changed (\(write))")
        }
        shot("net-2-recovered")
    }

    /// Diagnostic only: saves Control Center's accessibility tree so the network test can
    /// address its real controls on this iOS version. Changes nothing.
    func testDumpControlCenterTree() throws {
        guard env["QA_DEVICE_NETWORK_TOGGLE"] == "1" else { throw XCTSkip("diagnostic not enabled") }
        app.launch(); sleep(2)
        openControlCenter(); sleep(2)
        let a = XCTAttachment(string: springboard.debugDescription); a.name = "control-center-tree"; a.lifetime = .keepAlways; add(a)
        closeControlCenter()
    }

    /// P09-009, person-guided: iOS 26 does not expose Control Center's network tiles to XCTest,
    /// so the owner switches Mobile Data off and on while this test watches the app. The app
    /// must show the managed connection message while offline, recover afterwards, and write nothing.
    func testGuidedMobileDataOffAndOnDuringUse() throws {
        guard env["QA_DEVICE_GUIDED"] == "1" else { throw XCTSkip("person-guided network check not enabled") }
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]; app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        if springboard.buttons["Allow"].waitForExistence(timeout: 6) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 90), "signed in")
        sleep(5)
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@", "communicate", "internet", "connection")).firstMatch
        let list = app.scrollViews.firstMatch
        var offline = false
        for _ in 0..<36 where !offline { // up to 6 minutes for the owner to turn Mobile Data off
            app.activate(); list.swipeDown(velocity: .slow); offline = failure.waitForExistence(timeout: 8)
            if !offline { app.buttons["Messages"].tap(); sleep(2); app.buttons["Matches"].firstMatch.tap(); offline = failure.waitForExistence(timeout: 6) }
        }
        XCTAssertTrue(offline, "offline: the managed connection message appears")
        shot("guided-net-offline")
        var recovered = false
        for _ in 0..<36 where !recovered { // up to 6 minutes for the owner to turn it back on
            sleep(4); app.activate(); list.swipeDown(velocity: .slow); sleep(6)
            recovered = !failure.exists && !app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch.exists
        }
        XCTAssertTrue(recovered, "back online: the list recovers")
        for write in ["POST /api/users/matches", "POST /api/users/chats", "PUT /api/clients/profile", "PUT /api/caregivers/profile", "POST /api/users/profile"] {
            XCTAssertEqual(requestCount(write), 0, "no mutation while the network changed (\(write))")
        }
    }

    /// P10-010, person-guided: a real incoming phone call while a profile edit is unsaved. The
    /// owner calls the iPhone, ends the call and returns to Carezaar; the edit must still be there.
    func testGuidedIncomingCallKeepsUnsavedEdit() throws {
        guard env["QA_DEVICE_GUIDED"] == "1" else { throw XCTSkip("person-guided call check not enabled") }
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]; app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", "ProfileEdit", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        if springboard.buttons["Allow"].waitForExistence(timeout: 6) { springboard.buttons["Allow"].tap() }
        let bio = app.textFields["Tell us a little about yourself."]
        XCTAssertTrue(bio.waitForExistence(timeout: 40), "profile form")
        for _ in 0..<4 where !bio.isHittable { app.swipeUp() }
        bio.tap(); bio.typeText(" call-check")
        let edited = app.textFields.matching(NSPredicate(format: "value CONTAINS %@", "call-check")).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        let typed = edited.value as? String ?? ""
        let interrupted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.app.state != .runningForeground }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [interrupted], timeout: 360), .completed, "the incoming call interrupts the app")
        let back = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.app.state == .runningForeground }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: 360), .completed, "the owner returned to Carezaar after the call")
        XCTAssertTrue(edited.waitForExistence(timeout: 15), "the form is still open")
        XCTAssertEqual(edited.value as? String, typed, "the unsaved edit survives the call")
        assertNoPhotoWrites()
    }

    /// P10-010 (system interruption): Siri over an unsaved profile edit, then back to the app.
    /// The typed value is kept, nothing is saved and the session stays. A real phone call cannot
    /// be placed from XCTest; this is the system interruption it can trigger on a device.
    func testSiriInterruptionKeepsUnsavedEditAndSession() throws {
        guard env["QA_DEVICE_INTERRUPTION"] == "1" else { throw XCTSkip("Owner-approved device interruption not enabled") }
        let photoBefore = try serverPhoto()
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]; app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", "ProfileEdit",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        if springboard.buttons["Allow"].waitForExistence(timeout: 6) { springboard.buttons["Allow"].tap() }
        let banner = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
        if banner.waitForExistence(timeout: 10) { _ = banner.waitForNonExistence(timeout: 20) }
        let bio = app.textFields["Tell us a little about yourself."]
        XCTAssertTrue(bio.waitForExistence(timeout: 40), "profile form")
        let marker = " siri-check"
        for _ in 0..<4 where !bio.isHittable { app.swipeUp() }
        bio.tap(); bio.typeText(marker)
        // Once text is typed the placeholder query no longer matches; follow the field by its text.
        let edited = app.textFields.matching(NSPredicate(format: "value CONTAINS %@", marker.trimmingCharacters(in: .whitespaces))).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 5), "typed text is in the bio field")
        let typed = edited.value as? String ?? ""
        XCUIDevice.shared.siriService.activate(voiceRecognitionText: "What time is it")
        sleep(6)
        // On iOS 26 Siri opens as an overlay, so the app can stay in the foreground under it.
        // Follow it with a real trip to the Home screen, which does background the app.
        // The first Home press closes the Siri overlay; the second goes to the Home screen.
        XCUIDevice.shared.press(.home); sleep(2)
        if app.state == .runningForeground { XCUIDevice.shared.press(.home) }
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.app.state != .runningForeground }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed, "the app went to the background")
        app.activate()
        XCTAssertTrue(edited.waitForExistence(timeout: 15), "back on the same form with the edit")
        XCTAssertEqual(edited.value as? String, typed, "the unsaved edit survives the interruption")
        assertNoPhotoWrites()
        app.terminate()
        XCTAssertTrue(try serverPhoto() == photoBefore)
    }

    /// Settings → Apps → Carezaar → Camera switch, set to the requested state and verified.
    private func setCameraAccess(_ allowed: Bool) throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate(); settings.launch()
        func open(_ label: String) throws {
            let row = settings.cells.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).firstMatch
            let any = settings.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).firstMatch
            for _ in 0..<12 where !(row.exists && row.isHittable) && !(any.exists && any.isHittable) { settings.swipeUp() }
            if row.exists && row.isHittable { row.tap() } else if any.exists && any.isHittable { any.tap() }
            else { XCTFail("Settings row \(label) not reachable"); throw URLError(.cannotParseResponse) }
        }
        try open("Apps"); try open("Carezaar")
        let camera = settings.switches["Camera"]
        for _ in 0..<6 where !(camera.exists && camera.isHittable) { settings.swipeUp() }
        XCTAssertTrue(camera.exists && camera.isHittable, "Camera switch in Carezaar's Settings")
        if (camera.value as? String == "1") != allowed {
            // The row is exposed as the switch; its control sits at the trailing edge.
            camera.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", allowed ? "1" : "0"), object: camera)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed, "Camera switch must reach the requested state")
        settings.terminate()
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

/// P17-002 on the physical iPhone, performed by a person. The test turns on VoiceOver's caption
/// panel in Settings, opens Carezaar signed in, turns VoiceOver on through Siri, then only records a
/// screenshot every 2 s while the owner swipes (it sends no input, so VoiceOver gets only the
/// person's gestures). Afterwards it turns VoiceOver off through Siri and restores the caption panel.
final class DeviceVoiceOverRecordingTests: XCTestCase {
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private func openVoiceOverSettings() -> Bool {
        settings.terminate(); settings.launch()
        let accessibility = settings.cells.staticTexts["Accessibility"].firstMatch
        for _ in 0..<6 where !accessibility.isHittable { settings.swipeUp() }
        guard accessibility.waitForExistence(timeout: 10) else { return false }
        accessibility.tap()
        let vo = settings.cells.staticTexts["VoiceOver"].firstMatch
        guard vo.waitForExistence(timeout: 10) else { return false }
        vo.tap(); return settings.switches.firstMatch.waitForExistence(timeout: 10)
    }
    private func captionSwitch() -> XCUIElement {
        let s = settings.switches.matching(NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", "Caption", "Caption")).firstMatch
        for _ in 0..<8 where !s.exists || !s.isHittable { settings.swipeUp() }
        return s
    }
    func testRecordPersonsVoiceOverWalk() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_DEVICE_VOICEOVER"] == "1" else { throw XCTSkip("Physical iPhone run only (QA_DEVICE_VOICEOVER=1)") }
        var captionWasOn = true
        if openVoiceOverSettings() {
            let caption = captionSwitch()
            if caption.exists { captionWasOn = caption.value as? String == "1"; if !captionWasOn { caption.tap() } }
        }
        addTeardownBlock { [self] in
            XCUIDevice.shared.siriService.activate(voiceRecognitionText: "Turn off VoiceOver"); sleep(6)
            if !captionWasOn, openVoiceOverSettings() { let c = captionSwitch(); if c.exists, c.value as? String == "1" { c.tap() } }
            settings.terminate()
        }
        let app = XCUIApplication()
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]; app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sort")).firstMatch.waitForExistence(timeout: 90)
        XCUIDevice.shared.siriService.activate(voiceRecognitionText: "Turn on VoiceOver"); sleep(6)
        app.activate()
        let seconds = Int(env["QA_VO_SECONDS"] ?? "240") ?? 240
        for i in 0..<(seconds / 2) {
            sleep(2)
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = String(format: "vo-person-%03d", i); a.lifetime = .keepAlways; add(a)
        }
    }
}
