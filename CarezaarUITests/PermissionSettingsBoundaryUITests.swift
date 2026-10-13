import XCTest

/// Representative real simulator OS permission and accessibility checks. Each fresh-decision method
/// needs its own fresh isolated simulator; the decided-state method reuses only
/// that task's previously decided device. No TCC edits, permission mocks, GPS,
/// camera, uploads, remote push delivery, or four-allocation coverage claim.
final class PermissionSettingsBoundaryUITests: XCTestCase {
    private var app = XCUIApplication()
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private struct Owner { let token: String, role: String, id: String }
    override func setUp() { continueAfterFailure = false }
    override func tearDown() { app.terminate(); settings.terminate(); super.tearDown() }

    func testFreshNotificationAllowThenSettingsDenyKeepsOwnedSessionUsable() throws {
        try notificationDecision(allow: true)
    }
    func testFreshNotificationDenyThenSettingsAllowKeepsOwnedSessionUsable() throws {
        try notificationDecision(allow: false)
    }
    /// Independent initial-denial evidence; no Settings change coverage.
    func testFreshNotificationDenyKeepsOwnedSessionUsableAfterOrdinaryRelaunch() throws {
        try notificationDecision(allow: false, initialOnly: true)
    }

    /// Settings-only continuation after a separately observed real OS decision.
    /// This method cannot supply notDetermined or initial-prompt evidence.
    func testOwnedDecidedNotificationSettingsChangeAndRestore() throws {
        let owner = try ownedFixture()
        guard let decision = env["QA_EXPECT_NOTIFICATION_DECISION"], ["allow", "deny"].contains(decision) else {
            throw XCTSkip("Root must specify the previously observed decision on this task-owned device")
        }
        try relaunchPersistedSession() // Ordinary launch, no forced login/signout.
        try verifySettingsChange(owner: owner, allow: decision == "allow", initialPromptObserved: false)
    }

    private func notificationDecision(allow: Bool, initialOnly: Bool = false) throws {
        let owner = try ownedFixture()
        guard env["QA_EXPECT_NOTIFICATION_DECISION"] == (allow ? "allow" : "deny") else {
            throw XCTSkip("Root must choose the fresh isolated simulator's single initial decision")
        }
        launchOwned()
        let alert = notificationAlert()
        XCTAssertTrue(alert.waitForExistence(timeout: 60), "Real notDetermined notification prompt required; an already-decided simulator cannot pass")
        let yes = alert.buttons["Allow"]
        let no = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
        XCTAssertTrue(yes.exists && yes.isHittable && no.exists && no.isHittable)
        proof(alert, "notification-real-initial-permission-alert")
        (allow ? yes : no).tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 10))
        try assertSessionUsable()
        try relaunchPersistedSession()
        if initialOnly {
            try record("real-notification-initial-denial-session-only", ["role": owner.role,
                "initialOSPromptObserved": true, "initialDecisionAllowed": allow,
                "ownedSessionUsableAfterOrdinaryRelaunch": true, "noRepeatedPromptDuringBoundedObservation": true,
                "settingsChanged": false, "nativeSettingsChangedAndRestored": false,
                "remoteNotificationDeliveryVerified": false])
            return
        }
        try verifySettingsChange(owner: owner, allow: allow, initialPromptObserved: true)
    }

    private func verifySettingsChange(owner: Owner, allow: Bool, initialPromptObserved: Bool) throws {
        let toggle = try notificationSettingsSwitch()
        let original = try switchState(toggle)
        XCTAssertEqual(original, allow, "Actual Settings state must agree with the observed system decision")
        proof(toggle, "notification-settings-original-switch-only")
        var needsRestore = false
        defer {
            if needsRestore {
                do {
                    settings.activate()
                    let current = try requireVisible(settings.switches["Allow Notifications"])
                    if try switchState(current) != original { try tapNotificationToggle(current) }
                    XCTAssertEqual(try switchState(current), original, "Original permission must be restored")
                } catch { XCTFail("Could not restore original notification Settings switch: \(error)") }
            }
        }
        needsRestore = true // Set before tapping so failure after a UI mutation still restores.
        try tapNotificationToggle(toggle)
        try waitSwitch(toggle, equals: !original)
        proof(toggle, "notification-settings-changed-switch-only")
        app.activate()
        try assertSessionUsable()
        try assertNoRepeatedPrompt()
        try relaunchPersistedSession()
        settings.activate()
        let restored = try requireVisible(settings.switches["Allow Notifications"])
        if try switchState(restored) != original { try tapNotificationToggle(restored) }
        try waitSwitch(restored, equals: original)
        proof(restored, "notification-settings-restored-switch-only")
        needsRestore = false
        try record(initialPromptObserved ? "real-notification-permission-and-settings" : "decided-notification-settings-only", ["role": owner.role,
            "initialOSPromptObserved": initialPromptObserved,
            "initialOSPromptObservedInThisMethod": initialPromptObserved, "expectedOriginalPermissionAllowed": allow,
            "nativeSettingsChangedAndRestored": true, "ownedSessionUsableAfterRelaunch": true,
            "remoteNotificationDeliveryVerified": false])
    }

    func testActualOSLocationDeniedMapContinueKeepsNilWithoutProfileWrites() throws {
        let owner = try ownedFixture()
        guard env["QA_EXPECT_LOCATION_DENIED"] == "true" else {
            throw XCTSkip("Root must revoke actual location permission on the isolated simulator before launch")
        }
        try openAppSettings()
        let location = try revealSettingsRow("Location")
        XCTAssertTrue(location.label == "Location, Never"
                      || String(describing: location.value ?? "").contains("Never") || location.staticTexts["Never"].exists,
                      "Actual native app Settings must show Never; fixture denial is not OS evidence")
        proof(location, "location-native-settings-never-only")
        let endpoint = owner.role == "client" ? "clients/profile" : "caregivers/profile"
        let original = try profile(owner, endpoint)
        let contents = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: owner.token)
        XCTAssertEqual(contents.status, 200)
        let rows = try XCTUnwrap(contents.body["result"] as? [[String: Any]])
        func text(_ key: String) throws -> String {
            let row = try XCTUnwrap(rows.first { $0["slug"] as? String == key })
            return try XCTUnwrap((row["translations"] as? [[String: Any]])?.first {
                ($0["language_id"] as? NSNumber)?.intValue == 1 || ($0["language_id"] as? String) == "1"
            }?["name"] as? String)
        }
        launchOwned(extra: ["--qa-push", owner.role == "client" ? "ClientPreferences" : "CaregiverSkills",
            "--qa-owned-profile-no-location", "GET", endpoint])
        answerNotificationIfPresent()
        let attestation = app.staticTexts["qa-profile-no-location"]
        XCTAssertTrue(attestation.waitForExistence(timeout: 60))
        XCTAssertEqual(attestation.label, "path=\(endpoint) owned=true latitude=nil longitude=nil")
        XCTAssertFalse(app.staticTexts["qa-location-fixture"].exists, "Actual LocationProvider, without controlled location mode, is required")
        let next = app.buttons[try text("signup_form_client_continue")].firstMatch
        let prefilled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            next.exists && next.isEnabled && next.isHittable && !self.app.staticTexts["Please wait..."].exists
                && self.app.buttons.allElementsBoundByIndex.contains { $0.exists && $0.isSelected }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [prefilled], timeout: 30), .completed)
        next.tap()
        let second = app.staticTexts[try text(owner.role == "client" ? "signup_form_client_tell_us_about_needs" : "signup_form_caregiver_skill_title")]
        XCTAssertTrue(second.waitForExistence(timeout: 15)); next.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", try text("signup_form_client_location_hint"))).firstMatch
        try reveal(row); row.tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", try text("general_confirm"))).allElementsBoundByIndex.contains { $0.isHittable })
        let proceed = try requireVisible(app.buttons[try text("general_continue")].firstMatch)
        XCTAssertTrue(proceed.isEnabled); proof(proceed, "actual-location-denied-map-continue-only"); proceed.tap()
        XCTAssertTrue(app.maps.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Location is unavailable.")).firstMatch.exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*-?[0-9]+\\.[0-9]{6} , -?[0-9]+\\.[0-9]{6}.*")).count, 0)
        let mutations = app.staticTexts["qa-request-counts"].label.split(separator: "\n").filter {
            $0.contains(" /api/clients") || $0.contains(" /api/caregivers")
        }.filter { !$0.hasPrefix("GET ") }
        XCTAssertTrue(mutations.allSatisfy { $0.hasSuffix("=0") }, "Denied read-only flow must make no profile mutations")
        let after = try profile(owner, endpoint)
        for key in ["lat", "lng", "shift_ids", "careday_ids", "commute_id", "commute_ids", "worktype_id", "worktype_ids", "salary_min", "salary_max"] {
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: [original[key] ?? NSNull()], options: [.sortedKeys]),
                           try JSONSerialization.data(withJSONObject: [after[key] ?? NSNull()], options: [.sortedKeys]), "Server preference changed: \(key)")
        }
        try record("actual-os-location-denied-native", ["role": owner.role, "nativeSettingsNeverObserved": true,
            "controlledLocationFixtureUsed": false, "mapContinuedWithoutSelection": true,
            "profileMutationRequests": 0, "physicalGPSVerified": false, "validSaveAttempted": false])
    }

    /// Uses only root's exact marker-owned ACTIVE pair. Native Settings supplies
    /// Reduced Motion; no launch argument or location fixture simulates this flag.
    /// Root restores its staged relationship after this read-only UI check.
    func testActualOSReducedMotionMatchedCardsAndNavigation() throws {
        let owner = try ownedFixture()
        guard env["QA_OWNED_MATCH_MOTION"] == "1",
              let edge = env["QA_MATCH_EDGE"], let marker = env["QA_MATCH_MARKER"],
              !edge.isEmpty, !marker.isEmpty else {
            throw XCTSkip("Requires root's exact marker-owned active relationship")
        }
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/matches/\(edge)", token: owner.token)
        XCTAssertEqual(response.status, 200)
        let relation = try XCTUnwrap(response.body["result"] as? [String: Any])
        func userID(_ role: String) -> String? {
            ((relation[role] as? [String: Any])?["user"] as? [String: Any])?["id"].map { String(describing: $0) }
        }
        guard relation["introduction"] as? String == marker,
              userID("client") == env["QA_CLIENT_USER_ID"], userID("caregiver") == env["QA_CG_ID"] else {
            throw URLError(.userAuthenticationRequired)
        }
        let peer = try XCTUnwrap(env[owner.role == "client" ? "QA_CG_ID" : "QA_CLIENT_USER_ID"])
        let endpoint = (owner.role == "client" ? "clients/caregivers/" : "caregivers/clients/") + peer
        let current = try CarezaarAPI.callWithHTTPStatus("GET", endpoint, token: owner.token)
        XCTAssertEqual(current.status, 200)
        XCTAssertEqual((current.body["result"] as? [String: Any])?["match_status"] as? String, "active")

        settings.launch()
        try returnSettingsToRoot()
        try tapSettingsRow("Accessibility")
        try tapSettingsRow("Motion")
        let toggle = try requireVisible(settings.switches["Reduce Motion"])
        let original = try switchState(toggle)
        proof(toggle, "motion-original-native-setting-only")
        addTeardownBlock { [self] in
            settings.activate()
            let restored = try requireVisible(settings.switches["Reduce Motion"])
            if try switchState(restored) != original {
                restored.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            }
            try waitSwitch(restored, equals: original)
            proof(restored, "motion-restored-native-setting-only")
        }
        if !original {
            // The observed native Settings screenshot exposes a wide AX row;
            // its switch is on the right. Tapping the title does not toggle it.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            try waitSwitch(toggle, equals: true)
        }
        proof(toggle, "motion-enabled-native-setting-only")
        let route = "Matched/\(owner.role == "client" ? "caregivers" : "clients")/\(peer)"
        launchOwned(extra: ["--qa-push", route, "--qa-push-delay", "10"])
        let own = app.descendants(matching: .any).matching(identifier: "matched-self-photo-card").firstMatch
        let other = app.descendants(matching: .any).matching(identifier: "matched-partner-photo-card").firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 60) && other.exists)
        var previous: (CGRect, CGRect)?
        var stable = 0
        let readyPredicate = NSPredicate { _, _ in
            let frames = (own.frame, other.frame)
            if let previous,
               abs(frames.0.midX - previous.0.midX) < 0.5,
               abs(frames.1.midX - previous.1.midX) < 0.5 { stable += 1 }
            else { stable = 0 }
            previous = frames
            return stable >= 3 && own.isHittable && other.isHittable
                && !self.app.staticTexts["Please wait..."].exists
        }
        let ready = XCTNSPredicateExpectation(predicate: readyPredicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        let first = (own.frame, other.frame)
        XCTAssertLessThan(abs(first.0.width - first.1.width), 25)
        XCUIDevice.shared.press(.home)
        app.activate()
        let foreground = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            own.exists && other.exists && abs(own.frame.midX - first.0.midX) <= 2
                && abs(other.frame.midX - first.1.midX) <= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [foreground], timeout: 5), .completed)
        let profile = try requireVisible(app.buttons["View Profile"].firstMatch)
        profile.tap()
        XCTAssertTrue(profile.waitForNonExistence(timeout: 30))
        var backs: [XCUIElement] = []
        let profileReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            backs = self.app.navigationBars.buttons.allElementsBoundByIndex.filter {
                $0.exists && $0.isHittable && !$0.frame.isEmpty && $0.frame.midX < self.app.frame.midX
            }
            return backs.count == 1 && !self.app.staticTexts["Please wait..."].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [profileReady], timeout: 30), .completed,
                       "Profile loading must finish before its native Back control is used")
        XCTAssertEqual(backs.count, 1, "Only the observed native back control is eligible")
        try XCTUnwrap(backs.first).tap()
        // View Profile intentionally pops Matched before opening the profile.
        // Its Back action therefore returns to Main, not to a retained Matched.
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 30))
        XCTAssertFalse(own.exists || other.exists)
        app.terminate()
        previous = nil
        stable = 0
        launchOwned(extra: ["--qa-push", route, "--qa-push-delay", "10"])
        XCTAssertTrue(own.waitForExistence(timeout: 60) && other.exists)
        let repeated = XCTNSPredicateExpectation(predicate: readyPredicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [repeated], timeout: 10), .completed)
        XCTAssertLessThan(abs(own.frame.width - other.frame.width), 25)
        try record("actual-os-reduced-motion-native-match", ["role": owner.role,
            "nativeSettingEnabledObserved": true, "controlledMotionFixtureUsed": false,
            "balancedCards": true, "freshPresentations": 2,
            "foregroundPreservesGeometry": true, "nativeViewProfileBackReturnsToMain": true,
            "slideRasterReviewRequired": true, "navigationDuringAnimationVerified": false])
    }

    private func ownedFixture() throws -> Owner {
        guard env["QA_PERMISSION_ISOLATED_SIMULATOR"] == "true", let email = env["QA_EMAIL"],
              let password = env["QA_PASSWORD"], let client = env["QA_CLIENT_USER_ID"],
              let caregiver = env["QA_CG_ID"], !client.isEmpty, !caregiver.isEmpty, client != caregiver else {
            throw XCTSkip("Task-owned isolated simulator and exact retained distinct owned identities required")
        }
        let token = try CarezaarAPI.login(email, password), me = try CarezaarAPI.me(token)
        let role = me["role"] as? String ?? "", id = me["id"].map { String(describing: $0) } ?? ""
        guard !token.isEmpty, me["email"] as? String == email,
              (role == "client" && id == client) || (role == "caregiver" && id == caregiver) else { throw URLError(.userAuthenticationRequired) }
        return Owner(token: token, role: role, id: id)
    }
    private func profile(_ owner: Owner, _ endpoint: String) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", endpoint, token: owner.token)
        XCTAssertEqual(response.status, 200)
        let value = try XCTUnwrap(response.body["result"] as? [String: Any])
        XCTAssertEqual((value["user"] as? [String: Any])?["id"].map { String(describing: $0) }, owner.id)
        return value
    }
    private func launchOwned(extra: [String] = []) {
        app.launchEnvironment = ["QA_EMAIL": env["QA_EMAIL"] ?? "", "QA_PASSWORD": env["QA_PASSWORD"] ?? "",
            "QA_CLIENT_USER_ID": env["QA_CLIENT_USER_ID"] ?? "", "QA_CG_ID": env["QA_CG_ID"] ?? ""]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts",
            "-carezaar.languageId", "1", "-carezaar.languageCode", "en"] + extra
        app.launch()
    }
    private func notificationAlert() -> XCUIElement {
        springboard.alerts.matching(NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "Carezaar", "notification")).firstMatch
    }
    private func answerNotificationIfPresent() {
        let alert = notificationAlert()
        if alert.waitForExistence(timeout: 6), alert.buttons["Allow"].isHittable { alert.buttons["Allow"].tap() }
    }
    private func assertSessionUsable() throws {
        let matches = try requireVisible(app.buttons["Matches"].firstMatch, timeout: 60)
        let profile = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label == %@", "Profile")).allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.max { $0.frame.midY < $1.frame.midY })
        profile.tap(); XCTAssertFalse(app.buttons["Sign in"].firstMatch.exists)
        XCTAssertTrue(matches.exists && matches.isHittable); matches.tap()
        proof(matches, "permission-authenticated-matches-tab-only")
    }
    private func relaunchPersistedSession() throws {
        app.terminate(); app.launchEnvironment = [:]; app.launchArguments = ["--qa-request-counts"]
        app.launch(); try assertSessionUsable(); try assertNoRepeatedPrompt()
    }
    private func assertNoRepeatedPrompt() throws {
        let absence = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.notificationAlert().exists }, object: nil)
        absence.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [absence], timeout: 4), .completed)
    }
    private func openAppSettings() throws {
        settings.terminate(); settings.launch()
        try returnSettingsToRoot()
        try tapSettingsRow("Apps")
        try tapSettingsRow("Carezaar")
    }
    private func notificationSettingsSwitch() throws -> XCUIElement {
        // Actual app-specific Settings AX exposes Notifications with a compound
        // summary label and an exact Notifications child text.
        try openAppSettings()
        try tapSettingsRow("Notifications")
        return try requireVisible(settings.switches["Allow Notifications"])
    }
    private func returnSettingsToRoot() throws {
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        for _ in 0..<6 {
            let bars = settings.navigationBars.allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
            if bars.contains(where: {
                $0.identifier == "Settings" || $0.label == "Settings"
                    || $0.staticTexts.matching(NSPredicate(format: "label == %@", "Settings")).firstMatch.exists
            }) { return }
            guard let bar = bars.first else {
                privateSettingsAX("root-return-no-navigation-bar")
                throw URLError(.cannotParseResponse)
            }
            let previousTitle = navigationTitle(bar)
            // Only an actually observed native navigation-bar back button is
            // eligible. Never tap a Settings content row to simulate going back.
            let back = bar.buttons.allElementsBoundByIndex.filter {
                $0.exists && $0.isHittable && !$0.frame.isEmpty
                    && ["Settings", "Apps", "Carezaar", "Notifications", "Back"].contains($0.label)
                    && $0.frame.midX < bar.frame.midX
            }.min { $0.frame.minX < $1.frame.minX }
            guard let back else {
                privateSettingsAX("root-return-no-observed-back-button")
                throw URLError(.cannotParseResponse)
            }
            try record("native-settings-observed-back", ["label": back.label,
                "controlType": back.elementType.rawValue,
                "previousNavigationTitleIsExpectedPermissionPage": ["Apps", "Carezaar", "Notifications"].contains(previousTitle)])
            back.tap()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.settings.navigationBars.allElementsBoundByIndex.contains {
                    $0.exists && !$0.frame.isEmpty && self.navigationTitle($0) != previousTitle
                }
            }, object: nil)
            guard XCTWaiter.wait(for: [changed], timeout: 5) == .completed else {
                privateSettingsAX("root-return-navigation-did-not-change")
                throw URLError(.cannotParseResponse)
            }
        }
        privateSettingsAX("root-return-bound-exhausted")
        throw URLError(.cannotParseResponse)
    }
    private func navigationTitle(_ bar: XCUIElement) -> String {
        if !bar.label.isEmpty { return bar.label }
        if !bar.identifier.isEmpty { return bar.identifier }
        return bar.staticTexts.allElementsBoundByIndex.first(where: { $0.exists && !$0.label.isEmpty })?.label ?? ""
    }
    private func switchState(_ element: XCUIElement) throws -> Bool {
        let value = try XCTUnwrap(element.value as? String)
        guard value == "0" || value == "1" else { throw URLError(.cannotParseResponse) }
        return value == "1"
    }
    private func tapNotificationToggle(_ labelledRow: XCUIElement) throws {
        _ = try requireVisible(labelledRow)
        let original = try switchState(labelledRow)
        privateSettingsAX("before-notification-toggle")
        let nested = labelledRow.descendants(matching: .switch).allElementsBoundByIndex.filter {
            $0.exists && $0.isHittable && !$0.frame.isEmpty && labelledRow.frame.contains($0.frame)
                && $0.frame.width * $0.frame.height < labelledRow.frame.width * labelledRow.frame.height
                && (try? switchState($0)) == original
        }.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        if let nested {
            try record("native-notification-toggle-target", ["nestedNativeSwitch": true,
                "x": nested.frame.minX, "y": nested.frame.minY,
                "width": nested.frame.width, "height": nested.frame.height])
            nested.tap()
        } else {
            // Observed native Allow Notifications screenshot exposes one wide
            // AX switch row; its real toggle is at the far right, not the label.
            try record("native-notification-toggle-target", ["nestedNativeSwitch": false,
                "observedRowRightToggleCoordinate": true, "normalizedX": 0.95, "normalizedY": 0.5,
                "rowWidth": labelledRow.frame.width, "rowHeight": labelledRow.frame.height])
            labelledRow.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        try waitSwitch(labelledRow, equals: !original)
    }
    private func waitSwitch(_ element: XCUIElement, equals expected: Bool) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (try? self.switchState(element)) == expected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertEqual(try switchState(element), expected)
    }
    private func requireVisible(_ element: XCUIElement, timeout: TimeInterval = 10) throws -> XCUIElement {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.exists && element.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
        guard element.exists && element.isHittable else { throw URLError(.cannotParseResponse) }; return element
    }
    // Observed iOS 26 Settings labels append summaries with the exact ", "
    // delimiter. Only these direct native row labels are eligible. A descendant
    // title can resolve an unrelated Settings row, so it is never a fallback.
    private func settingsRows(_ label: String) -> [XCUIElement] {
        let nativeLabel = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ", ")
        return settings.buttons.matching(nativeLabel).allElementsBoundByIndex
            + settings.cells.matching(nativeLabel).allElementsBoundByIndex
    }
    private func visibleSettingsRow(_ label: String) -> XCUIElement? {
        let bars = settings.navigationBars.allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
        let contentTop = bars.map { $0.frame.maxY }.max() ?? settings.frame.minY
        return settingsRows(label).first { row in
            row.exists && row.isHittable && !row.frame.isEmpty && settings.frame.contains(row.frame)
                && row.identifier != "BackButton" && row.frame.minY >= contentTop
                && !bars.contains(where: { $0.frame.intersects(row.frame) })
        }
    }
    private func revealSettingsRow(_ label: String) throws -> XCUIElement {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.visibleSettingsRow(label) != nil
        }, object: nil)
        if XCTWaiter.wait(for: [ready], timeout: 15) == .completed,
           let row = visibleSettingsRow(label) { return row }
        for upward in [true, false] { for _ in 0..<12 {
            if let row = visibleSettingsRow(label) { return row }
            if upward { settings.swipeUp() } else { settings.swipeDown() }
        } }
        if let row = visibleSettingsRow(label) { return row }
        privateSettingsAX("missing-row-\(label.lowercased())")
        XCTFail("Exact native Settings button/cell row must be visible: \(label)")
        throw URLError(.cannotParseResponse)
    }
    private func tapSettingsRow(_ label: String) throws {
        let row = try revealSettingsRow(label)
        // Validate the resolved label again immediately before the real tap.
        guard row.label == label || row.label.hasPrefix(label + ", ") else {
            privateSettingsAX("resolved-row-label-mismatch")
            XCTFail("Actual Settings row label did not match the requested exact native title")
            throw URLError(.cannotParseResponse)
        }
        let knownIdentifiers = ["Apps", "Carezaar", "Location", "Notifications", "NOTIFICATIONS", "LOCATION"]
        try record("native-settings-navigation-\(label.lowercased())", ["label": label,
            "actualResolvedLabel": row.label,
            "actualIdentifier": knownIdentifiers.contains(row.identifier) ? row.identifier : "unlisted",
            "actualIdentifierIsKnown": knownIdentifiers.contains(row.identifier),
            "controlType": row.elementType.rawValue, "hittable": row.isHittable,
            "x": row.frame.minX, "y": row.frame.minY, "width": row.frame.width, "height": row.frame.height])
        row.tap()
    }
    private func reveal(_ element: XCUIElement) throws {
        let scroll = try XCTUnwrap(app.scrollViews.allElementsBoundByIndex.max { $0.frame.height < $1.frame.height })
        for upward in [true, false] { for _ in 0..<20 {
            if element.exists && element.isHittable && scroll.frame.contains(element.frame) { return }
            if upward { scroll.swipeUp() } else { scroll.swipeDown() }
        } }
        _ = try requireVisible(element)
    }
    private func proof(_ element: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    /// PRIVATE diagnostic may contain Settings account/device metadata. Root
    /// must retain it locally and exclude every private-* attachment from any
    /// public collector or Git curation. Do not print this hierarchy to logs.
    private func privateSettingsAX(_ reason: String) {
        let attachment = XCTAttachment(data: Data(settings.debugDescription.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "private-native-settings-ax-\(reason)"
        attachment.lifetime = .keepAlways; add(attachment)
        let screenshot = XCTAttachment(screenshot: settings.screenshot())
        screenshot.name = "private-native-settings-screen-\(reason)"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }
    private func record(_ name: String, _ values: [String: Any]) throws {
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
