import XCTest

final class StartupGateUITests: XCTestCase {
    /// The host prepares and records an invalid cache in an isolated QA app
    /// container before launch. This method must not clear that file itself:
    /// doing so would test a missing cache rather than rejection and recovery.
    func testPreparedInvalidReferenceCacheRecoversBeforeAllowingContinuation() throws {
        let env = ProcessInfo.processInfo.environment
        guard let variant = env["QA_PREPARED_REFERENCE_CACHE_VARIANT"],
              ["malformed-json", "incomplete-counts"].contains(variant),
              let digest = env["QA_PREPARED_REFERENCE_CACHE_SHA256"],
              digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
            throw XCTSkip("Requires a host-recorded invalid reference cache in an isolated QA app container")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa-signout", "--qa-request-counts", "--qa-latency", "5",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        defer { app.terminate() }
        let signIn = app.buttons["Sign in"].firstMatch
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 3))
        XCTAssertFalse(signIn.exists, "Invalid cached data must not immediately unlock Welcome")
        XCTAssertFalse(app.buttons["Messages"].exists)
        let loading = XCTAttachment(screenshot: app.screenshot())
        loading.name = "invalid-cache-\(variant)-loading-gate"
        loading.lifetime = .keepAlways; add(loading)
        XCTAssertTrue(signIn.waitForExistence(timeout: 120))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: signIn)], timeout: 120), .completed)
        let datasets = ["careconditions", "caredays", "carespecials", "certifications",
                        "clienttypes", "commutes", "contents", "countries", "experiences",
                        "genders", "issuetypes", "languageskills", "reasons", "roles",
                        "shifts", "subjects", "worktypes", "languages", "states", "media",
                        "faqs", "faq_categories"]
        func references() -> [String] {
            ledger.label.split(separator: "\n").map(String.init)
                .filter { $0.contains(" /api/base/") }.sorted()
        }
        XCTAssertEqual(references(), (["info"] + datasets).map { "GET /api/base/\($0)=1" }.sorted())
        let recovered = XCTAttachment(string: ledger.label)
        recovered.name = "invalid-cache-\(variant)-recovered-transport-ledger"
        recovered.lifetime = .keepAlways; add(recovered)
        for _ in 0..<8 {
            if signIn.isHittable { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(signIn.isHittable, "Recovered Welcome must provide usable native continuation")
        signIn.tap()
        XCTAssertTrue(app.textFields["Enter your email address..."].waitForExistence(timeout: 20))
        XCTAssertTrue(app.secureTextFields["Enter your password..."].exists)
        XCTAssertEqual(references(), (["info"] + datasets).map { "GET /api/base/\($0)=1" }.sorted(),
                       "Entering Sign In after recovery must not download reference lists again")
        let continued = XCTAttachment(screenshot: app.buttons["Sign In"].firstMatch.screenshot())
        continued.name = "invalid-cache-\(variant)-public-sign-in-control-only"
        continued.lifetime = .keepAlways; add(continued)
        let proof = XCTAttachment(string: "variant=\(variant)\npreparedCacheSHA256=\(digest)\n")
        proof.name = "invalid-cache-\(variant)-host-precondition"
        proof.lifetime = .keepAlways; add(proof)
    }

    /// An uncached native launch must expose its loading gate and fetch the complete
    /// reference inventory once before permitting onboarding. This deliberately
    /// clears only the app's reference cache, not an account or simulator gallery.
    func testUncachedStartupGatesWelcomeUntilEveryReferenceDatasetLoadsOnce() {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-signout", "--qa-clear-reference-cache",
                               "--qa-request-counts", "--qa-latency", "5"]
        app.launch()
        defer { app.terminate() }
        let signIn = app.buttons["Sign in"].firstMatch
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 3))
        XCTAssertFalse(signIn.exists, "Fresh uncached startup must keep onboarding behind Splash until references are ready")
        XCTAssertFalse(app.buttons["Messages"].exists)
        let loading = XCTAttachment(screenshot: app.screenshot())
        loading.name = "uncached-reference-loading-gate"; loading.lifetime = .keepAlways; add(loading)
        XCTAssertTrue(signIn.waitForExistence(timeout: 120))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: signIn)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 120), .completed)
        XCTAssertTrue(ledger.waitForExistence(timeout: 10))
        // Contract inventory is fixed independently of BaseTable.allCases.
        let datasets = ["careconditions", "caredays", "carespecials", "certifications",
                        "clienttypes", "commutes", "contents", "countries", "experiences",
                        "genders", "issuetypes", "languageskills", "reasons", "roles",
                        "shifts", "subjects", "worktypes", "languages", "states", "media",
                        "faqs", "faq_categories"]
        let referenceRequests = ledger.label.split(separator: "\n").map(String.init)
            .filter { $0.contains(" /api/base/") }.sorted()
        XCTAssertEqual(referenceRequests, (["info"] + datasets).map { "GET /api/base/\($0)=1" }.sorted(),
                       "Ready Welcome requires exactly one bootstrap request for every reference dataset")
        XCTAssertFalse(app.buttons["Messages"].exists)
        let proof = XCTAttachment(string: ledger.label)
        proof.name = "uncached-complete-reference-transport-ledger"; proof.lifetime = .keepAlways; add(proof)
        let loaded = XCTAttachment(screenshot: app.screenshot())
        loaded.name = "uncached-reference-ready-welcome"; loaded.lifetime = .keepAlways; add(loaded)
    }

    /// Count real transport attempts after an actual process termination. A new
    /// BaseDataStore instance alone does not establish the native launch behavior.
    func testUnchangedReferenceCacheSurvivesActualAppRelaunchWithoutDatasetDownloads() {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-signout", "--qa-request-counts"]
        app.launch()
        defer { app.terminate() }
        func awaitReadyWelcome() {
            let signIn = app.buttons["Sign in"].firstMatch
            XCTAssertTrue(signIn.waitForExistence(timeout: 60))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isEnabled == true"), object: signIn)], timeout: 120), .completed)
        }
        awaitReadyWelcome()
        app.terminate()
        app.launchArguments = ["--qa-request-counts"]
        app.launch()
        awaitReadyWelcome()
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 10))
        let referenceRequests = ledger.label.split(separator: "\n").map(String.init)
            .filter { $0.contains(" /api/base/") }
        XCTAssertEqual(referenceRequests, ["GET /api/base/info=1"],
                       "An unchanged complete disk snapshot must check metadata once and download no datasets")
        let proof = XCTAttachment(string: ledger.label)
        proof.name = "actual-process-relaunch-reference-request-ledger"
        proof.lifetime = .keepAlways
        add(proof)
    }

    func testOfflineRejectedSavedSessionShowsWelcomeWithReferenceContinuationDisabled() {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-clear-reference-cache", "--qa-seed-invalid-session", "--qa-offline", "0", "120", "--qa-request-counts"]
        app.launch()
        defer { app.terminate() }
        let signIn = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 60), "An unverifiable saved session must show Welcome, even with no cached lists")
        XCTAssertFalse(signIn.isEnabled, "Welcome cannot proceed before every reference dataset is ready")
        XCTAssertTrue(app.otherElements["welcome-reference-gate"].exists || app.buttons["Try Again"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Messages"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "offline-saved-session-welcome-gated"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
        app.launchArguments = ["--qa-request-counts"]
        app.launch()
        XCTAssertTrue(app.buttons["Sign in"].firstMatch.waitForExistence(timeout: 60), "Next launch must not restore invalid credentials")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: app.buttons["Sign in"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 120), .completed, "Online Welcome must unlock only after complete reference startup")
        for dataset in ["languages", "states", "media", "faqs", "faq_categories"] {
            XCTAssertTrue(app.staticTexts["qa-request-counts"].label.contains("GET /api/base/\(dataset)=1"), "First uncached launch must load \(dataset)")
        }
        XCTAssertFalse(app.buttons["Messages"].exists)
        XCTAssertFalse(app.staticTexts["qa-request-counts"].label.contains("GET /api/auth/info="), "Invalid saved credentials must have been cleared")
        let reopened = XCTAttachment(screenshot: app.screenshot()); reopened.name = "subsequent-online-welcome"; reopened.lifetime = .keepAlways; add(reopened)
    }
}
