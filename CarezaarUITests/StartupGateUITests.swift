import XCTest
import Vision

final class StartupGateUITests: XCTestCase {
    /// Public loading copy must fit before reference data permits navigation.
    /// Only local reference data and QA session tokens are cleared; no API writes.
    func testSplashLoadingCopyIsFullyInsideViewportWithoutScrolling() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa-signout", "--qa-clear-reference-cache", "--qa-request-counts",
                               "--qa-latency", "15", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        defer { app.terminate() }
        let copy = ["Welcome to", "our healthcare community", "Initialization may take a while. Please be patient..."]
        // The Figma prototype exposes one composite scene button, rather than
        // separate StaticText elements. Match its actual public label.
        let scene = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", copy[2])).firstMatch
        XCTAssertTrue(scene.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Sign in"].exists)
        let captured = app.screenshot()
        let screenshot = XCTAttachment(screenshot: captured)
        screenshot.name = "splash-loading-public-full-viewport"
        screenshot.lifetime = .keepAlways; add(screenshot)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        let cgImage = try XCTUnwrap(captured.image.cgImage)
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let recognizedBounds = (request.results ?? []).compactMap { observation -> [String: Any]? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return ["text": text, "x": box.minX, "y": box.minY, "width": box.width, "height": box.height]
        }
        let visibleCopy = recognized.joined(separator: " ").lowercased()
        let rows: [String: Any] = ["recognizedPublicLoadingText": recognized,
            "recognizedNormalizedImageBounds": recognizedBounds,
            "wholeSceneInsideViewport": app.frame.contains(scene.frame),
            "sceneWidth": scene.frame.width, "sceneHeight": scene.frame.height]
        let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]),
                                  uniformTypeIdentifier: "public.json")
        proof.name = "splash-loading-copy-native-geometry"; proof.lifetime = .keepAlways; add(proof)
        for text in copy {
            let expected = text.replacingOccurrences(of: "...", with: "").lowercased()
            XCTAssertTrue(visibleCopy.contains(expected), "Actual rendered loading copy must be complete: \(text)")
        }
        // Composite AX bounds include SourceText's extra drawing inset around
        // the logo, so that diagnostic cannot substitute for visible glyphs.
        // The full-copy OCR assertions above test actual rendered pixels.
    }

    /// P01-008: no cached data may unlock onboarding during a connection loss.
    /// The fault redirects transport to a closed local port, then expires in the
    /// same native process so the real Retry control can recover against the API.
    func testUncachedOfflineStartupRecoversThroughNativeRetry() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa-signout", "--qa-clear-reference-cache", "--qa-request-counts",
                               "--qa-offline", "0", "20",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        defer { app.terminate() }
        let ledger = app.staticTexts["qa-request-counts"]
        let retry = app.buttons["Try Again"].firstMatch
        let signIn = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 18), "Uncached connection loss must show a recoverable reference error")
        XCTAssertTrue(retry.isEnabled && retry.isHittable)
        XCTAssertTrue(app.staticTexts["Cannot communicate with server."].exists)
        XCTAssertFalse(signIn.exists, "Incomplete reference data must not expose onboarding continuation")
        XCTAssertFalse(app.buttons["Messages"].exists)
        func references() -> [String] {
            ledger.label.split(separator: "\n").map(String.init)
                .filter { $0.contains(" /api/base/") }.sorted()
        }
        XCTAssertEqual(references(), ["GET /api/base/info=4"],
                       "Failed metadata must exhaust only its bounded connection retries, without partial datasets")
        let failed = XCTAttachment(string: ledger.label)
        failed.name = "uncached-offline-failed-reference-ledger"; failed.lifetime = .keepAlways; add(failed)
        let error = XCTAttachment(screenshot: app.screenshot())
        error.name = "uncached-offline-native-retry-error"; error.lifetime = .keepAlways; add(error)
        // Wait beyond the fault window from this observed failure. The process
        // remains alive; a relaunch must not substitute for tapping Retry.
        let reconnectAt = Date().addingTimeInterval(21)
        let reconnected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= reconnectAt }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reconnected], timeout: 24), .completed)
        XCTAssertTrue(retry.exists && retry.isHittable)
        XCTAssertEqual(references(), ["GET /api/base/info=4"], "No hidden background bootstrap should bypass Retry")
        retry.tap()
        let dispatched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            references().contains("GET /api/base/info=5")
        }, object: nil)
        let dispatchResult = XCTWaiter.wait(for: [dispatched], timeout: 10)
        let tapped = XCTAttachment(string: ledger.label)
        tapped.name = "uncached-offline-post-retry-dispatch-ledger"; tapped.lifetime = .keepAlways; add(tapped)
        XCTAssertEqual(dispatchResult, .completed, "Actual Retry must dispatch the metadata request")
        XCTAssertTrue(signIn.waitForExistence(timeout: 120))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: signIn)], timeout: 120), .completed)
        let datasets = ["careconditions", "caredays", "carespecials", "certifications",
                        "clienttypes", "commutes", "contents", "countries", "experiences",
                        "genders", "issuetypes", "languageskills", "reasons", "roles",
                        "shifts", "subjects", "worktypes", "languages", "states", "media",
                        "faqs", "faq_categories"]
        let expected = (["GET /api/base/info=5"] + datasets.map { "GET /api/base/\($0)=1" }).sorted()
        XCTAssertEqual(references(), expected)
        XCTAssertFalse(retry.exists)
        let recovered = XCTAttachment(string: ledger.label)
        recovered.name = "uncached-offline-retry-complete-reference-ledger"; recovered.lifetime = .keepAlways; add(recovered)
        for _ in 0..<8 {
            if signIn.isHittable { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(signIn.isHittable)
        signIn.tap()
        XCTAssertTrue(app.textFields["Enter your email address..."].waitForExistence(timeout: 20))
        XCTAssertTrue(app.secureTextFields["Enter your password..."].exists)
        XCTAssertEqual(references(), expected, "Continuation must retain the complete reference snapshot")
        let continued = XCTAttachment(screenshot: app.buttons["Sign In"].firstMatch.screenshot())
        continued.name = "uncached-offline-retry-public-sign-in-control"; continued.lifetime = .keepAlways; add(continued)
    }

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
