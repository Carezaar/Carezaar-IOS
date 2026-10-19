import XCTest
import Foundation
import CryptoKit

/// Standalone one-tap observation only. Never constructs the graph journal or logs in.
final class NativeSavedCGProfileTransitionUITests: XCTestCase {
    private enum Stopped: Error { case invariant(String) }
    private var app: XCUIApplication!
    private var labels: [String: String] = [:]
    private var tapped = false
    private var publicContentsGETs = 0
    private var output: URL?

    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app?.terminate(); super.tearDown() }

    private func require(_ value: @autoclosure () -> Bool, _ code: String) throws {
        guard value() else { throw Stopped.invariant(code) }
    }
    private func wait(_ code: String, seconds: TimeInterval = 30, _ condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        try require(XCTWaiter.wait(for: [expectation], timeout: seconds) == .completed, code)
    }
    private func text(_ key: String, _ fallback: String) -> String { labels[key] ?? fallback }
    private func tab(_ key: String, _ fallback: String) -> [XCUIElement] {
        app.buttons.matching(identifier: text(key, fallback)).allElementsBoundByIndex.filter {
            $0.exists && $0.isEnabled && $0.isHittable && self.app.frame.contains($0.frame)
                && $0.frame.width > 0 && $0.frame.height > 0 && $0.frame.minY > self.app.frame.midY
        }
    }
    private func selectedProfile() -> Bool {
        let tabs = tab("bottom_navigation_profile", "Profile")
        return app.state == .runningForeground && tabs.count == 1 && tabs[0].isSelected
    }
    private func ledger() throws -> [String: Int] {
        let counter = app.staticTexts["qa-request-counts"]
        try require(counter.exists, "actual-app-request-ledger-required")
        var result: [String: Int] = [:]
        for line in counter.label.split(separator: "\n") {
            guard let delimiter = line.lastIndex(of: "="), let count = Int(line[line.index(after: delimiter)...]), count > 0 else {
                throw Stopped.invariant("unparseable-app-ledger")
            }
            let route = String(line[..<delimiter])
            try require(result[route] == nil, "unique-ledger-routes-required")
            result[route] = count
        }
        return result
    }
    private func snapshot(_ phase: String) {
        let state = app.state.rawValue
        let details: [String: Any] = ["phase": phase, "appStateRaw": state, "foreground": app.state == .runningForeground,
            "profileTapCount": tapped ? 1 : 0, "publicContentsGETs": publicContentsGETs,
            "profileSelected": selectedProfile(), "officialLoginCalls": 0, "nativeLoginTaps": 0]
        if let bytes = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]),
           let value = String(data: bytes, encoding: .utf8) {
            let attachment = XCTAttachment(string: value); attachment.name = "private-\(phase)-state"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        let ax = XCTAttachment(string: app.debugDescription); ax.name = "private-\(phase)-AX"
        ax.lifetime = .keepAlways; add(ax)
        let raster = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); raster.name = "private-\(phase)-screen"
        raster.lifetime = .keepAlways; add(raster)
    }
    private func publish(_ value: [String: Any]) throws {
        guard let output else { throw Stopped.invariant("private-output-required") }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        // Each phase has a distinct file. Never replace a prior observation.
        try data.write(to: output, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
    private func loadManagedCopy(_ language: Int) throws {
        publicContentsGETs += 1
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0")
        try require(response.status == 200, "one-public-managed-copy-GET-must-succeed")
        guard let rows = response.body["result"] as? [[String: Any]] else { throw Stopped.invariant("contents-array-required") }
        for row in rows {
            guard let slug = row["slug"] as? String, let translations = row["translations"] as? [[String: Any]] else { continue }
            func name(_ id: Int) -> String? {
                guard let value = translations.first(where: { ($0["language_id"] as? NSNumber)?.intValue == id })?["name"] as? String, !value.isEmpty else { return nil }
                return value
            }
            if let value = name(language) ?? name(1) { labels[slug] = value }
        }
    }
    func testSavedCaregiverSingleProfileTapSettlesExactOwner() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_SAVED_CG_PROFILE_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Exact reviewed standalone read-only saved caregiver diagnostic required")
        }
        guard let fixturePath = env["QA_NATIVE_GRAPH_CAREGIVER_FILE"], let expectedSHA = env["QA_NATIVE_SAVED_CG_FIXTURE_SHA256"],
              let destination = env["QA_NATIVE_SAVED_CG_DIAGNOSTIC_PROOF"],
              let language = env["QA_NATIVE_SAVED_CG_LANGUAGE_ID"].flatMap(Int.init), language > 0 else {
            throw Stopped.invariant("reviewed-private-control-required")
        }
        output = URL(fileURLWithPath: destination)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        try require(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == expectedSHA, "immutable-owned-fixture-SHA-required")
        guard let fixture = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let provenance = fixture["native_provenance"] as? [String: Any],
              fixture["role"] as? String == "caregiver", provenance["role"] as? String == "caregiver",
              provenance["purpose"] as? String == "carezaar-native-final-qa", provenance["stage"] as? String == "signupComplete",
              let repair = fixture["native_dob_repair"] as? [String: Any], repair["stage"] as? String == "complete",
              let email = fixture["email"] as? String, !email.isEmpty else { throw Stopped.invariant("exact-completed-purpose-CG-required") }
        try loadManagedCopy(language)
        do {
            // Ordinary saved-session launch; no signout, temporary locale, login, hidden tab or route.
            app.launchArguments = ["--qa-request-counts"]
            app.launchEnvironment = [:]
            app.launch()
            var stableSince: Date?
            try wait("actual-loaded-foreground-Main-before-one-tap", seconds: 120) {
                let matches = self.tab("bottom_navigation_matches", "Matches")
                let messages = self.tab("bottom_navigation_messages", "Messages")
                let profile = self.tab("bottom_navigation_profile", "Profile")
                let total = self.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
                    self.text("caregiver_matches_all_matches", "All Matches") + " (")).firstMatch
                let busy = self.app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@",
                    self.text("loading_please_wait", "Please wait..."))).firstMatch
                let interrupted = self.app.alerts.count > 0 || XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count > 0
                let loaded = self.app.state == .runningForeground && matches.count == 1 && matches[0].isSelected
                    && messages.count == 1 && profile.count == 1 && !profile[0].isSelected
                    && total.exists && !busy.exists && !interrupted
                if !loaded { stableSince = nil; return false }
                if stableSince == nil { stableSince = Date() }
                return Date().timeIntervalSince(stableSince!) >= 3
            }
            try require(app.staticTexts["qa-token-presence"].label == "accessPresent=true;refreshPresent=true", "existing-paired-saved-session-required")
            let beforeLedger = try ledger()
            try require(beforeLedger.keys.allSatisfy { $0.hasPrefix("GET ") }, "zero-nonGET-before-single-tap")
            snapshot("before-single-Profile-tap")
            let targets = tab("bottom_navigation_profile", "Profile")
            let busyAtTap = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text("loading_please_wait", "Please wait..."))).firstMatch
            try require(targets.count == 1 && app.state == .runningForeground && !busyAtTap.exists
                && app.alerts.count == 0 && XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0,
                "one-actual-foreground-unblocked-Profile-target-required")
            let target = targets[0]
            let intent = XCTAttachment(string: "singleTap=true;targetFrame=\(target.frame);appFrame=\(app.frame);foreground=true;selectedBefore=false")
            intent.name = "private-single-Profile-tap-intent-geometry"; intent.lifetime = .keepAlways; add(intent)
            tapped = true
            target.tap() // Exactly one genuine observed bottom-tab action. No retries or alternate route.
            try wait("single-visible-Profile-tap-must-select-tab", seconds: 20) { self.selectedProfile() }
            let owner = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value == %@",
                text("profile_edit_email", "Email Address"), email))
            try wait("selected-Profile-must-expose-exact-private-owned-email", seconds: 30) {
                self.selectedProfile() && owner.count == 1 && owner.firstMatch.isHittable && self.app.frame.contains(owner.firstMatch.frame)
            }
            let afterLedger = try ledger()
            try require(afterLedger.keys.allSatisfy { $0.hasPrefix("GET ") }, "zero-nonGET-after-single-tap")
            snapshot("after-single-Profile-tap-exact-owner-settled")
            try require(tapped && publicContentsGETs == 1, "one-tap-and-one-public-copy-GET-only")
            try publish(["status": "PASS", "singleBottomProfileTap": 1, "profileSelected": true, "exactNativeOwnerEmailVerified": true,
                "ordinarySavedSession": true, "zeroOfficialLoginCalls": true, "zeroNativeLoginTaps": true,
                "allAppRequestsGETOnly": true, "beforeAppGETLedger": beforeLedger, "afterAppGETLedger": afterLedger,
                "publicManagedCopyGETs": publicContentsGETs, "localeOverride": false, "automaticRetryOrAlternateRoute": false])
        } catch {
            snapshot("failure-observation-no-retry")
            let observed = try? ledger()
            try? publish(["status": "FAIL", "singleBottomProfileTap": tapped ? 1 : 0,
                "profileSelected": selectedProfile(), "appStateRaw": app.state.rawValue,
                "zeroOfficialLoginCalls": true, "zeroNativeLoginTaps": true, "publicManagedCopyGETs": publicContentsGETs,
                "appLedgerReadable": observed != nil, "appLedgerGETOnly": observed?.keys.allSatisfy { $0.hasPrefix("GET ") } ?? false,
                "observedAppLedger": observed ?? [:],
                "automaticRetryOrAlternateRoute": false])
            throw error
        }
    }
}
