import XCTest
import Vision

/// First bounded new-native-purpose graph phase only. Never stages edges via API.
final class NativeOwnedGraphJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private var journal: NativeOwnedGraphJournal?
    private var labels: [String: String] = [:]
    private var activeRole = ""
    private var inspectKeyboardFinalLine = false
    private typealias Guard = NativeOwnedGraphJournal

    override func setUp() { continueAfterFailure = false; app = XCUIApplication(); journal = nil; labels = [:]; activeRole = ""; inspectKeyboardFinalLine = false }
    override func tearDown() {
        // No automatic graph cleanup or hidden retry. Pending durable intent is
        // retained for primary review before any exact-owned failure withdrawal.
        if (testRun?.totalFailureCount ?? 0) > 0 { try? journal?.event("test-stopped-no-automatic-cleanup") }
        app?.terminate()
        super.tearDown()
    }
    /// No fixture/API proof, credentials, session reset or graph journal used.
    func testSignedOutWelcomeScrollReachesEmptySignInWithoutMutation() throws {
        guard ProcessInfo.processInfo.environment["QA_NATIVE_GRAPH_SETUP_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Explicit read-only setup diagnostic required")
        }
        app.launchArguments = ["--qa-request-counts"]
        app.launchEnvironment = [:]
        app.launch()
        defer { app.terminate() }
        let welcome = try revealWelcomeSignIn()
        try Guard.require(app.staticTexts["qa-token-presence"].label == "accessPresent=false;refreshPresent=false", "diagnostic-requires-existing-signed-out-state-no-clear")
        try writes([:])
        try capture("readonly-Welcome-Sign-in-revealed", element: welcome)
        welcome.tap()
        let email = app.textFields["Enter your email address..."]
        let password = app.secureTextFields["Enter your password..."]
        let submit = app.buttons["Sign In"].firstMatch
        try ready(email); try ready(password)
        try Guard.require(submit.waitForExistence(timeout: 15) && !submit.isEnabled
            && app.frame.contains(submit.frame), "actual-empty-Sign-In-submit-must-exist-visible-disabled")
        try Guard.require((email.value as? String).map { $0.isEmpty || $0 == email.placeholderValue } == true
            && (password.value as? String).map { $0.isEmpty || $0 == password.placeholderValue } == true,
            "diagnostic-form-must-remain-empty")
        try writes([:])
        try capture("readonly-empty-native-Sign-In-form", element: app)
        // This scene makes its action-bearing Header the Button; insideButton
        // suppresses its nested Back button. The binder supplies its Back semantics.
        let back = app.buttons["Back"].firstMatch
        try ready(back)
        // The Header AX union includes the logo and transparent space. Target
        // the observed painted Back square, verified against scene geometry.
        let signInScroll = app.scrollViews["v2-51-5170"].firstMatch
        try Guard.require(signInScroll.exists, "actual-Sign-In-scene-required")
        let scale = signInScroll.frame.width / 412 // Scene source width; not inflated Header AX union.
        try Guard.require(scale.isFinite && scale > 0
            && abs(back.frame.height - 40 * scale) < 1, "Header-source-scale-must-match")
        let expected = CGRect(x: back.frame.minX, y: back.frame.minY + 4 * scale,
                              width: 32 * scale, height: 32 * scale)
        let observed = back.descendants(matching: .other).allElementsBoundByIndex.map(\.frame).filter {
            abs($0.minX - expected.minX) < 1 && abs($0.minY - expected.minY) < 1
                && abs($0.width - expected.width) < 1 && abs($0.height - expected.height) < 1
        }
        var unique: [CGRect] = []
        for frame in observed where !unique.contains(frame) { unique.append(frame) }
        try Guard.require(unique.count == 1, "one-unique-observed-Back-square-required")
        let paintedBack = unique[0]
        let target = XCTAttachment(string: "appFrame=\(app.frame);HeaderFrame=\(back.frame);observedBackFrame=\(paintedBack);sourceScale=\(scale);uniquePaintedRectangles=1;credentialsTyped=false;nonGET=0")
        target.name = "readonly-observed-Back-target-geometry"; target.lifetime = .keepAlways; add(target)
        // Independently queried AX edges can differ by subpixel rounding. Allow
        // at most one point at rectangle edges; the actual tap center must still
        // be strictly inside the unexpanded app and Header.
        let center = CGPoint(x: paintedBack.midX, y: paintedBack.midY)
        try Guard.require(app.frame.insetBy(dx: -1, dy: -1).contains(paintedBack)
            && back.frame.insetBy(dx: -1, dy: -1).contains(paintedBack)
            && app.frame.contains(center) && back.frame.contains(center)
            && paintedBack.width > 0 && paintedBack.height > 0, "painted-Back-must-be-contained")
        back.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: paintedBack.midX - back.frame.minX, dy: paintedBack.midY - back.frame.minY)).tap()
        try Guard.require(password.waitForNonExistence(timeout: 15)
            && app.scrollViews["v2-16-14997"].firstMatch.exists, "actual-Back-must-return-Welcome")
        try writes([:])
        let proof = XCTAttachment(string: "setupDiagnostic=true;actualNativeScrollView=true;SignInRevealedAndTapped=true;emailPasswordSubmitControls=true;emptyForm=true;submitDisabled=true;credentialsTyped=false;proofAPILogins=0;nativeLoginPOSTs=0;allAppRequestsGET=true;graphJournalOrControlChanged=false;BackReturnedWelcome=true\n" + app.staticTexts["qa-request-counts"].label)
        proof.name = "readonly-native-setup-scroll-anonymous"; proof.lifetime = .keepAlways; add(proof)
    }
    /// Read-only continuation of existing stored client session; no login/reset.
    func testExistingOwnedClientProfileTabReadOnlyWithoutLogin() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_GRAPH_CURRENT_SESSION_DIAGNOSTIC"] == "1",
              let path = env["QA_NATIVE_GRAPH_CLIENT_FILE"] else {
            throw XCTSkip("Explicit current-session read-only diagnostic required")
        }
        let fixture = try NativeLifecycleFixture.read(path)
        guard let provenance = fixture["native_provenance"] as? [String: Any],
              let email = fixture["email"] as? String,
              let marker = provenance["marker"] as? String,
              let identity = fixture["user_id"] as? String else {
            throw Guard.Stopped.invariant("complete-owned-client-fixture-required")
        }
        try Guard.require(fixture["role"] as? String == "client"
            && provenance["role"] as? String == "client"
            && provenance["purpose"] as? String == "carezaar-native-final-qa"
            && provenance["stage"] as? String == "signupComplete"
            && provenance["size"] as? String == "modern"
            && provenance["provider_create_attempts"] as? Int == 1
            && provenance["app_registration_attempts"] as? Int == 1
            && provenance["provider_ownership_verified"] as? Bool == true
            && email.hasPrefix("carezaar-native-\(marker)@") && !identity.isEmpty
            && fixture["deleted"] as? Bool != true, "exact-native-purpose-client-required")
        let fixtureURL = URL(fileURLWithPath: path)
        let bytesBefore = try Data(contentsOf: fixtureURL)
        app.launchArguments = ["--qa-request-counts"]
        app.launchEnvironment = [:] // No signout, hidden login, credentials or route push.
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try Guard.require(app.staticTexts["qa-token-presence"].waitForExistence(timeout: 120)
            && app.staticTexts["qa-token-presence"].label == "accessPresent=true;refreshPresent=true",
            "existing-saved-client-session-required-no-repair")
        let ax = XCTAttachment(string: app.debugDescription + "\nSPRINGBOARD\n" + springboard.debugDescription)
        ax.name = "private-current-session-before-Profile-readiness-AX"; ax.lifetime = .keepAlways; add(ax)
        try capture("private-current-session-before-Profile-readiness", element: app)
        try writes([:])
        // Do not infer AX ownership from a video. Runtime must positively expose
        // the exact task-triggered title and unique decline button in one owner.
        var declinedPasswordSave = false
        let deadline = Date().addingTimeInterval(40)
        var stableProfileChecks = 0
        while Date() < deadline && stableProfileChecks < 3 {
            for owner in [app!, springboard] {
                let title = owner.staticTexts["Save Password?"].firstMatch
                let decline = owner.buttons.matching(identifier: "Not Now")
                if title.exists {
                    try Guard.require(!declinedPasswordSave && decline.count == 1
                        && decline.firstMatch.isEnabled && decline.firstMatch.isHittable,
                        "exact-password-save-decline-control-required")
                    let promptAX = XCTAttachment(string: owner.debugDescription)
                    promptAX.name = "private-observed-password-save-owner-AX"; promptAX.lifetime = .keepAlways; add(promptAX)
                    decline.firstMatch.tap(); declinedPasswordSave = true
                    try Guard.require(title.waitForNonExistence(timeout: 10), "password-save-prompt-must-dismiss")
                } else if owner.alerts.count > 0 {
                    let unknown = XCTAttachment(string: owner.debugDescription)
                    unknown.name = "private-unknown-prompt-stop-AX"; unknown.lifetime = .keepAlways; add(unknown)
                    throw Guard.Stopped.invariant("unknown-system-or-app-alert-no-action")
                }
            }
            let candidates = app.buttons.matching(identifier: "Profile").allElementsBoundByIndex.filter {
                $0.isEnabled && $0.isHittable && self.app.frame.contains($0.frame)
                    && $0.frame.minY > self.app.frame.midY
            }
            stableProfileChecks = candidates.count == 1 ? stableProfileChecks + 1 : 0
            if stableProfileChecks < 3 { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        }
        try Guard.require(stableProfileChecks == 3, "existing-session-Profile-tab-not-ready")
        let profiles = app.buttons.matching(identifier: "Profile")
        try wait("existing-session-Profile-tab-not-ready", timeout: 40) {
            profiles.allElementsBoundByIndex.filter {
                $0.isEnabled && $0.isHittable && self.app.frame.contains($0.frame)
                    && $0.frame.minY > self.app.frame.midY
            }.count == 1
        }
        let profile = profiles.allElementsBoundByIndex.filter {
            $0.isEnabled && $0.isHittable && self.app.frame.contains($0.frame)
                && $0.frame.minY > self.app.frame.midY
        }
        try Guard.require(profile.count == 1, "unique-bottom-Profile-required")
        try capture("private-current-session-Profile-tab-ready", element: profile[0])
        try writes([:]); profile[0].tap()
        let displayedOwner = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", email, email)).firstMatch
        try Guard.require(displayedOwner.waitForExistence(timeout: 30), "exact-displayed-owned-client-email-required")
        try capture("private-current-session-owned-client-Profile", element: app)
        try writes([:])
        try Guard.require(try Data(contentsOf: fixtureURL) == bytesBefore, "owned-fixture-must-remain-byte-identical")
        let proof = XCTAttachment(string: "ordinaryStoredClientSession=true;nativeDisplayedOwnerEmailMatched=true;ProfileTabReadyAndTapped=true;passwordSaveDeclined=\(declinedPasswordSave);credentialTyping=false;officialProofLogin=0;nativeLoginPOST=0;allAppRequestsGET=true;graphJournalUnchanged=true;fixtureBytesUnchanged=true\n" + app.staticTexts["qa-request-counts"].label)
        proof.name = "readonly-current-owned-client-Profile-anonymous"; proof.lifetime = .keepAlways; add(proof)
    }

    /// Supplemental P23-001 copy inspection only: uses an already saved client,
    /// never initializes the graph journal or performs proof/login/match writes.
    func testExistingOwnedClientMatchFormManagedCopyDismissesWithoutMutation() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_MATCH_FORM_READONLY"] == "1",
              let cf = env["QA_NATIVE_GRAPH_CLIENT_FILE"], let gf = env["QA_NATIVE_GRAPH_CAREGIVER_FILE"],
              let identityFile = env["QA_NATIVE_MATCH_FORM_PEER_IDENTITY_FILE"],
              let frozenJSON = env["QA_NATIVE_MATCH_FORM_FROZEN_FILES"], let frozenData = frozenJSON.data(using: .utf8),
              let frozen = try JSONSerialization.jsonObject(with: frozenData) as? [String: String] else {
            throw XCTSkip("Explicit frozen-pair read-only Match-form inspection required")
        }
        func unchanged() throws {
            try Guard.require(frozen.count >= 17, "both-fixtures-seven-controls-seven-journals-peer-snapshot-required")
            for (path, expected) in frozen {
                try Guard.require(Guard.sha(try Data(contentsOf: URL(fileURLWithPath: path))) == expected,
                                  "read-only-frozen-file-must-remain-byte-identical")
            }
        }
        try unchanged()
        let client = try NativeLifecycleFixture.read(cf), caregiver = try NativeLifecycleFixture.read(gf)
        var run: String?
        for (role, fixture, path) in [("client", client, cf), ("caregiver", caregiver, gf)] {
            guard let p = fixture["native_provenance"] as? [String: Any], let marker = p["marker"] as? String,
                  let email = fixture["email"] as? String, let id = fixture["user_id"] as? String,
                  let nativeRun = p["run_id"] as? String else { throw Guard.Stopped.invariant("exact-owned-fixture-required") }
            try Guard.require(frozen[path] != nil && p["purpose"] as? String == "carezaar-native-final-qa"
                && p["stage"] as? String == "signupComplete" && p["role"] as? String == role
                && fixture["role"] as? String == role && p["size"] as? String == "modern"
                && p["provider_create_attempts"] as? Int == 1 && p["app_registration_attempts"] as? Int == 1
                && p["provider_ownership_verified"] as? Bool == true && fixture["deleted"] as? Bool != true
                && email.hasPrefix("carezaar-native-\(marker)@") && !id.isEmpty,
                "same-completed-native-purpose-pair-required")
            if let run { try Guard.require(run == nativeRun, "same-native-provenance-run-required") }
            else { run = nativeRun }
        }
        guard let ownerEmail = client["email"] as? String, let peerID = caregiver["user_id"] as? String,
              let peer = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: identityFile))) as? [String: Any],
              let first = peer["first_name"] as? String, let last = peer["last_name"] as? String else {
            throw Guard.Stopped.invariant("frozen-peer-identity-required")
        }
        try Guard.require(frozen[identityFile] != nil && client["user_id"] as? String != peerID
            && String(describing: peer["id"] ?? "") == peerID
            && peer["email"] as? String == caregiver["email"] as? String
            && peer["role"] as? String == "caregiver", "frozen-identity-must-be-exact-owned-peer")
        let peerName = first + " " + last
        let content = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: nil)
        try Guard.require(content.status == 200, "public-English-managed-content-http200-required")
        guard let rows = content.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("managed-content-array-required") }
        for row in rows {
            guard let slug = row["slug"] as? String,
                  let translation = (row["translations"] as? [[String: Any]])?.first(where: {
                      ($0["language_id"] as? NSNumber)?.intValue == 1 || $0["language_id"] as? String == "1"
                  }), let value = translation["name"] as? String, !value.isEmpty else { continue }
            labels[slug] = value
        }
        for key in ["match_match_button", "match_match_message", "match_match_title", "match_introduction_title", "match_introduction_message", "general_cancel"] {
            try Guard.require(labels[key]?.isEmpty == false, "nonempty-managed-Match-copy-prerequisite-required")
        }
        app.launchArguments = ["--qa-request-counts"]; app.launchEnvironment = [:]; app.launch()
        try settlePasswordSavePrompt(requireMainReady: true)
        try Guard.require(app.staticTexts["qa-token-presence"].label == "accessPresent=true;refreshPresent=true", "existing-saved-session-required-no-repair")
        try writes([:]); try bottom("Profile")
        let owner = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", ownerEmail, ownerEmail)).firstMatch
        try Guard.require(owner.waitForExistence(timeout: 30), "actual-native-owned-client-email-required-before-peer-action")
        // Inspect the real selected-language trait without tapping a language or Save.
        let languageRows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@",
            text("profile_change_language_title", "Change Language"), text("profile_change_language_description", "Choose your preferred language")))
        let languageRow = try revealExactTabTarget(languageRows, tag: "readonly-current-language-row")
        try ready(languageRow); languageRow.tap()
        let english = app.buttons["English"].firstMatch
        try Guard.require(english.waitForExistence(timeout: 20) && english.isSelected, "actual-current-English-required-no-language-change")
        try capture("private-readonly-selected-English-without-changing-language", element: app)
        try back(); try writes([:]); try bottom(text("bottom_navigation_matches", "Matches"))
        let cards = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", peerName, text("general_miles_away", "mile(s) away")))
        try wait("actual-native-matches-list-required", timeout: 60) { self.count("GET /api/clients/matches") >= 1 && cards.count == 1 }
        let card = try revealExactTabTarget(cards, tag: "readonly-owned-peer-card")
        let profilePath = "GET /api/clients/caregivers/" + peerID
        let readsBefore = count(profilePath)
        try ready(card); card.tap()
        try wait("exact-owned-peer-profile-GET-after-actual-card-tap-required", timeout: 60) {
            self.count(profilePath) > readsBefore && self.app.staticTexts[peerName].firstMatch.exists
        }
        let request = app.buttons["match-request"]; try ready(request)
        for id in ["match-withdraw", "match-reject", "match-accept", "match-unmatch"] {
            try Guard.require(!app.buttons[id].exists, "actual-owned-peer-must-remain-NONE")
        }
        try Guard.require(!app.buttons[text("caregiver_details_message", "Message")].exists, "NONE-profile-must-hide-Message")
        try writes([:]); request.tap()
        let title = text("match_match_button", "Request a Match")
        let contentView = app.scrollViews["match-request-content"].firstMatch
        try Guard.require(contentView.waitForExistence(timeout: 15), "actual-Match-form-content-required")
        let fullTitle = contentView.staticTexts.matching(NSPredicate(format: "label == %@", title))
        try wait("one-actual-full-managed-title-StaticText-required", timeout: 15) { fullTitle.count == 1 }
        let heading = fullTitle.element(boundBy: 0)
        try Guard.require(heading.identifier == "match-request-heading" && heading.label == title,
                          "full-managed-Match-form-heading-required")
        try Guard.require(heading.isHittable && app.frame.contains(heading.frame),
                          "managed-heading-must-be-painted-and-fully-contained")
        let body = app.staticTexts.matching(NSPredicate(format: "label == %@", text("match_match_message", ""))).firstMatch
        try Guard.require(body.exists && body.isHittable && app.staticTexts[text("match_introduction_title", "Introduction")].exists, "exact-managed-Match-question-body-and-heading-required")
        try capture("readonly-Match-managed-title-and-question-before-input", element: app)
        let input = app.textFields[text("match_introduction_title", "Introduction")]
        try ready(input)
        try Guard.require(input.placeholderValue == text("match_introduction_message", "")
            && (input.value as? String).map { $0.isEmpty || $0 == input.placeholderValue } == true,
            "managed-optional-placeholder-and-empty-introduction-required")
        let introduction = "Synthetic read-only native Match form " + String(repeating: "Complete first-line context. ", count: 5)
            + "\nSecond paragraph stays complete.\nFinal synthetic line."
        try Guard.require(introduction.prefix { !$0.isNewline }.count > 80 && introduction.count < 1000, "full-multiline-synthetic-intro-required")
        input.tap(); input.typeText(introduction)
        try Guard.require(input.value as? String == introduction, "full-introduction-value-must-be-preserved")
        let confirm = app.buttons["match-request-confirm"]
        try Guard.require(app.buttons.matching(identifier: "match-request-confirm").count == 1 && confirm.exists && confirm.label == text("match_match_title", "Match"), "confirm-identifier-and-exact-managed-action-label-required")
        try ready(confirm)
        try capture("private-readonly-Match-managed-title-body-full-introduction", element: app)
        try capture("readonly-Match-confirm-action-label", element: confirm)
        let ax = XCTAttachment(string: app.debugDescription)
        ax.name = "private-readonly-Match-managed-form-AX"; ax.lifetime = .keepAlways; add(ax)
        let cancel = app.buttons["match-request-dismiss"].firstMatch
        try Guard.require(cancel.label == text("general_cancel", "Cancel"), "exact-managed-Cancel-label-required")
        try ready(cancel); try writes([:]); cancel.tap()
        try Guard.require(heading.waitForNonExistence(timeout: 15), "actual-Match-sheet-must-dismiss")
        try ready(request); try writes([:]); try unchanged()
        try Guard.require(app.staticTexts["qa-token-presence"].label == "accessPresent=true;refreshPresent=true", "saved-session-presence-unchanged")
        let proof = XCTAttachment(string: "supplementalP23001CopyInspection=true;actualCurrentEnglishSelected=true;languageChanged=false;nativeOwnerEmailMatched=true;exactPeerProfileGETAfterCardTap=true;managedTitleBodyPlaceholderConfirmLabel=true;confirmActionIdentifier=true;fullMultilineIntroduction=true;nativeCancelDismissed=true;confirmNeverTapped=true;officialProofLogins=0;nativeLoginPOSTs=0;allAppRequestsGET=true;allSevenPriorControlsAndJournalsAndFixturesUnchanged=true\n" + app.staticTexts["qa-request-counts"].label)
        proof.name = "private-readonly-Match-form-proof-redact-ID-paths-before-curation"; proof.lifetime = .keepAlways; add(proof)
    }

    /// Supplemental Small r2: preserve and inspect the existing saved locale.
    /// Copy inspection only: uses an already saved client,
    /// never initializes the graph journal or performs proof/login/match writes.
    func testExistingOwnedClientCurrentLocaleMatchFormDismissesWithoutMutation() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_MATCH_FORM_CURRENT_LOCALE_READONLY"] == "1",
              let code = env["QA_NATIVE_MATCH_FORM_EXPECTED_LANGUAGE_CODE"],
              let rawLanguageID = env["QA_NATIVE_MATCH_FORM_EXPECTED_LANGUAGE_ID"], let languageID = Int(rawLanguageID),
              let cf = env["QA_NATIVE_GRAPH_CLIENT_FILE"], let gf = env["QA_NATIVE_GRAPH_CAREGIVER_FILE"],
              let identityFile = env["QA_NATIVE_MATCH_FORM_PEER_IDENTITY_FILE"],
              let frozenJSON = env["QA_NATIVE_MATCH_FORM_FROZEN_FILES"], let frozenData = frozenJSON.data(using: .utf8),
              let frozen = try JSONSerialization.jsonObject(with: frozenData) as? [String: String] else {
            throw XCTSkip("Explicit frozen-pair read-only Match-form inspection required")
        }
        func unchanged() throws {
            try Guard.require(frozen.count >= 17, "both-fixtures-seven-controls-seven-journals-peer-snapshot-required")
            for (path, expected) in frozen {
                try Guard.require(Guard.sha(try Data(contentsOf: URL(fileURLWithPath: path))) == expected,
                                  "read-only-frozen-file-must-remain-byte-identical")
            }
        }
        try unchanged()
        let client = try NativeLifecycleFixture.read(cf), caregiver = try NativeLifecycleFixture.read(gf)
        var run: String?
        for (role, fixture, path) in [("client", client, cf), ("caregiver", caregiver, gf)] {
            guard let p = fixture["native_provenance"] as? [String: Any], let marker = p["marker"] as? String,
                  let email = fixture["email"] as? String, let id = fixture["user_id"] as? String,
                  let nativeRun = p["run_id"] as? String else { throw Guard.Stopped.invariant("exact-owned-fixture-required") }
            try Guard.require(frozen[path] != nil && p["purpose"] as? String == "carezaar-native-final-qa"
                && p["stage"] as? String == "signupComplete" && p["role"] as? String == role
                && fixture["role"] as? String == role && p["size"] as? String == "modern"
                && p["provider_create_attempts"] as? Int == 1 && p["app_registration_attempts"] as? Int == 1
                && p["provider_ownership_verified"] as? Bool == true && fixture["deleted"] as? Bool != true
                && email.hasPrefix("carezaar-native-\(marker)@") && !id.isEmpty,
                "same-completed-native-purpose-pair-required")
            if let run { try Guard.require(run == nativeRun, "same-native-provenance-run-required") }
            else { run = nativeRun }
        }
        guard let ownerEmail = client["email"] as? String, let peerID = caregiver["user_id"] as? String,
              let peer = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: identityFile))) as? [String: Any],
              let first = peer["first_name"] as? String, let last = peer["last_name"] as? String else {
            throw Guard.Stopped.invariant("frozen-peer-identity-required")
        }
        try Guard.require(frozen[identityFile] != nil && client["user_id"] as? String != peerID
            && String(describing: peer["id"] ?? "") == peerID
            && peer["email"] as? String == caregiver["email"] as? String
            && peer["role"] as? String == "caregiver", "frozen-identity-must-be-exact-owned-peer")
        let peerName = first + " " + last
        let languageResponse = try CarezaarAPI.callWithHTTPStatus("GET", "base/languages?ts_cache=0", token: nil)
        try Guard.require(languageResponse.status == 200 && languageID > 0 && !code.isEmpty, "actual-stored-locale-and-public-language-http200-required")
        guard let languages = languageResponse.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("public-language-array-required") }
        let currentLanguages = languages.filter { ($0["id"] as? Int) == languageID && ($0["code"] as? String) == code }
        guard currentLanguages.count == 1, let languageName = currentLanguages[0]["name"] as? String, !languageName.isEmpty else {
            throw Guard.Stopped.invariant("stored-code-ID-must-bind-one-real-language")
        }
        let content = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: nil)
        try Guard.require(content.status == 200, "public-managed-content-http200-required")
        guard let rows = content.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("managed-content-array-required") }
        // Match Localization.t: current translation (including empty) takes
        // precedence over English; an empty chosen value then uses caller fallback.
        // The only production correction rows concern password placeholders, none
        // of the navigation or Match slugs inspected here.
        for row in rows {
            guard let slug = row["slug"] as? String, let translations = row["translations"] as? [[String: Any]] else { continue }
            func translated(_ id: Int) -> String? {
                translations.first { ($0["language_id"] as? NSNumber)?.intValue == id || $0["language_id"] as? String == String(id) }?["name"] as? String
            }
            if let chosen = translated(languageID) ?? translated(1), !chosen.isEmpty { labels[slug] = chosen }
        }
        // Caller fallbacks from MatchRequestSheet, preserving Localization.t's
        // empty-current-value rule rather than silently substituting English.
        let formFallbacks = ["match_match_button": "Request a Match",
            "match_match_message": "Are you sure you want to match with this user? They should accept your request.",
            "match_match_title": "Match", "match_introduction_title": "Introduction",
            "match_introduction_message": "You can introduce yourself here (Optional)", "general_cancel": "Cancel"]
        for (key, fallback) in formFallbacks where labels[key] == nil { labels[key] = fallback }
        app.launchArguments = ["--qa-request-counts"]; app.launchEnvironment = [:]; app.launch()
        try settlePasswordSavePrompt(requireMainReady: true)
        try Guard.require(app.staticTexts["qa-token-presence"].label == "accessPresent=true;refreshPresent=true", "existing-saved-session-required-no-repair")
        try writes([:]); try bottom(text("bottom_navigation_profile", "Profile"))
        let owner = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", ownerEmail, ownerEmail)).firstMatch
        try Guard.require(owner.waitForExistence(timeout: 30), "actual-native-owned-client-email-required-before-peer-action")
        // Inspect the real selected-language trait without tapping a language or Save.
        let languageRows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@",
            text("profile_change_language_title", "Change Language"), text("profile_change_language_description", "Choose your preferred language")))
        let languageRow = try revealExactTabTarget(languageRows, tag: "readonly-current-language-row")
        try ready(languageRow); languageRow.tap()
        let selectedLanguage = app.buttons[languageName].firstMatch
        try Guard.require(selectedLanguage.waitForExistence(timeout: 20) && selectedLanguage.isSelected, "actual-current-language-trait-must-match-stored-code-ID-no-change")
        try capture("private-readonly-selected-current-language-without-changing-language", element: app)
        try back(); try writes([:]); try bottom(text("bottom_navigation_matches", "Matches"))
        let cards = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", peerName, text("general_miles_away", "mile(s) away")))
        try wait("actual-native-matches-list-required", timeout: 60) { self.count("GET /api/clients/matches") >= 1 && cards.count == 1 }
        let card = try revealExactTabTarget(cards, tag: "readonly-owned-peer-card")
        let profilePath = "GET /api/clients/caregivers/" + peerID
        let readsBefore = count(profilePath)
        try ready(card); card.tap()
        try wait("exact-owned-peer-profile-GET-after-actual-card-tap-required", timeout: 60) {
            self.count(profilePath) > readsBefore && self.app.staticTexts[peerName].firstMatch.exists
        }
        let request = app.buttons["match-request"]; try ready(request)
        for id in ["match-withdraw", "match-reject", "match-accept", "match-unmatch"] {
            try Guard.require(!app.buttons[id].exists, "actual-owned-peer-must-remain-NONE")
        }
        try Guard.require(!app.buttons[text("caregiver_details_message", "Message")].exists, "NONE-profile-must-hide-Message")
        try writes([:]); request.tap()
        let title = text("match_match_button", "Request a Match")
        let contentView = app.scrollViews["match-request-content"].firstMatch
        try Guard.require(contentView.waitForExistence(timeout: 15), "actual-Match-form-content-required")
        let fullTitle = contentView.staticTexts.matching(NSPredicate(format: "label == %@", title))
        try wait("one-actual-full-managed-title-StaticText-required", timeout: 15) { fullTitle.count == 1 }
        let heading = fullTitle.element(boundBy: 0)
        try Guard.require(heading.identifier == "match-request-heading" && heading.label == title,
                          "full-managed-Match-form-heading-required")
        try Guard.require(heading.isHittable && app.frame.contains(heading.frame),
                          "managed-heading-must-be-painted-and-fully-contained")
        let body = app.staticTexts.matching(NSPredicate(format: "label == %@", text("match_match_message", ""))).firstMatch
        try Guard.require(body.exists && body.isHittable && app.staticTexts[text("match_introduction_title", "Introduction")].exists, "exact-managed-Match-question-body-and-heading-required")
        try capture("readonly-Match-managed-title-and-question-before-input", element: app)
        let input = app.textFields[text("match_introduction_title", "Introduction")]
        try ready(input)
        try Guard.require(input.placeholderValue == text("match_introduction_message", "")
            && (input.value as? String).map { $0.isEmpty || $0 == input.placeholderValue } == true,
            "managed-optional-placeholder-and-empty-introduction-required")
        let introduction = "Synthetic read-only native Match form " + String(repeating: "Complete first-line context. ", count: 5)
            + "\nSecond paragraph stays complete.\nFinal synthetic line."
        try Guard.require(introduction.prefix { !$0.isNewline }.count > 80 && introduction.count < 1000, "full-multiline-synthetic-intro-required")
        input.tap(); input.typeText(introduction)
        try Guard.require(input.value as? String == introduction, "full-introduction-value-must-be-preserved")
        if inspectKeyboardFinalLine { try exposeSyntheticFinalLineAboveMeasuredKeyboard(input: input, value: introduction) }
        let confirm = app.buttons["match-request-confirm"]
        try Guard.require(app.buttons.matching(identifier: "match-request-confirm").count == 1 && confirm.exists && confirm.label == text("match_match_title", "Match"), "confirm-identifier-and-exact-managed-action-label-required")
        try ready(confirm)
        try capture("private-readonly-Match-managed-title-body-full-introduction", element: app)
        try capture("readonly-Match-confirm-action-label", element: confirm)
        let ax = XCTAttachment(string: app.debugDescription)
        ax.name = "private-readonly-Match-managed-form-AX"; ax.lifetime = .keepAlways; add(ax)
        let cancel = app.buttons["match-request-dismiss"].firstMatch
        try Guard.require(cancel.label == text("general_cancel", "Cancel"), "exact-managed-Cancel-label-required")
        try ready(cancel); try writes([:]); cancel.tap()
        try Guard.require(heading.waitForNonExistence(timeout: 15), "actual-Match-sheet-must-dismiss")
        try ready(request); try writes([:]); try unchanged()
        // Reinspect actual selected trait after form dismissal; do not select or Save.
        try back(); try bottom(text("bottom_navigation_profile", "Profile"))
        let afterLanguageRows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@",
            text("profile_change_language_title", "Change Language"), text("profile_change_language_description", "Choose your preferred language")))
        let afterLanguageRow = try revealExactTabTarget(afterLanguageRows, tag: "readonly-current-language-after-form")
        try ready(afterLanguageRow); afterLanguageRow.tap()
        try Guard.require(selectedLanguage.waitForExistence(timeout: 20) && selectedLanguage.isSelected, "selected-current-language-must-remain-unchanged-after-form")
        try capture("private-readonly-current-language-still-selected-after-form", element: app)
        try back(); try writes([:]); try unchanged()
        try Guard.require(app.staticTexts["qa-token-presence"].label == "accessPresent=true;refreshPresent=true", "saved-session-presence-unchanged")
        let proof = XCTAttachment(string: "supplementalP23001CopyInspection=true;actualStoredLocaleBoundToPublicLanguage=true;actualSelectedLanguageTraitBeforeAndAfter=true;languageChanged=false;nativeOwnerEmailMatched=true;exactPeerProfileGETAfterCardTap=true;managedTitleBodyPlaceholderConfirmLabel=true;confirmActionIdentifier=true;fullMultilineIntroduction=true;nativeCancelDismissed=true;confirmNeverTapped=true;officialProofLogins=0;nativeLoginPOSTs=0;allAppRequestsGET=true;allSevenPriorControlsAndJournalsAndFixturesUnchanged=true;languageCode=\(code);languageID=\(languageID)\n" + app.staticTexts["qa-request-counts"].label)
        proof.name = "private-readonly-current-locale-Match-form-proof-redact-ID-paths-before-curation"; proof.lifetime = .keepAlways; add(proof)
    }

    /// Supplemental read-only keyboard proof, retaining every ordinary form guard.
    func testExistingOwnedClientSmallMatchFinalLineExposureWithoutMutation() throws {
        guard ProcessInfo.processInfo.environment["QA_NATIVE_MATCH_KEYBOARD_EXPOSURE"] == "1" else {
            throw XCTSkip("Explicit reviewed Small keyboard exposure supplement required")
        }
        inspectKeyboardFinalLine = true
        defer { inspectKeyboardFinalLine = false }
        try testExistingOwnedClientCurrentLocaleMatchFormDismissesWithoutMutation()
    }

    private func exposeSyntheticFinalLineAboveMeasuredKeyboard(input: XCUIElement, value: String) throws {
        let content = app.scrollViews["match-request-content"].firstMatch
        let keyboards = app.keyboards
        func normalized(_ string: String) -> String {
            String(String.UnicodeScalarView(string.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })).lowercased()
        }
        let target = normalized("Final synthetic line.")
        for attempt in 0...3 {
            try Guard.require(content.exists && keyboards.count == 1 && input.value as? String == value,
                              "actual-form-keyboard-and-unchanged-full-input-required")
            let appFrame = app.frame, contentFrame = content.frame, inputFrame = input.frame, keyboardFrame = keyboards.element(boundBy: 0).frame
            try Guard.require(appFrame.contains(keyboardFrame) && keyboardFrame.width > 0 && keyboardFrame.height > 0,
                              "measured-native-keyboard-frame-required")
            // iOS exposes its real suggestion strip as a separate full-width
            // ScrollView immediately adjoining the top of the keyboard proper.
            let accessoryFrames = app.scrollViews.allElementsBoundByIndex.filter {
                $0.identifier != "match-request-content"
            }.map(\.frame).filter {
                $0.height > 0 && $0.height <= 88 && $0.width >= keyboardFrame.width * 0.9
                    && abs($0.maxY - keyboardFrame.minY) <= 1 && $0.minY < keyboardFrame.minY
                    && appFrame.contains($0)
            }
            var uniqueAccessories: [CGRect] = []
            for frame in accessoryFrames where !uniqueAccessories.contains(frame) { uniqueAccessories.append(frame) }
            try Guard.require(uniqueAccessories.count <= 1, "unknown-keyboard-accessory-geometry-stop")
            let envelopeTop = min(keyboardFrame.minY, uniqueAccessories.first?.minY ?? keyboardFrame.minY)
            let visible = contentFrame.intersection(appFrame).intersection(CGRect(x: appFrame.minX, y: appFrame.minY,
                width: appFrame.width, height: envelopeTop - appFrame.minY))
            try Guard.require(!visible.isNull && visible.width > 0 && visible.height > 60,
                              "actual-content-above-keyboard-envelope-required")
            let screenshot = app.screenshot()
            let imageAttachment = XCTAttachment(screenshot: screenshot)
            imageAttachment.name = "private-small-final-line-OCR-attempt-\(attempt)"; imageAttachment.lifetime = .keepAlways; add(imageAttachment)
            guard let cgImage = screenshot.image.cgImage else { throw Guard.Stopped.invariant("OCR-image-unavailable-raster-preserved-no-product-inference") }
            try Guard.require(abs(Double(cgImage.width) / Double(cgImage.height) - Double(appFrame.width / appFrame.height)) < 0.01,
                              "screenshot-to-logical-frame-aspect-must-match")
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false; request.recognitionLanguages = ["en-US"]
            do { try VNImageRequestHandler(cgImage: cgImage).perform([request]) }
            catch { throw Guard.Stopped.invariant("Vision-OCR-failed-raster-preserved-no-product-inference") }
            // Never log other recognized text, user strings or private hierarchy.
            let boxes = (request.results ?? []).compactMap { observation -> CGRect? in
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.7,
                      normalized(candidate.string) == target else { return nil }
                let b = observation.boundingBox
                return CGRect(x: appFrame.minX + b.minX * appFrame.width,
                    y: appFrame.minY + (1 - b.maxY) * appFrame.height,
                    width: b.width * appFrame.width, height: b.height * appFrame.height)
            }
            let exposed = boxes.filter { $0.width > 0 && $0.height > 0 && appFrame.contains($0)
                && visible.contains($0) && inputFrame.insetBy(dx: -1, dy: -1).contains($0) && $0.maxY < envelopeTop }
            let geometry = XCTAttachment(string: "attempt=\(attempt);app=\(appFrame);content=\(contentFrame);input=\(inputFrame);keyboard=\(keyboardFrame);accessories=\(uniqueAccessories);envelopeTop=\(envelopeTop);visible=\(visible);exactSyntheticFinalLineBoxes=\(boxes);fullyExposedMatches=\(exposed.count);full238CharacterValueUnchanged=\(input.value as? String == value);otherOCRTextLogged=false")
            geometry.name = "small-keyboard-final-line-measured-geometry-\(attempt)"; geometry.lifetime = .keepAlways; add(geometry)
            if exposed.count == 1 {
                try Guard.require(input.value as? String == value && value.count == 238, "original-full-introduction-must-remain-exact")
                try writes([:])
                return
            }
            try Guard.require(attempt < 3, "final-line-not-proved-by-bounded-OCR-raster-preserved-no-product-inference")
            // AX may clip the input exactly at the accessory boundary even when
            // the last painted line is behind it. Permit <=1pt boundary rounding.
            try Guard.require(inputFrame.maxY >= envelopeTop - 1, "OCR-target-missing-without-measured-keyboard-clipping-stop")
            let marginWidth = inputFrame.minX - contentFrame.minX
            try Guard.require(marginWidth >= 12, "real-parent-form-margin-required-no-text-selection")
            let x = contentFrame.minX + marginWidth / 2
            let startY = visible.maxY - 12
            let distance = min(CGFloat(64), visible.height * 0.2)
            let endY = startY - distance
            let startPoint = CGPoint(x: x, y: startY), endPoint = CGPoint(x: x, y: endY)
            try Guard.require(visible.contains(startPoint) && visible.contains(endPoint)
                && x <= inputFrame.minX - 4 && endY > visible.minY + 12 && distance >= 12,
                "measured-short-parent-margin-drag-must-avoid-field-and-toolbar")
            let drag = XCTAttachment(string: "attempt=\(attempt + 1);start=\(startPoint);end=\(endPoint);distance=\(distance);outsideInputHorizontalBounds=true;normalScrollOnly=true")
            drag.name = "small-keyboard-parent-margin-drag-\(attempt + 1)"; drag.lifetime = .keepAlways; add(drag)
            let origin = content.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: x - contentFrame.minX, dy: startY - contentFrame.minY))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: x - contentFrame.minX, dy: endY - contentFrame.minY)),
                       withVelocity: .slow, thenHoldForDuration: 0.5)
            try Guard.require(input.value as? String == value, "normal-parent-scroll-must-not-edit-introduction")
        }
    }

    func testExistingOwnedCaregiverBoundRequestReadOnlyWithoutLogin() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_GRAPH_RECIPIENT_READONLY"] == "1",
              let cf = env["QA_NATIVE_GRAPH_CLIENT_FILE"], let gf = env["QA_NATIVE_GRAPH_CAREGIVER_FILE"],
              let source = env["QA_NATIVE_GRAPH_SOURCE_JOURNAL_FILE"], let expectedSHA = env["QA_NATIVE_GRAPH_SOURCE_JOURNAL_SHA256"] else {
            throw XCTSkip("Explicit existing-edge recipient read-only diagnostic required")
        }
        let sourceURL = URL(fileURLWithPath: source)
        let sourceBytes = try Data(contentsOf: sourceURL)
        try Guard.require(Guard.sha(sourceBytes) == expectedSHA, "immutable-r4-journal-required")
        guard let old = try JSONSerialization.jsonObject(with: sourceBytes) as? [String: Any],
              let edge = old["edgeID"] as? Int, let introduction = old["introduction"] as? String else {
            throw Guard.Stopped.invariant("existing-bound-edge-required")
        }
        let client = try NativeLifecycleFixture.read(cf), caregiver = try NativeLifecycleFixture.read(gf)
        let clientBytes = try Data(contentsOf: URL(fileURLWithPath: cf)), caregiverBytes = try Data(contentsOf: URL(fileURLWithPath: gf))
        for (role, fixture, bytes) in [("client", client, clientBytes), ("caregiver", caregiver, caregiverBytes)] {
            guard let p = fixture["native_provenance"] as? [String: Any], let marker = p["marker"] as? String,
                  let email = fixture["email"] as? String, let id = fixture["user_id"] as? String else {
                throw Guard.Stopped.invariant("exact-owned-complete-fixture-required")
            }
            try Guard.require(p["purpose"] as? String == "carezaar-native-final-qa"
                && p["stage"] as? String == "signupComplete" && p["role"] as? String == role
                && fixture["role"] as? String == role && p["size"] as? String == "modern"
                && p["provider_create_attempts"] as? Int == 1 && p["app_registration_attempts"] as? Int == 1
                && p["provider_ownership_verified"] as? Bool == true && fixture["deleted"] as? Bool != true
                && email.hasPrefix("carezaar-native-\(marker)@") && old[role + "ID"] as? String == id
                && old[role + "FixtureSHA256"] as? String == Guard.sha(bytes)
                && old["nativeRunID"] as? String == p["run_id"] as? String, "bound-pair-and-provenance-required")
        }
        try Guard.require(old["phase"] as? String == "test-stopped-no-automatic-cleanup"
            && old["requestAttempts"] as? Int == 1 && old["withdrawAttempts"] == nil
            && edge > 0 && introduction.hasPrefix("Synthetic native client Cancel "), "one-existing-unwithdrawn-marked-edge-required")
        let identityURL = sourceURL.deletingLastPathComponent().appendingPathComponent("official-client-identity.json")
        guard let identity = try JSONSerialization.jsonObject(with: Data(contentsOf: identityURL)) as? [String: Any],
              let first = identity["first_name"] as? String, let last = identity["last_name"] as? String, let snapshotID = identity["id"],
              let email = caregiver["email"] as? String, let clientID = client["user_id"] as? String else {
            throw Guard.Stopped.invariant("bound-requester-identity-snapshot-required")
        }
        try Guard.require(String(describing: snapshotID) == clientID && identity["email"] as? String == client["email"] as? String
            && identity["role"] as? String == "client", "snapshot-must-match-bound-client")
        let peerName = first + " " + last
        app.launchArguments = ["--qa-request-counts"]; app.launchEnvironment = [:]; app.launch()
        try settlePasswordSavePrompt() // Positive task prompt only, before hittable Main wait.
        try ready(app.buttons["Messages"].firstMatch, timeout: 90)
        try Guard.require(app.staticTexts["qa-token-presence"].label == "accessPresent=true;refreshPresent=true", "saved-caregiver-session-required-no-login")
        try writes([:]); try bottom("Profile")
        let ownEmail = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", email, email)).firstMatch
        try Guard.require(ownEmail.waitForExistence(timeout: 20), "actual-owned-caregiver-native-email-required")
        try capture("private-readonly-owned-caregiver-Profile", element: app)
        try bottom("Matches")
        let cards = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", peerName, "mile(s) away"))
        try wait("readonly-actual-bound-client-card-required") { cards.count == 1 && cards.firstMatch.isHittable }
        try ready(cards.firstMatch); cards.firstMatch.tap()
        try wait("readonly-exact-bound-client-profile-required") {
            self.count("GET /api/caregivers/clients/" + clientID) >= 1 && self.app.staticTexts[peerName].firstMatch.exists
        }
        try ready(app.buttons["match-reject"]); try ready(app.buttons["match-accept"])
        for id in ["match-request", "match-withdraw", "match-unmatch"] { try Guard.require(!app.buttons[id].exists, "received-only-actions-required") }
        try Guard.require(!app.buttons["Message"].exists
            && !app.staticTexts.matching(NSPredicate(format: "label == %@", introduction)).firstMatch.exists,
            "received-profile-must-hide-Message-and-top-intro")
        let reject = app.buttons["match-reject"].frame, accept = app.buttons["match-accept"].frame
        try Guard.require(abs(reject.midY - accept.midY) < 8 ? reject.midX < accept.midX : reject.midY < accept.midY, "Reject-before-Accept-required")
        try capture("private-readonly-bound-RECEIVED-profile", element: app)
        try back(); try bottom("Profile")
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Matches")).allElementsBoundByIndex.filter { $0.isHittable && $0.frame.maxY < self.app.frame.height - 90 }
        try Guard.require(rows.count == 1, "unique-native-Manage-Matches-row-required"); try ready(rows[0]); rows[0].tap()
        let requests = app.buttons["Requests"].firstMatch; try ready(requests)
        let before = count("GET /api/users/matches"); requests.tap()
        try wait("readonly-Requests-tab-live-load-required", timeout: 60) { requests.isSelected && self.count("GET /api/users/matches") > before }
        let preview = app.buttons["match-introduction-\(edge)"]; try ready(preview, timeout: 60)
        let firstLine = String(introduction.prefix { !$0.isNewline })
        try Guard.require(preview.label == "Introduction: " + firstLine && firstLine.count > 80, "exact-bound-complete-preview-required")
        let profileReads = count("GET /api/caregivers/clients/" + clientID); preview.tap()
        let detail = app.descendants(matching: .any)["match-introduction-detail"].firstMatch
        try Guard.require(detail.waitForExistence(timeout: 15)
            && detail.staticTexts.matching(NSPredicate(format: "label == %@", introduction)).firstMatch.exists
            && detail.staticTexts[peerName].exists, "full-bound-intro-and-requester-required")
        try capture("private-readonly-bound-full-introduction", element: detail)
        let close = detail.buttons["Cancel"].firstMatch; try ready(close); close.tap()
        try Guard.require(detail.waitForNonExistence(timeout: 10) && count("GET /api/caregivers/clients/" + clientID) == profileReads,
                          "intro-close-no-profile-navigation-required")
        try writes([:])
        try Guard.require(try Data(contentsOf: sourceURL) == sourceBytes, "r4-journal-byte-identical-required")
        try Guard.require(try Data(contentsOf: URL(fileURLWithPath: cf)) == clientBytes, "client-fixture-unchanged")
        try Guard.require(try Data(contentsOf: URL(fileURLWithPath: gf)) == caregiverBytes, "caregiver-fixture-unchanged")
        let proof = XCTAttachment(string: "ordinarySavedCaregiver=true;nativeOwnedEmailMatched=true;boundRequesterProfileRECEIVED=true;RejectBeforeAccept=true;MessageAndTopIntroAbsent=true;exactExistingEdgePreview=true;fullIntroAndRequesterMatched=true;introCloseNoProfileNavigation=true;sourceJournalAndBothFixturesUnchanged=true;officialProofLogins=0;nativeLoginPOSTs=0;graphWrites=0;allAppRequestsGET=true\n" + app.staticTexts["qa-request-counts"].label)
        proof.name = "readonly-bound-recipient-anonymous"; proof.lifetime = .keepAlways; add(proof)
    }

    func testClientOriginatedMarkedRequestCancelAndHistory() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_GRAPH_CLIENT_CANCEL"] == "1" else { throw XCTSkip("Explicit first native graph phase approval required") }
        let j = try NativeOwnedGraphJournal(environment: env); journal = j
        try j.officialProof("client"); try j.officialProof("caregiver")
        let before = try j.requirePair("none")
        try j.privateSnapshot("before-reciprocal-profiles.json", before)
        try j.snapshotHistory()
        // Both roles must be eligible before the first graph write, not just
        // after creating a request which the recipient could not reach.
        try firstPagePeer("client", j: j); try firstPagePeer("caregiver", j: j)
        let content = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0")
        try Guard.require(content.status == 200, "public-managed-text-http200-required")
        guard let rows = content.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("managed-array-required") }
        for row in rows {
            guard let slug = row["slug"] as? String,
                  let translation = (row["translations"] as? [[String: Any]])?.first(where: {
                      ($0["language_id"] as? NSNumber)?.intValue == 1 || $0["language_id"] as? String == "1"
                  }), let text = translation["name"] as? String, !text.isEmpty else { continue }
            labels[slug] = text
        }
        try Guard.require(text("general_cancel", "Cancel") == "Cancel", "governing-English-Cancel-required")
        try signIn("client", journal: j)
        try openExactPeerFromActualMatches(j)
        try profileState("none", j: j)
        try openRequestAndEnterIntroduction(j)
        try dismissRequestSheet(j)
        try writes(["POST /api/auth/login": 1])
        _ = try j.requirePair("none")
        try j.event("request-form-dismissed-no-write")
        try openRequestAndEnterIntroduction(j)
        let confirmRequest = app.buttons["match-request-confirm"]
        try ready(confirmRequest)
        try writes(["POST /api/auth/login": 1])
        try j.requestIntent() // Durable/fsynced BEFORE the sole actual create tap.
        confirmRequest.tap()
        try ready(app.buttons["match-withdraw"], timeout: 60)
        try writes(["POST /api/auth/login": 1, "POST /api/users/matches": 1])
        let edge = try j.bindCreatedPendingEdge()
        try profileState("sent", j: j)
        try capture("owned-client-created-pending-control", element: app.buttons["match-withdraw"])
        try j.event("client-native-pending-inspected")

        try signIn("caregiver", journal: j)
        try openExactPeerFromActualMatches(j)
        try profileState("received", j: j)
        _ = try j.requirePair("pending", edge: edge)
        try writes(["POST /api/auth/login": 1])
        try inspectManageRequestsIntroduction(j, edge: edge)
        _ = try j.requirePair("pending", edge: edge)
        try writes(["POST /api/auth/login": 1])
        try j.event("recipient-native-pending-and-full-introduction-inspected")

        try signIn("client", journal: j)
        try openExactPeerFromActualMatches(j)
        try profileState("sent", j: j)
        let outgoing = app.buttons["match-withdraw"]
        try ready(outgoing)
        try Guard.require(outgoing.label == text("general_cancel", "Cancel") && outgoing.label != "Withdraw", "outgoing-label-must-be-managed-Cancel")
        let withdrawal = "DELETE /api/users/matches/\(edge)/withdraw"
        for confirm in [false, true] {
            try ready(outgoing); outgoing.tap()
            let dialog = app.alerts[text("general_cancel", "Cancel")]
            try Guard.require(dialog.waitForExistence(timeout: 10), "managed-Cancel-alert-title-required")
            let dismiss = dialog.buttons.matching(identifier: "match-confirm-dismiss").firstMatch
            let action = dialog.buttons.matching(identifier: "match-action-confirm").firstMatch
            try ready(dismiss); try ready(action)
            try Guard.require(dismiss.label == "Cancel" && action.label == "Cancel", "both-distinct-Cancel-controls-required")
            let nodes = dialog.buttons.allElementsBoundByIndex
            let targets = Set(nodes.map { "\($0.identifier):\(NSCoder.string(for: $0.frame))" })
            try Guard.require(Set(nodes.map(\.identifier)) == ["match-confirm-dismiss", "match-action-confirm"]
                && nodes.allSatisfy { $0.label == "Cancel" } && targets.count == 2,
                "exact-two-identified-Cancel-hit-targets-required")
            try capture(confirm ? "owned-client-Cancel-before-confirm" : "owned-client-Cancel-before-dismiss", element: dialog)
            try writes(["POST /api/auth/login": 1])
            _ = try j.requirePair("pending", edge: edge); _ = try j.ownedEdge(edge)
            if confirm {
                try j.withdrawalIntent(edge) // Durable exact edge intent BEFORE tap.
                action.tap()
                try ready(app.buttons["match-request"], timeout: 60)
                try writes(["POST /api/auth/login": 1, withdrawal: 1])
                _ = try j.requirePair("none")
                try j.event("native-withdraw-acknowledged-both-none")
            } else {
                dismiss.tap()
                try Guard.require(dialog.waitForNonExistence(timeout: 10), "Cancel-dismiss-must-close-alert")
                try writes(["POST /api/auth/login": 1])
                _ = try j.requirePair("pending", edge: edge)
                try j.event("native-Cancel-dismiss-preserved-pending")
            }
        }
        try j.verifyHistoryAfterWithdrawal(edge)
        try inspectClientHistory(j)
        try writes(["POST /api/auth/login": 1, withdrawal: 1])
        _ = try j.requirePair("none")
        try j.verifyProvenanceUnchanged()
        try j.privateSnapshot("final-reciprocal-profiles.json", j.profiles())
        try j.event("complete-both-none-history-and-provenance-preserved", ["nativeUIloginAttempts": 3,
            "officialProofLoginAttemptsPerRole": 1, "nativeRequestPOSTs": 1, "nativeWithdrawalDELETEs": 1,
            "requestFormDismissPOSTs": 0, "cancelDialogDismissDELETEs": 0, "recipientGraphWrites": 0])
        let proof = XCTAttachment(string: "phase=client-originated-Cancel;exactNativePurposePair=true;actualMatchesCards=true;requestFormDismissPOSTs=0;nativeRequestPOSTs=1;recipientFullIntroAndActionOrder=true;CancelDismissDELETEs=0;nativeWithdrawDELETEs=1;bothFinalNONE=true;historyPreserved=true;cancelledHistoryPolicyObserved=true;finishedUnmatchHistoryCovered=false;fixtureBytesUnchanged=true;officialLoginsPerRole=1;visibleUIlogins=3;hiddenLogin=false;otherBackendWrites=0\n" + app.staticTexts["qa-request-counts"].label)
        proof.name = "native-owned-client-Cancel-anonymous"; proof.lifetime = .keepAlways; add(proof)
    }
    /// Completes only the already bound r4 edge. No request form/create call.
    func testContinueExactR4RecipientInspectionAndNativeCancelWithoutNewRequest() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_GRAPH_WITHDRAW_CONTINUATION"] == "1" else {
            throw XCTSkip("Explicit immutable-bound-edge continuation approval required")
        }
        let j = try NativeOwnedGraphJournal(environment: env); journal = j
        try j.officialProof("client"); try j.officialProof("caregiver")
        let edge = try j.verifyContinuationReady()
        let content = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0")
        try Guard.require(content.status == 200, "public-managed-text-http200-required")
        guard let rows = content.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("managed-array-required") }
        for row in rows {
            guard let slug = row["slug"] as? String,
                  let translation = (row["translations"] as? [[String: Any]])?.first(where: {
                      ($0["language_id"] as? NSNumber)?.intValue == 1 || $0["language_id"] as? String == "1"
                  }), let text = translation["name"] as? String, !text.isEmpty else { continue }
            labels[slug] = text
        }
        try Guard.require(text("general_cancel", "Cancel") == "Cancel", "governing-English-Cancel-required")
        try signIn("caregiver", journal: j)
        try openExactPeerFromActualMatches(j)
        try profileState("received", j: j)
        try inspectManageRequestsIntroduction(j, edge: edge)
        _ = try j.requirePair("pending", edge: edge); _ = try j.ownedEdge(edge)
        try writes(["POST /api/auth/login": 1])
        try j.event("continuation-recipient-full-introduction-inspected-no-write")
        try signIn("client", journal: j)
        try openExactPeerFromActualMatches(j)
        try profileState("sent", j: j)
        let outgoing = app.buttons["match-withdraw"]
        try ready(outgoing)
        try Guard.require(outgoing.label == text("general_cancel", "Cancel") && outgoing.label != "Withdraw", "outgoing-label-must-be-managed-Cancel")
        let withdrawal = "DELETE /api/users/matches/\(edge)/withdraw"
        for confirm in [false, true] {
            try ready(outgoing); outgoing.tap()
            let dialog = app.alerts[text("general_cancel", "Cancel")]
            try Guard.require(dialog.waitForExistence(timeout: 10), "managed-Cancel-alert-title-required")
            let dismiss = dialog.buttons.matching(identifier: "match-confirm-dismiss").firstMatch
            let action = dialog.buttons.matching(identifier: "match-action-confirm").firstMatch
            try ready(dismiss); try ready(action)
            try Guard.require(dismiss.label == "Cancel" && action.label == "Cancel", "both-distinct-Cancel-controls-required")
            let nodes = dialog.buttons.allElementsBoundByIndex
            let targets = Set(nodes.map { "\($0.identifier):\(NSCoder.string(for: $0.frame))" })
            try Guard.require(Set(nodes.map(\.identifier)) == ["match-confirm-dismiss", "match-action-confirm"]
                && nodes.allSatisfy { $0.label == "Cancel" } && targets.count == 2,
                "exact-two-identified-Cancel-hit-targets-required")
            try capture(confirm ? "owned-client-Cancel-before-confirm" : "owned-client-Cancel-before-dismiss", element: dialog)
            try writes(["POST /api/auth/login": 1])
            _ = try j.requirePair("pending", edge: edge); _ = try j.ownedEdge(edge)
            if confirm {
                try j.withdrawalIntent(edge) // Durable exact edge intent BEFORE tap.
                action.tap()
                try ready(app.buttons["match-request"], timeout: 60)
                try writes(["POST /api/auth/login": 1, withdrawal: 1])
                _ = try j.requirePair("none")
                try j.event("native-withdraw-acknowledged-both-none")
            } else {
                dismiss.tap()
                try Guard.require(dialog.waitForNonExistence(timeout: 10), "Cancel-dismiss-must-close-alert")
                try writes(["POST /api/auth/login": 1])
                _ = try j.requirePair("pending", edge: edge)
                try j.event("native-Cancel-dismiss-preserved-pending")
            }
        }
        try j.verifyHistoryAfterWithdrawal(edge)
        try inspectClientHistory(j)
        try writes(["POST /api/auth/login": 1, withdrawal: 1])
        _ = try j.requirePair("none")
        try j.verifyProvenanceUnchanged()
        try j.privateSnapshot("final-reciprocal-profiles.json", j.profiles())
        try j.event("continuation-complete-both-none-history-and-provenance", ["nativeUIloginAttempts": 2,
            "officialProofLoginAttemptsPerRole": 1, "newRequestAttempts": 0, "inheritedRequestAttempts": 1,
            "nativeWithdrawalDELETEs": 1, "cancelDialogDismissDELETEs": 0, "recipientGraphWrites": 0])
        let proof = XCTAttachment(string: "continuationOfExactR4Edge=true;newRequestPOSTs=0;inheritedRequestPOSTs=1;recipientFullIntroAndActionOrder=true;CancelDismissDELETEs=0;nativeWithdrawDELETEs=1;bothFinalNONE=true;historyPreserved=true;finishedUnmatchHistoryCovered=false;fixtureBytesUnchanged=true;officialLoginsPerRole=1;visibleUIlogins=2;hiddenLogin=false;otherBackendWrites=0\n" + app.staticTexts["qa-request-counts"].label)
        proof.name = "native-owned-exact-r4-withdraw-continuation-anonymous"; proof.lifetime = .keepAlways; add(proof)
    }

    /// Completes only the already bound Small edge. No request form/create call.
    func testContinueExactSmallRecipientInspectionAndNativeCancelWithoutNewRequest() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_GRAPH_WITHDRAW_CONTINUATION"] == "1" else {
            throw XCTSkip("Explicit immutable-bound-edge continuation approval required")
        }
        let j = try NativeOwnedGraphJournal(environment: env); journal = j
        try j.officialProof("client"); try j.officialProof("caregiver")
        let edge = try j.verifyContinuationReady()
        let content = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0")
        try Guard.require(content.status == 200, "public-managed-text-http200-required")
        guard let rows = content.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("managed-array-required") }
        for row in rows {
            guard let slug = row["slug"] as? String,
                  let translation = (row["translations"] as? [[String: Any]])?.first(where: {
                      ($0["language_id"] as? NSNumber)?.intValue == 1 || $0["language_id"] as? String == "1"
                  }), let text = translation["name"] as? String, !text.isEmpty else { continue }
            labels[slug] = text
        }
        try Guard.require(text("general_cancel", "Cancel") == "Cancel", "governing-English-Cancel-required")
        try signIn("caregiver", journal: j)
        try openExactPeerFromActualMatches(j)
        try profileState("received", j: j)
        try inspectManageRequestsIntroduction(j, edge: edge)
        _ = try j.requirePair("pending", edge: edge); _ = try j.ownedEdge(edge)
        try writes(["POST /api/auth/login": 1])
        try j.event("continuation-recipient-full-introduction-inspected-no-write")
        try signIn("client", journal: j)
        try openExactPeerFromActualMatches(j)
        try profileState("sent", j: j)
        let outgoing = app.buttons["match-withdraw"]
        try ready(outgoing)
        try Guard.require(outgoing.label == text("general_cancel", "Cancel") && outgoing.label != "Withdraw", "outgoing-label-must-be-managed-Cancel")
        let withdrawal = "DELETE /api/users/matches/\(edge)/withdraw"
        for confirm in [false, true] {
            try ready(outgoing); outgoing.tap()
            let dialog = app.alerts[text("general_cancel", "Cancel")]
            try Guard.require(dialog.waitForExistence(timeout: 10), "managed-Cancel-alert-title-required")
            let dismiss = dialog.buttons.matching(identifier: "match-confirm-dismiss").firstMatch
            let action = dialog.buttons.matching(identifier: "match-action-confirm").firstMatch
            try ready(dismiss); try ready(action)
            try Guard.require(dismiss.label == "Cancel" && action.label == "Cancel", "both-distinct-Cancel-controls-required")
            let nodes = dialog.buttons.allElementsBoundByIndex
            let targets = Set(nodes.map { "\($0.identifier):\(NSCoder.string(for: $0.frame))" })
            try Guard.require(Set(nodes.map(\.identifier)) == ["match-confirm-dismiss", "match-action-confirm"]
                && nodes.allSatisfy { $0.label == "Cancel" } && targets.count == 2,
                "exact-two-identified-Cancel-hit-targets-required")
            try capture(confirm ? "owned-client-Cancel-before-confirm" : "owned-client-Cancel-before-dismiss", element: dialog)
            try writes(["POST /api/auth/login": 1])
            _ = try j.requirePair("pending", edge: edge); _ = try j.ownedEdge(edge)
            if confirm {
                try j.withdrawalIntent(edge) // Durable exact edge intent BEFORE tap.
                action.tap()
                try ready(app.buttons["match-request"], timeout: 60)
                try writes(["POST /api/auth/login": 1, withdrawal: 1])
                _ = try j.requirePair("none")
                try j.event("native-withdraw-acknowledged-both-none")
            } else {
                dismiss.tap()
                try Guard.require(dialog.waitForNonExistence(timeout: 10), "Cancel-dismiss-must-close-alert")
                try writes(["POST /api/auth/login": 1])
                _ = try j.requirePair("pending", edge: edge)
                try j.event("native-Cancel-dismiss-preserved-pending")
            }
        }
        try j.verifyHistoryAfterWithdrawal(edge)
        try inspectClientHistory(j)
        try writes(["POST /api/auth/login": 1, withdrawal: 1])
        _ = try j.requirePair("none")
        try j.verifyProvenanceUnchanged()
        try j.privateSnapshot("final-reciprocal-profiles.json", j.profiles())
        try j.event("continuation-complete-both-none-history-and-provenance", ["nativeUIloginAttempts": 2,
            "officialProofLoginAttemptsPerRole": 1, "newRequestAttempts": 0, "inheritedRequestAttempts": 1,
            "nativeWithdrawalDELETEs": 1, "cancelDialogDismissDELETEs": 0, "recipientGraphWrites": 0])
        let proof = XCTAttachment(string: "continuationOfExactSmallEdge=true;newRequestPOSTs=0;inheritedRequestPOSTs=1;recipientFullIntroAndActionOrder=true;CancelDismissDELETEs=0;nativeWithdrawDELETEs=1;bothFinalNONE=true;historyPreserved=true;finishedUnmatchHistoryCovered=false;fixtureBytesUnchanged=true;officialLoginsPerRole=1;visibleUIlogins=2;hiddenLogin=false;otherBackendWrites=0\n" + app.staticTexts["qa-request-counts"].label)
        proof.name = "native-owned-exact-small-withdraw-continuation-anonymous"; proof.lifetime = .keepAlways; add(proof)
    }


    private func text(_ key: String, _ fallback: String) -> String { labels[key] ?? fallback }
    private func wait(_ code: String, timeout: TimeInterval = 40, _ condition: @escaping () -> Bool) throws {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        try Guard.require(XCTWaiter.wait(for: [e], timeout: timeout) == .completed, code)
    }
    private func ready(_ element: XCUIElement, timeout: TimeInterval = 30) throws {
        try wait("required-native-control-not-ready", timeout: timeout) {
            element.exists && element.isEnabled && element.isHittable && self.app.frame.intersects(element.frame)
                && !self.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch.exists
        }
    }
    private func count(_ path: String) -> Int {
        let prefix = path + "="
        return app.staticTexts["qa-request-counts"].label.split(separator: "\n").first { $0.hasPrefix(prefix) }
            .flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
    }
    private func writes(_ expected: [String: Int]) throws {
        try Guard.require(app.staticTexts["qa-request-counts"].exists, "actual-app-ledger-required")
        var result: [String: Int] = [:]
        for line in app.staticTexts["qa-request-counts"].label.split(separator: "\n").map(String.init) {
            guard !line.hasPrefix("GET ") else { continue }
            guard let separator = line.lastIndex(of: "="), let value = Int(line[line.index(after: separator)...]) else {
                throw Guard.Stopped.invariant("unexpected-non-GET-ledger-entry")
            }
            result[String(line[..<separator])] = value
        }
        try Guard.require(result == expected, "unexpected-native-mutation-or-attempt-count")
    }
    private func bottom(_ title: String) throws {
        let buttons = app.buttons.matching(identifier: title)
        var stableSince: Date?
        try wait("bottom-tab-not-reachable", timeout: 40) {
            let candidates = buttons.allElementsBoundByIndex.filter {
                $0.isEnabled && $0.isHittable && self.app.frame.contains($0.frame)
                    && $0.frame.minY > self.app.frame.midY
            }
            guard candidates.count == 1 else { stableSince = nil; return false }
            if stableSince == nil { stableSince = Date() }
            return Date().timeIntervalSince(stableSince!) >= 1.5
        }
        let targets = buttons.allElementsBoundByIndex.filter {
            $0.isEnabled && $0.isHittable && self.app.frame.contains($0.frame)
                && $0.frame.minY > self.app.frame.midY
        }
        try Guard.require(targets.count == 1, "unique-ready-bottom-tab-required")
        try ready(targets[0]); targets[0].tap()
    }
    /// Decline only the positively identified task-triggered iOS password-save
    /// prompt; never save credentials or act on an unrelated system alert.
    private func settlePasswordSavePrompt(_ j: NativeOwnedGraphJournal? = nil, requireMainReady: Bool = false) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let began = Date()
        let deadline = began.addingTimeInterval(requireMainReady ? 90 : 8)
        var stableMainSince: Date?
        var declined = false
        while Date() < deadline {
            for owner in [app!, springboard] {
                let title = owner.staticTexts["Save Password?"].firstMatch
                let buttons = owner.buttons.matching(identifier: "Not Now")
                if title.exists {
                    try Guard.require(!declined && buttons.count == 1
                        && buttons.firstMatch.isEnabled && buttons.firstMatch.isHittable,
                        "unique-observed-password-save-decline-required")
                    let observed = XCTAttachment(string: owner.debugDescription)
                    observed.name = "private-actual-password-save-AX"; observed.lifetime = .keepAlways; add(observed)
                    try capture("private-actual-password-save-prompt", element: owner)
                    buttons.firstMatch.tap(); declined = true
                    try Guard.require(title.waitForNonExistence(timeout: 10), "password-save-must-dismiss")
                    try j?.event("native-password-save-declined", ["role": activeRole, "count": 1])
                } else if owner.alerts.count > 0 {
                    let unknown = XCTAttachment(string: owner.debugDescription)
                    unknown.name = "private-unknown-post-signin-alert-stop-AX"; unknown.lifetime = .keepAlways; add(unknown)
                    throw Guard.Stopped.invariant("unknown-post-signin-alert-no-action")
                }
            }
            if requireMainReady {
                let messages = app.buttons[text("bottom_navigation_messages", "Messages")].firstMatch
                let loaded = messages.exists && messages.isEnabled && messages.isHittable
                    && app.frame.contains(messages.frame)
                    && !app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch.exists
                if loaded {
                    if stableMainSince == nil { stableMainSince = Date() }
                    if Date().timeIntervalSince(stableMainSince!) >= 1.5 && Date().timeIntervalSince(began) >= 8 { return }
                } else { stableMainSince = nil }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        try Guard.require(!requireMainReady, "post-signin-Main-not-ready-after-positive-prompt-handling")
    }
    private func owner(_ role: String, _ j: NativeOwnedGraphJournal) throws {
        try bottom(text("bottom_navigation_profile", "Profile"))
        let email = j.account(role).email
        let displayed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", email, email)).firstMatch
        try Guard.require(displayed.waitForExistence(timeout: 20), "exact-native-displayed-account-required")
    }
    /// Reveal the same genuine managed Welcome button by scrolling its exact
    /// native Intro scroll view; never substitute a route push or coordinate tap.
    private func revealWelcomeSignIn() throws -> XCUIElement {
        let welcome = app.buttons[text("intro_sign_in", "Sign in")].firstMatch
        try Guard.require(welcome.waitForExistence(timeout: 120), "actual-Welcome-Sign-in-must-exist")
        let scroll = app.scrollViews["v2-16-14997"].firstMatch
        try Guard.require(scroll.exists, "actual-native-Intro-scroll-view-required")
        var swipes = 0
        for _ in 0..<8 {
            if welcome.isEnabled && welcome.isHittable && app.frame.contains(welcome.frame) { break }
            scroll.swipeUp(velocity: .slow); swipes += 1
        }
        try ready(welcome)
        try Guard.require(app.frame.contains(welcome.frame), "complete-Welcome-Sign-in-control-must-be-visible")
        try writes([:])
        let proof = XCTAttachment(string: "actualIntroScrollView=true;boundedSwipes=\(swipes);completeSignInVisible=true;enabled=true;hittable=true;nonGETs=0")
        proof.name = "native-Welcome-reveal-structural"; proof.lifetime = .keepAlways; add(proof)
        return welcome
    }
    private func signIn(_ role: String, journal j: NativeOwnedGraphJournal) throws {
        app.terminate(); activeRole = role
        app.launchArguments = ["--qa-signout", "--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launchEnvironment = [:] // No QA login credentials are injected into app.
        app.launch()
        let welcome = try revealWelcomeSignIn()
        welcome.tap()
        let email = app.textFields["Enter your email address..."]
        let password = app.secureTextFields["Enter your password..."]
        try ready(email); email.tap(); email.typeText(j.account(role).email)
        try ready(password); password.tap(); password.typeText(j.account(role).password)
        let returnKey = app.keyboards.buttons["Return"].firstMatch
        if returnKey.exists && returnKey.isHittable && app.frame.intersects(returnKey.frame) { returnKey.tap() }
        else { app.swipeDown(velocity: .slow) }
        let submit = app.buttons["Sign In"].firstMatch
        for _ in 0..<4 where !submit.isHittable { app.swipeUp(velocity: .slow) }
        try ready(submit); try writes([:])
        try j.uiLoginIntent(role); submit.tap()
        // Positive system prompt handling must run before any hittability gate.
        try settlePasswordSavePrompt(j, requireMainReady: true)
        try ready(app.buttons[text("bottom_navigation_messages", "Messages")].firstMatch, timeout: 90)
        try writes(["POST /api/auth/login": 1])
        try Guard.require(app.staticTexts["qa-token-presence"].label == "accessPresent=true;refreshPresent=true", "native-saved-owned-pair-required")
        try writes(["POST /api/auth/login": 1])
        try owner(role, j)
    }
    /// The actual tab ScrollView and measured bottom tab frame define the visible
    /// content region; no fixed screen coordinate or hidden route substitutes.
    /// Short, held normal drags use current target geometry. Unlike a flick,
    /// release has no intended inertia, and an overshot target reverses direction.
    private func revealExactTabTarget(_ query: XCUIElementQuery, tag: String) throws -> XCUIElement {
        let (scroll, viewport) = try actualTabScrollViewport()
        var lastFrame: CGRect?
        for step in 0..<8 {
            try Guard.require(query.count <= 1, "ambiguous-exact-tab-target")
            let observed = query.count == 1 ? query.firstMatch.frame : nil
            let current: CGRect? = observed.flatMap { frame in
                frame.width > 0 && frame.height > 0 && frame.minX.isFinite && frame.minY.isFinite
                    && frame.width.isFinite && frame.height.isFinite ? frame : nil
            }
            if let current { lastFrame = current }
            if query.count == 1 && query.firstMatch.isEnabled && query.firstMatch.isHittable,
               let current, viewport.contains(current) {
                let proof = XCTAttachment(string: "tag=\(tag);step=\(step);viewport=\(viewport);targetFrame=\(current);fullyContained=true")
                proof.name = "private-exact-scroll-target-visible"; proof.lifetime = .keepAlways; add(proof)
                try capture("private-\(tag)-fully-visible", element: app)
                return query.firstMatch
            }
            let frame = current ?? lastFrame
            let moveDown = frame.map { $0.minY < viewport.minY } ?? false
            let gap = frame.map { moveDown ? viewport.minY - $0.minY : $0.maxY - viewport.maxY } ?? viewport.height * 0.15
            // Target already fits but is blocked: do not scroll around an unknown
            // interruption or substitute a different action.
            if let current, viewport.contains(current) {
                try capture("private-\(tag)-blocked-stop", element: app)
                throw Guard.Stopped.invariant("fully-contained-target-not-hittable-no-alternate-action")
            }
            let distance = min(max(24, gap + 8), viewport.height * 0.20)
            let start = CGPoint(x: viewport.midX, y: viewport.midY)
            let end = CGPoint(x: start.x, y: start.y + (moveDown ? distance : -distance))
            try Guard.require(viewport.contains(start) && viewport.contains(end) && distance > 0,
                              "short-drag-must-remain-inside-observed-viewport")
            let geometry = XCTAttachment(string: "tag=\(tag);step=\(step);viewport=\(viewport);targetFrame=\(String(describing: current));lastKnownFrame=\(String(describing: lastFrame));direction=\(moveDown ? "down" : "up");distance=\(distance);start=\(start);end=\(end)")
            geometry.name = "private-directional-short-scroll-geometry"; geometry.lifetime = .keepAlways; add(geometry)
            if step == 0 { try capture("private-\(tag)-before-short-scroll", element: app) }
            let origin = scroll.coordinate(withNormalizedOffset: .zero)
            let a = origin.withOffset(CGVector(dx: start.x - scroll.frame.minX, dy: start.y - scroll.frame.minY))
            let b = origin.withOffset(CGVector(dx: end.x - scroll.frame.minX, dy: end.y - scroll.frame.minY))
            a.press(forDuration: 0.1, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        try capture("private-\(tag)-bounded-scroll-stop", element: app)
        throw Guard.Stopped.invariant("exact-target-not-fully-revealed-after-bounded-directional-drags")
    }
    private func actualTabScrollViewport() throws -> (XCUIElement, CGRect) {
        let scrolls = app.scrollViews.allElementsBoundByIndex.filter { $0.isHittable }
        let messages = app.buttons.matching(identifier: text("bottom_navigation_messages", "Messages")).allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.minY > self.app.frame.midY && self.app.frame.contains($0.frame)
        }
        try Guard.require(scrolls.count == 1 && messages.count == 1, "unique-actual-tab-scroll-and-bar-required")
        let aboveBar = CGRect(x: app.frame.minX, y: app.frame.minY, width: app.frame.width,
                              height: messages[0].frame.minY - app.frame.minY)
        let viewport = scrolls[0].frame.intersection(aboveBar)
        try Guard.require(!viewport.isNull && viewport.width > 0 && viewport.height > 0, "positive-tab-content-viewport-required")
        return (scrolls[0], viewport)
    }
    private func firstPagePeer(_ role: String, j: NativeOwnedGraphJournal) throws {
        let endpoint = role == "client" ? "clients/matches" : "caregivers/matches"
        let response = try CarezaarAPI.callWithHTTPStatus("GET", endpoint + "?page=1&perPage=10&sort=distance", token: j.account(role).token)
        try Guard.require(response.status == 200, "independent-first-page-must-load")
        guard let rows = response.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("first-page-array-required") }
        let owned = rows.filter { j.stringID(($0["user"] as? [String: Any])?["id"]) == j.peer(role).id }
        try Guard.require(owned.count == 1, "exact-peer-not-in-native-first-page-no-fabricated-card")
    }
    private func openExactPeerFromActualMatches(_ j: NativeOwnedGraphJournal) throws {
        let role = activeRole, endpoint = role == "client" ? "clients/matches" : "caregivers/matches"
        try firstPagePeer(role, j: j)
        try bottom(text("bottom_navigation_matches", "Matches"))
        let cards = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", j.peer(role).name, text("general_miles_away", "mile(s) away")))
        let totalPrefix = text(role == "client" ? "client_matches_all_matches" : "caregiver_matches_all_matches", "All Matches") + " ("
        let loadedTotal = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", totalPrefix)).firstMatch
        try wait("actual-native-matches-must-load") {
            self.count("GET /api/" + endpoint) >= 1 && loadedTotal.exists
                && !self.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch.exists
        }
        _ = try revealExactTabTarget(cards, tag: "owned-peer-card")
        try ready(cards.firstMatch)
        try Guard.require(!cards.firstMatch.descendants(matching: .any)["active-match-icon"].exists, "none-or-pending-card-must-not-show-active-badge")
        cards.firstMatch.tap()
        try wait("exact-native-peer-profile-not-loaded") { self.count("GET /api/" + j.profilePath(role)) >= 1 && self.app.staticTexts[j.peer(role).name].firstMatch.exists }
    }
    private func profileState(_ state: String, j: NativeOwnedGraphJournal) throws {
        let expected: Set<String> = state == "none" ? ["match-request"] : state == "sent" ? ["match-withdraw"] : ["match-reject", "match-accept"]
        for id in ["match-request", "match-withdraw", "match-reject", "match-accept", "match-unmatch"] {
            if expected.contains(id) { try ready(app.buttons[id]) }
            else { try Guard.require(!app.buttons[id].exists, "unexpected-native-profile-action") }
        }
        let prefix = activeRole == "client" ? "caregiver_details_message" : "client_details_message"
        try Guard.require(!app.buttons[text(prefix, "Message")].exists && !app.staticTexts.matching(NSPredicate(format: "label == %@", j.introduction)).firstMatch.exists, "pending-profile-must-hide-Message-and-top-introduction")
        if state == "received" {
            let r = app.buttons["match-reject"].frame, a = app.buttons["match-accept"].frame
            try Guard.require(abs(r.midY-a.midY) < 8 ? r.midX < a.midX : r.midY < a.midY, "Reject-must-precede-Accept")
        }
    }
    private func openRequestAndEnterIntroduction(_ j: NativeOwnedGraphJournal) throws {
        let request = app.buttons["match-request"]; try ready(request); request.tap()
        let input = app.textFields[text("match_introduction_title", "Introduction")]
        try ready(input)
        try Guard.require((input.value as? String).map { $0.isEmpty || $0 == input.placeholderValue } == true, "new-request-introduction-must-start-empty")
        input.tap(); input.typeText(j.introduction)
        try Guard.require(input.value as? String == j.introduction && j.introduction.count < 1000, "complete-synthetic-introduction-required")
        app.swipeDown(velocity: .slow)
    }
    private func dismissRequestSheet(_ j: NativeOwnedGraphJournal) throws {
        let cancel = app.buttons["match-request-dismiss"].firstMatch
        try Guard.require(cancel.label == text("general_cancel", "Cancel"), "exact-managed-Cancel-label-required")
        try ready(cancel); cancel.tap()
        try ready(app.buttons["match-request"])
    }
    private func back() throws {
        let b = app.navigationBars.firstMatch.buttons.firstMatch; try ready(b); b.tap()
    }
    private func manage(_ tab: String, j: NativeOwnedGraphJournal) throws {
        try back(); try owner(activeRole, j)
        // MenuRow combines its title and description; the bottom Matches tab
        // has no description. Retain exact managed copy and unique target.
        let candidates = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@",
            text("profile_matches_title", "Matches"), text("profile_matches_description", "Review your match history")))
        let row = try revealExactTabTarget(candidates, tag: "Profile-Manage-Matches-row")
        try ready(row); row.tap()
        let segment = app.buttons[tab].firstMatch; try ready(segment)
        let previous = count("GET /api/users/matches")
        segment.tap()
        try wait("actual-Manage-Matches-tab-load-required", timeout: 60) {
            segment.isSelected && self.count("GET /api/users/matches") > previous
                && !self.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch.exists
        }
    }
    private func inspectManageRequestsIntroduction(_ j: NativeOwnedGraphJournal, edge: Int) throws {
        try manage(text("match_tab_requests", "Requests"), j: j)
        let preview = app.buttons["match-introduction-\(edge)"]
        try ready(preview, timeout: 60)
        let firstLine = String(j.introduction.prefix { !$0.isNewline })
        try Guard.require(preview.label == text("match_introduction_title", "Introduction") + ": " + firstLine && firstLine.count > 80, "literal-complete-first-line-preview-AX-required")
        let profileReads = count("GET /api/" + j.profilePath(activeRole))
        preview.tap()
        let detail = app.descendants(matching: .any)["match-introduction-detail"].firstMatch
        try Guard.require(detail.waitForExistence(timeout: 15), "actual-introduction-modal-required")
        try Guard.require(detail.staticTexts.matching(NSPredicate(format: "label == %@", j.introduction)).firstMatch.exists && detail.staticTexts[j.peer(activeRole).name].exists, "full-introduction-and-exact-partner-name-required")
        try capture("owned-recipient-full-introduction-modal", element: detail)
        let close = detail.buttons[text("general_cancel", "Cancel")].firstMatch; try ready(close); close.tap()
        try Guard.require(detail.waitForNonExistence(timeout: 10) && count("GET /api/" + j.profilePath(activeRole)) == profileReads, "intro-dismiss-must-not-navigate-to-profile")
    }
    private func inspectClientHistory(_ j: NativeOwnedGraphJournal) throws {
        try manage(text("match_tab_history", "History"), j: j)
        try wait("created-withdrawn-history-row-missing", timeout: 60) {
            (j.cancelledEdgeRetainedInHistory ? self.app.staticTexts[j.caregiver.name].firstMatch.exists
                : self.app.staticTexts[self.text("match_tab_history", "History") + " (0)"].firstMatch.exists) && self.count("GET /api/users/matches") >= 1
                && !self.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch.exists
        }
        try Guard.require(app.textFields.count == 0 && app.textViews.count == 0
            && !app.buttons["Submit Review"].exists && !app.buttons["Submit review"].exists,
            "finished-history-must-not-expose-review-form")
        try capture("owned-client-withdrawn-history", element: app.scrollViews.firstMatch)
    }
    private func capture(_ name: String, element: XCUIElement) throws {
        try Guard.require(element.exists, "capture-target-required")
        let shot = XCTAttachment(screenshot: element.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
