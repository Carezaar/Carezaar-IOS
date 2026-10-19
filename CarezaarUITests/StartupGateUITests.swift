import XCTest
import Vision

final class StartupGateUITests: XCTestCase {
    /// Real warm metadata completion; host only reads existing cache/preferences.
    func testHostWitnessedWarmMetadataCompletesWithEqualMarkerAndNoDatasets() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["QA_HOST_WARM_METADATA_COMPLETION"] == "1", let folder = env["QA_WARM_METADATA_HANDSHAKE"] else {
            throw XCTSkip("Explicit reviewed read-only warm metadata controller required")
        }
        enum WarmProofError: Error { case failed(String) }
        func require(_ ok: Bool, _ why: String) throws { if !ok { throw WarmProofError.failed(why) } }
        let directory = URL(fileURLWithPath: folder)
        func host(_ phase: String) throws {
            let event = directory.appendingPathComponent(phase + ".ready")
            try Data(phase.utf8).write(to: event, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: event.path)
            let handle = try FileHandle(forWritingTo: event); try handle.synchronize(); try handle.close()
            let ack = directory.appendingPathComponent(phase + ".ack")
            let wait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: ack.path) }, object: nil)
            try require(XCTWaiter.wait(for: [wait], timeout: 45) == .completed, "Read-only host did not acknowledge exact stopped phase")
        }
        let app = XCUIApplication()
        defer { app.terminate() }
        // The first XCUIApplication.launch may finish Xcode's ordinary app/data
        // installation refresh. Prime only that read-only launch before pinning
        // the baseline; measured launch below has a new process/reset ledger.
        app.launchArguments = ["--qa-request-counts", "--qa-reference-completion"]
        app.launchEnvironment = [:]
        app.launch()
        let primingPresence = app.staticTexts["qa-token-presence"]
        try require(primingPresence.waitForExistence(timeout: 30), "Priming credential-presence witness required")
        let primingPresenceValue = primingPresence.label
        try require(["accessPresent=true;refreshPresent=true", "accessPresent=false;refreshPresent=false"].contains(primingPresenceValue), "Unpaired priming credentials refused")
        let primingWitness = app.staticTexts["qa-reference-completion"]
        try require(primingWitness.waitForExistence(timeout: 120)
            && primingWitness.label == "completed=true;decoded=true;cached=true;markerMatches=true", "Ordinary priming launch must decode matching warm metadata")
        let primingLedger = app.staticTexts["qa-request-counts"].label.split(separator: "\n").map(String.init)
        try require(!primingLedger.isEmpty && primingLedger.allSatisfy { $0.hasPrefix("GET ") }
            && primingLedger.filter { $0.contains(" /api/base/") }.sorted() == ["GET /api/base/info=1"], "Priming launch permits exactly one metadata GET and no dataset/mutation requests")
        let primingProof = XCTAttachment(string: "primingOnly=true;completedDecodedEqualMarker=true;allGET=true;oneMetadata=true;zeroDatasets=true;noLogin=true")
        primingProof.name = "read-only-install-refresh-priming-proof"; primingProof.lifetime = .keepAlways; add(primingProof)
        app.terminate(); try host("installed-stopped")
        guard let cache = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("cache-before-private.json"))) as? [String: Any],
              let tables = cache["tables"] as? [String: Any], let contents = tables["contents"] as? [[String: Any]],
              let locale = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("locale-before-private.json"))) as? [String: Any],
              let languageID = locale["effectiveID"] as? Int, let languageCode = locale["effectiveCode"] as? String,
              let languages = cache["languages"] as? [[String: Any]] else { throw WarmProofError.failed("Host-validated existing cache and locale required") }
        try require(cache["schemaVersion"] as? Int == 3 && languages.filter {
            ($0["id"] as? Int) == languageID && ($0["code"] as? String) == languageCode
        }.count == 1, "Existing locale must bind one cached language without preference changes")
        func localized(_ slug: String, _ fallback: String) -> String {
            guard let row = contents.first(where: { $0["slug"] as? String == slug }), let values = row["translations"] as? [[String: Any]] else { return fallback }
            func name(_ id: Int) -> String? {
                guard let value = values.first(where: { ($0["language_id"] as? NSNumber)?.intValue == id })?["name"] as? String,
                      !value.isEmpty else { return nil }
                return value
            }
            let chosen = name(languageID) ?? name(1)
            return chosen?.isEmpty == false ? chosen! : fallback
        }
        let messagesLabel = localized("bottom_navigation_messages", "Messages")
        let signInLabel = localized("intro_sign_in", "Sign in")
        app.launchArguments = ["--qa-request-counts", "--qa-reference-completion"]
        app.launchEnvironment = [:] // No clear, force, login, fault, locale or route flags.
        app.launch()
        let presence = app.staticTexts["qa-token-presence"]
        try require(presence.waitForExistence(timeout: 30), "Actual initial credential-presence witness required")
        let initialPresence = presence.label
        try require(["accessPresent=true;refreshPresent=true", "accessPresent=false;refreshPresent=false"].contains(initialPresence), "Unpaired observed credential store refused")
        try require(initialPresence == primingPresenceValue, "Paired credential presence must survive ordinary priming and measured launches")
        let witness = app.staticTexts["qa-reference-completion"]
        try require(witness.waitForExistence(timeout: 120), "Actual awaited metadata-completion witness required")
        try require(witness.label == "completed=true;decoded=true;cached=true;markerMatches=true", "Real decoded info must match complete cached snapshot")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let target = initialPresence.contains("=true") ? app.buttons[messagesLabel].firstMatch : app.buttons[signInLabel].firstMatch
            return target.exists && target.isEnabled
        }, object: nil)
        try require(XCTWaiter.wait(for: [ready], timeout: 120) == .completed, "Ordinary current-locale saved Main/Welcome must be ready")
        func ledger() -> [String] { app.staticTexts["qa-request-counts"].label.split(separator: "\n").map(String.init) }
        func checks() throws {
            try require(app.staticTexts["qa-request-counts"].exists && !ledger().isEmpty, "Actual app request ledger required")
            try require(ledger().allSatisfy { $0.hasPrefix("GET ") }, "No refresh/login/backend mutations allowed")
            try require(ledger().filter { $0.contains(" /api/base/") }.sorted() == ["GET /api/base/info=1"], "Exactly one real metadata request and zero22 dataset downloads required")
            try require(presence.label == initialPresence, "Observed paired credential-presence must remain unchanged")
            try require(witness.label == "completed=true;decoded=true;cached=true;markerMatches=true", "Completion witness must remain the same")
        }
        try checks()
        let observedCompletion = Date(), until = observedCompletion.addingTimeInterval(2)
        let elapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= until }, object: nil)
        try require(XCTWaiter.wait(for: [elapsed], timeout: 4) == .completed, "Two real seconds after decoded completion must be observed")
        try checks()
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "private-warm-decoded-equal-marker-ordinary-ready"; image.lifetime = .keepAlways; add(image)
        let proof = XCTAttachment(string: witness.label + "\n" + ledger().joined(separator: "\n")
            + "\nobservedPairedCredentialPresenceUnchanged=true;ordinaryLaunch=true;hiddenLogin=false;completedResponseNotDispatchOnly=true;twoSecondsAfterWitness=true;noCacheRemoval=true;noCacheRestore=true;localeChanged=false")
        proof.name = "private-warm-metadata-completed-ledger-redact-ID-paths-before-curation"; proof.lifetime = .keepAlways; add(proof)
        app.terminate(); try host("completed-stopped")
    }

    /// Host removes only the exact public-reference cache after backing it up.
    /// No session/login/reset flags: this retains whichever session already exists.
    func testHostWitnessedMissingCacheThenUnchangedWarmRelaunch() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["QA_HOST_REFERENCE_CACHE_WITNESS"] == "1",
              let folder = env["QA_REFERENCE_CACHE_HANDSHAKE"] else {
            throw XCTSkip("Requires reviewed host cache controller and exact owned device")
        }
        enum ProofError: Error { case failed(String) }
        func require(_ ok: Bool, _ why: String) throws { if !ok { throw ProofError.failed(why) } }
        // Public reference read in the test process; it does not use/change an
        // app session or appear in the app's independently counted bootstrap.
        let managed = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0")
        try require(managed.status == 200, "Managed locale labels must load independently")
        let contents = try XCTUnwrap(managed.body["result"] as? [[String: Any]])
        func labels(_ slug: String, fallback: String) throws -> [String] {
            let row = try XCTUnwrap(contents.first { $0["slug"] as? String == slug })
            let translations = try XCTUnwrap(row["translations"] as? [[String: Any]])
            let names = Array(Set(translations.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }))
            try require(!names.isEmpty, "Managed locale labels cannot be empty")
            return Array(Set(names + [fallback])) // Exact production English fallback when managed English is blank.
        }
        let signInLabels = try labels("intro_sign_in", fallback: "Sign in")
        let messageLabels = try labels("bottom_navigation_messages", fallback: "Messages")
        let directory = URL(fileURLWithPath: folder)
        func host(_ stage: String) throws {
            let event = directory.appendingPathComponent(stage + ".ready")
            try Data(stage.utf8).write(to: event, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: event.path)
            let handle = try FileHandle(forWritingTo: event)
            try handle.synchronize(); try handle.close()
            let ack = directory.appendingPathComponent(stage + ".ack")
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: ack.path)
            }, object: nil)
            try require(XCTWaiter.wait(for: [ready], timeout: 45) == .completed, "Host witness did not acknowledge the exact stopped phase")
        }
        let app = XCUIApplication()
        defer { app.terminate() }
        func launchReady() throws -> String {
            app.launchArguments = ["--qa-request-counts"]
            app.launch()
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (app.buttons.matching(NSPredicate(format: "label IN %@", messageLabels)).firstMatch.exists && app.buttons.matching(NSPredicate(format: "label IN %@", messageLabels)).firstMatch.isEnabled)
                    || (app.buttons.matching(NSPredicate(format: "label IN %@", signInLabels)).firstMatch.exists && app.buttons.matching(NSPredicate(format: "label IN %@", signInLabels)).firstMatch.isEnabled)
            }, object: nil)
            try require(XCTWaiter.wait(for: [settled], timeout: 120) == .completed, "Ordinary native launch did not reach Main/Welcome")
            let presence = app.staticTexts["qa-token-presence"]
            try require(presence.waitForExistence(timeout: 10), "Token presence witness missing")
            let value = presence.label
            try require(["accessPresent=true;refreshPresent=true", "accessPresent=false;refreshPresent=false"].contains(value), "Unpaired stored credentials refused")
            if value.contains("=true") { try require(app.buttons.matching(NSPredicate(format: "label IN %@", messageLabels)).firstMatch.exists, "Saved session must remain signed in") }
            else { try require(app.buttons.matching(NSPredicate(format: "label IN %@", signInLabels)).firstMatch.exists && app.buttons.matching(NSPredicate(format: "label IN %@", signInLabels)).firstMatch.isEnabled, "Signed-out baseline must remain ready") }
            return value
        }
        func ledger() -> [String] {
            app.staticTexts["qa-request-counts"].label.split(separator: "\n").map(String.init)
        }
        func assertNoMutations() throws {
            try require(ledger().allSatisfy { $0.hasPrefix("GET ") }, "Bootstrap proof must perform only GET requests; refresh/relogin/mutation invalidates this run")
        }
        let baseline = try launchReady()
        try assertNoMutations()
        app.terminate()
        try host("baseline-stopped") // Host records bytes/hash and removes exact cache once.
        let cold = try launchReady()
        try require(cold == baseline, "Cold reference reload must retain baseline credential presence")
        try assertNoMutations()
        let datasets = ["careconditions", "caredays", "carespecials", "certifications", "clienttypes", "commutes", "contents", "countries", "experiences", "genders", "issuetypes", "languageskills", "reasons", "roles", "shifts", "subjects", "worktypes", "languages", "states", "media", "faqs", "faq_categories"]
        let completeDispatch = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ledger().filter { $0.contains(" /api/base/") }.sorted() == (["info"] + datasets).map { "GET /api/base/\($0)=1" }.sorted()
        }, object: nil)
        try require(XCTWaiter.wait(for: [completeDispatch], timeout: 120) == .completed, "Cold launch must settle its exact23 reference dispatches")
        try assertNoMutations()
        let coldBase = ledger().filter { $0.contains(" /api/base/") }.sorted()
        try require(coldBase == (["info"] + datasets).map { "GET /api/base/\($0)=1" }.sorted(), "Missing app cache must download every reference exactly once before ready")
        let first = XCTAttachment(string: coldBase.joined(separator: "\n") + "\ncredentialPresenceUnchanged=true")
        first.name = "missing-cache-actual-reference-ledger"; first.lifetime = .keepAlways; add(first)
        app.terminate()
        try host("cold-stopped") // Host validates schema3/22datasets/21counts, saves exact bytes.
        let warm = try launchReady()
        try require(warm == baseline, "Warm relaunch must retain baseline credential presence")
        try assertNoMutations()
        let metadataDispatched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ledger().contains("GET /api/base/info=1")
        }, object: nil)
        try require(XCTWaiter.wait(for: [metadataDispatched], timeout: 20) == .completed, "Warm metadata must be dispatched")
        // A cache may unlock UI before this response completes. This bounded
        // observation does not certify the server marker or P01-003 roundtrip.
        let boundedUntil = Date().addingTimeInterval(2)
        let observation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= boundedUntil }, object: nil)
        try require(XCTWaiter.wait(for: [observation], timeout: 4) == .completed, "Bounded warm observation interrupted")
        try assertNoMutations()
        let warmBase = ledger().filter { $0.contains(" /api/base/") }.sorted()
        try require(warmBase == ["GET /api/base/info=1"], "Bounded warm observation must show one metadata dispatch and no dataset downloads")
        let second = XCTAttachment(string: warmBase.joined(separator: "\n") + "\ncredentialPresenceUnchanged=true;ordinaryLaunch=true;hiddenLogin=false;metadataDispatchOnly=true;metadataResponseCompletionUnproven=true")
        second.name = "warm-cache-actual-reference-ledger"; second.lifetime = .keepAlways; add(second)
        app.terminate()
        try host("warm-stopped") // Host checks identical cold/warm hash then restores original cache.
    }

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

    /// October13 supersedes the earlier Welcome-on-unverifiable-session policy.
    /// Offline cannot establish rejection; the next online server refusal can.
    func testOfflineSavedSessionRetainsCredentialsUntilOnlineServerExplicitlyRejects() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa-clear-reference-cache", "--qa-seed-invalid-session", "--qa-offline", "0", "120", "--qa-request-counts",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Try Again"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Sign in"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Messages"].exists)
        XCTAssertEqual(app.staticTexts["qa-token-presence"].label, "accessPresent=true;refreshPresent=true")
        XCTAssertTrue(app.staticTexts["qa-request-counts"].label.contains("GET /api/auth/info=4"))
        XCTAssertFalse(app.staticTexts["qa-request-counts"].label.contains("PUT /api/auth/refresh="))
        let offline = XCTAttachment(screenshot: app.screenshot())
        offline.name = "offline-unverifiable-session-retained-retry"; offline.lifetime = .keepAlways; add(offline)
        app.terminate()
        app.launchArguments = ["--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let signIn = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 60))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: signIn)], timeout: 120), .completed)
        XCTAssertEqual(app.staticTexts["qa-token-presence"].label, "accessPresent=false;refreshPresent=false")
        let ledger = app.staticTexts["qa-request-counts"].label
        XCTAssertTrue(ledger.contains("GET /api/auth/info=1"))
        XCTAssertTrue(ledger.contains("PUT /api/auth/refresh=1"))
        XCTAssertFalse(ledger.contains("POST /api/auth/login="))
        for dataset in ["languages", "states", "media", "faqs", "faq_categories"] {
            XCTAssertTrue(ledger.contains("GET /api/base/\(dataset)=1"))
        }
        XCTAssertFalse(app.buttons["Messages"].exists)
    }
}
