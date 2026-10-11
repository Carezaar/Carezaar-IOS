import XCTest

/// P17-008: every supported managed language on six native surfaces, including
/// FAQ All. No broader RTL forms/modals, VoiceOver, or matched-screen claim.
final class ManagedLanguageMatrixUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private struct Language { let id: Int; let code: String; let name: String }
    private var languages: [Language] = []
    private var contents: [[String: Any]] = []
    private var fallbackKeys: [Int: Set<String>] = [:]
    private var surfaceEvidence: [[String: Any]] = []
    private var originalLanguage: Language?
    private var originalRestored = false
    private var primaryRole: String?
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() {
        // XCTest's stop-on-failure can bypass Swift defer. Track the original
        // before changing anything and retry native cleanup in lifecycle teardown.
        if let originalLanguage, !originalRestored {
            let priorFailurePolicy = continueAfterFailure
            continueAfterFailure = true
            do { try restoreOriginal(originalLanguage) }
            catch { XCTFail("Native teardown original-language restoration failed") }
            continueAfterFailure = priorFailurePolicy
        }
        app?.terminate()
        super.tearDown()
    }

    private func text(_ key: String, _ language: Language) throws -> String {
        guard let item = contents.first(where: { $0["slug"] as? String == key }),
              let translations = item["translations"] as? [[String: Any]] else {
            XCTFail("Required managed key absent from independent reference")
            throw URLError(.cannotParseResponse)
        }
        if let selected = translations.first(where: { $0["language_id"] as? Int == language.id })?["name"] as? String {
            XCTAssertFalse(selected.isEmpty, "Present managed translation must not render an empty control")
            return selected
        }
        guard let english = translations.first(where: { $0["language_id"] as? Int == 1 })?["name"] as? String,
              !english.isEmpty else {
            XCTFail("Absent language translation has no coherent English fallback")
            throw URLError(.cannotParseResponse)
        }
        fallbackKeys[language.id, default: []].insert(key)
        return english
    }
    private func renderedText(_ key: String, _ language: Language) throws -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", try text(key, language))).firstMatch
    }
    /// Element screenshots crop only reference-managed labels/control content.
    /// Never capture the full page, partner identity, messages, or account data.
    private func captureControl(_ element: XCUIElement, identifier: String,
                                expected: String, language: Language) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && element.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed,
                       "Safe managed control must be visible for deliberate cropped evidence")
        XCTAssertEqual(element.label, expected, "Observed managed control label differs from independent reference")
        let crop = XCTAttachment(screenshot: element.screenshot())
        crop.name = "P17-008-\(language.code)-\(identifier)-control-crop"
        crop.lifetime = .keepAlways
        add(crop)
        surfaceEvidence.append(["languageCode": language.code, "controlIdentifier": identifier,
                                "expectedAXLabel": expected, "observedAXLabel": element.label,
                                "isSelected": element.isSelected, "cropContainsManagedControlOnly": true])
    }
    private func captureText(_ key: String, _ language: Language) throws {
        captureControl(try renderedText(key, language), identifier: key,
                       expected: try text(key, language), language: language)
    }
    private func rectangle(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }
    private func revealFAQAll(_ all: XCUIElement, language: Language) {
        guard all.exists, !all.isHittable else { return }
        // Observe the shallow horizontal strip at All's Y position, excluding
        // the tall outer vertical ScrollView. Never swipe the page/back edge.
        let strips = app.scrollViews.allElementsBoundByIndex.filter {
            $0.frame.height > 0 && $0.frame.height < app.frame.height * 0.3
                && $0.frame.width > app.frame.width * 0.4
                && abs($0.frame.midY - all.frame.midY) < max($0.frame.height, all.frame.height)
                && $0.isHittable
        }
        let strip = strips.min { $0.frame.height < $1.frame.height }
        if let strip {
            for direction in [true, false] {
                for _ in 0..<4 where !all.isHittable {
                    let start = strip.coordinate(withNormalizedOffset: CGVector(dx: direction ? 0.8 : 0.2, dy: 0.5))
                    let end = strip.coordinate(withNormalizedOffset: CGVector(dx: direction ? 0.2 : 0.8, dy: 0.5))
                    start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
                }
            }
        }
        if !all.isHittable {
            let diagnostic: [String: Any] = ["languageCode": language.code, "controlIdentifier": "general_all",
                "expectedAXLabel": (try? text("general_all", language)) ?? "reference_unavailable",
                "observedAXLabel": all.label, "exists": all.exists, "isSelected": all.isSelected,
                "isHittable": all.isHittable, "allFrame": rectangle(all.frame),
                "observedHorizontalStripFrames": strips.map { rectangle($0.frame) },
                "viewport": rectangle(app.frame), "bothInsetSwipeDirectionsAttempted": strip != nil]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "P17-008-\(language.code)-FAQ-All-visibility-diagnostic"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
    private func restoreOriginal(_ original: Language) throws {
        app.terminate(); app.launchEnvironment = [:]
        app.launchArguments = ["--qa-request-counts", "--qa-push", "ChangeLanguage"]
        app.launch()
        let option = app.buttons[original.name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 30))
        try saveSelection(original)
        ordinaryRelaunch()
        try tapTab("bottom_navigation_profile", original)
        try menu("profile_change_language_title", original)
        let restored = try revealLanguageRow(original, purpose: "restored_row_check").option
        XCTAssertTrue(restored.exists && restored.isSelected, "Original language must remain restored after ordinary relaunch")
        originalRestored = restored.exists && restored.isSelected
        let attachment = XCTAttachment(string: originalRestored
            ? "Original native language restored and selected after ordinary relaunch."
            : "Original native language restoration remains unverified.")
        attachment.name = "P17-008-native-language-cleanup-result"
        attachment.lifetime = .keepAlways; add(attachment)
    }
    private func tapTab(_ key: String, _ language: Language) throws {
        let label = try text(key, language)
        let candidates = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            candidates.allElementsBoundByIndex.contains { $0.isHittable }
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 30)
        if result != .completed { try readinessDiagnostic(language, phase: "missing-" + key) }
        XCTAssertEqual(result, .completed)
        guard let tab = candidates.allElementsBoundByIndex.filter(\.isHittable).max(by: { $0.frame.midY < $1.frame.midY }) else {
            XCTFail("Visible native managed tab unavailable"); return
        }
        tab.tap(); XCTAssertTrue(tab.isSelected)
    }
    private func menu(_ key: String, _ language: Language) throws {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", try text(key, language))).firstMatch
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.exists && row.isHittable); row.tap()
    }
    private func verticalScrollView() throws -> XCUIElement {
        let views = app.scrollViews.allElementsBoundByIndex.filter {
            $0.frame.width > app.frame.width * 0.5 && $0.frame.height > 60
        }
        guard let view = views.max(by: { $0.frame.height < $1.frame.height }) else {
            XCTFail("Actual native vertical ScrollView unavailable")
            throw URLError(.cannotParseResponse)
        }
        return view
    }
    private func scrollInside(_ view: XCUIElement, upward: Bool) {
        let start = view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.75 : 0.25))
        let end = view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.25 : 0.75))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    private func revealLanguageRow(_ chosen: Language, purpose: String) throws -> (option: XCUIElement, save: XCUIElement) {
        let option = app.buttons.matching(NSPredicate(format: "label == %@", chosen.name)).firstMatch
        // Union locates the current action; exact current-language Save copy
        // remains outside this test's claims.
        let saveLabels = try languages.map { try text("settings_change_language_save", $0) }
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", saveLabels)).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 30), "Native Save footer required before selecting language")
        let picker = try verticalScrollView()
        func fullyVisible() -> Bool {
            guard option.exists, option.isHittable, save.exists else { return false }
            return picker.frame.insetBy(dx: -0.5, dy: -0.5).contains(option.frame)
                && option.frame.maxY < save.frame.minY - 1
                && app.frame.insetBy(dx: -0.5, dy: -0.5).contains(option.frame)
        }
        for direction in [true, false] {
            for _ in 0..<8 where !fullyVisible() { scrollInside(picker, upward: direction) }
        }
        let visible = fullyVisible()
        let exists = option.exists
        let rect = exists ? option.frame : CGRect.zero
        func geometry(_ value: CGRect) -> [String: Double] {
            ["x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width), "height": Double(value.height)]
        }
        let diagnostic: [String: Any] = ["languageCode": chosen.code,
            "controlIdentifier": "language_picker_full_row", "purpose": purpose, "expectedOptionLabel": chosen.name,
            "observedOptionLabel": exists ? option.label : "MISSING", "exists": exists,
            "isHittable": exists && option.isHittable, "fullyVisibleAboveSave": visible,
            "optionFrame": geometry(rect), "pickerFrame": geometry(picker.frame),
            "saveFrame": geometry(save.exists ? save.frame : .zero), "expectedSaveLabels": saveLabels,
            "observedSaveLabel": save.exists ? save.label : "MISSING",
            "scopedBothDirectionsBounded": true]
        let data = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "\(chosen.code)-native-picker-\(purpose)-geometry"
        attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(visible, "Entire native option must be inside picker and above Save footer")
        guard visible else { throw URLError(.cannotParseResponse) }
        return (option, save)
    }
    private func saveSelection(_ chosen: Language) throws {
        let (option, save) = try revealLanguageRow(chosen, purpose: "before_selection_tap")
        option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            option.exists && option.isSelected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                       "Actual language row must be selected before Save can be pressed")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in save.exists && save.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed); save.tap()
        try waitForSavedMain(chosen, option: option, save: save)
    }
    private let mainTabKeys = ["bottom_navigation_matches", "bottom_navigation_messages", "bottom_navigation_profile"]
    private func bottomTab(_ label: String) -> XCUIElement? {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable }.max(by: { $0.frame.midY < $1.frame.midY })
    }
    private func readinessDiagnostic(_ chosen: Language, phase: String) throws {
        var observations = [[String: Any]]()
        for language in languages {
            for key in mainTabKeys {
                let label = try text(key, language)
                let elements = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
                    .filter { $0.exists }
                let bottom = elements.max(by: { $0.frame.midY < $1.frame.midY })
                observations.append(["languageCode": language.code, "controlIdentifier": key,
                    "expectedAXLabel": label, "presentCount": elements.count,
                    "bottommostIsHittable": bottom?.isHittable ?? false,
                    "bottommostFrame": rectangle(bottom?.frame ?? .zero)])
            }
        }
        let busyLabels = try languages.map { try text("loading_please_wait", $0) }
        let busy = app.staticTexts.matching(NSPredicate(format: "label IN %@", busyLabels)).firstMatch
        let pickerLabels = try languages.map { try text("settings_change_language_app_title", $0) }
        let picker = app.staticTexts.matching(NSPredicate(format: "label IN %@", pickerLabels)).firstMatch
        let record: [String: Any] = ["languageCode": chosen.code, "phase": phase,
            "expectedManagedTabsBySupportedLanguage": observations,
            "managedBusyIndicatorExists": busy.exists, "managedLanguagePickerHeadingExists": picker.exists,
            "brandExists": app.staticTexts["Carezaar"].exists, "viewport": rectangle(app.frame),
            "containsNoAccountText": true]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "P17-008-\(chosen.code)-\(phase)-native-readiness"
        attachment.lifetime = .keepAlways; add(attachment)
    }
    private func waitForSavedMain(_ chosen: Language, option: XCUIElement, save: XCUIElement) throws {
        let labels = try mainTabKeys.map { try text($0, chosen) }
        let busyLabels = try languages.map { try text("loading_please_wait", $0) }
        let busy = app.staticTexts.matching(NSPredicate(format: "label IN %@", busyLabels)).firstMatch
        let departed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !option.exists && !save.exists && !busy.exists && labels.allSatisfy { self.bottomTab($0) != nil }
        }, object: nil)
        let departureResult = XCTWaiter.wait(for: [departed], timeout: 30)
        try readinessDiagnostic(chosen, phase: "post-save-before-terminate")
        XCTAssertEqual(departureResult, .completed,
                       "Observe picker departure and all three chosen-language native tabs before termination")
        guard departureResult == .completed,
              let matches = bottomTab(labels[0]), let role = primaryRole else {
            throw URLError(.cannotParseResponse)
        }
        matches.tap()
        let heading = try renderedText("\(role)_matches_page_title", chosen)
        let mainReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            heading.exists && matches.exists && matches.isSelected && !busy.exists
                && labels.allSatisfy { self.bottomTab($0) != nil }
        }, object: nil)
        let mainResult = XCTWaiter.wait(for: [mainReady], timeout: 30)
        if mainResult != .completed { try readinessDiagnostic(chosen, phase: "post-save-owned-main-heading-missing") }
        XCTAssertEqual(mainResult, .completed, "Chosen-language owned-role Matches must render before ordinary relaunch")
        guard mainResult == .completed else { throw URLError(.cannotParseResponse) }
    }
    private func ordinaryRelaunch() {
        app.terminate(); app.launchEnvironment = [:]
        app.launchArguments = ["--qa-request-counts"] // Read-only observability only.
        app.launch()
    }
    private func assertSurfaces(_ language: Language, role: String) throws {
        try tapTab("bottom_navigation_matches", language)
        XCTAssertTrue((try renderedText("\(role)_matches_page_title", language)).waitForExistence(timeout: 30))
        try captureText("\(role)_matches_page_title", language)
        try tapTab("bottom_navigation_messages", language)
        XCTAssertTrue((try renderedText("messages_title", language)).waitForExistence(timeout: 15))
        try captureText("messages_title", language)
        try tapTab("bottom_navigation_profile", language)
        XCTAssertTrue((try renderedText("profile_description", language)).waitForExistence(timeout: 15))
        try captureText("profile_description", language)
        try menu("profile_help_center_title", language)
        XCTAssertTrue((try renderedText("contact_support_subtitle", language)).waitForExistence(timeout: 15))
        try captureText("contact_support_subtitle", language)
        app.navigationBars.buttons.firstMatch.tap()
        try menu("profile_faq_title", language)
        let all = app.buttons[try text("general_all", language)]
        XCTAssertTrue(all.waitForExistence(timeout: 15)); XCTAssertTrue(all.isSelected)
        revealFAQAll(all, language: language)
        captureControl(all, identifier: "general_all", expected: try text("general_all", language), language: language)
        app.navigationBars.buttons.firstMatch.tap()
        try menu("profile_change_language_title", language)
        XCTAssertTrue((try renderedText("settings_change_language_app_title", language)).waitForExistence(timeout: 15))
        try captureText("settings_change_language_app_title", language)
        // Reveal the full selected row without tapping it or Save. Cropping an
        // offscreen/partially footer-covered row would not prove readable content.
        let selectedLanguage = try revealLanguageRow(language, purpose: "selected_row_crop").option
        XCTAssertTrue(selectedLanguage.exists && selectedLanguage.isSelected, "Persisted native picker selection differs from chosen language")
        captureControl(selectedLanguage, identifier: "selected_language_option", expected: language.name, language: language)
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.exists)
        XCTAssertFalse(ledger.label.contains("POST /api/auth/login="), "Ordinary relaunch must use persisted session, not repeat login")
    }

    func testEverySupportedManagedLanguageRendersNativeSurfacesAndFAQAll() throws {
        guard let email = env["QA_EMAIL"], let password = env["QA_PASSWORD"],
              let clientID = env["QA_CLIENT_USER_ID"], let caregiverID = env["QA_CG_ID"] else {
            throw XCTSkip("Owned pair runner identity and credentials missing")
        }
        let token = try CarezaarAPI.login(email, password)
        let me = try CarezaarAPI.me(token)
        let id = me["id"].map { String(describing: $0) } ?? ""
        guard let role = me["role"] as? String,
              (role == "client" && id == clientID) || (role == "caregiver" && id == caregiverID) else {
            XCTFail("Primary identity/role must match retained owned fixture")
            throw URLError(.userAuthenticationRequired)
        }
        let languageResponse = try CarezaarAPI.call("GET", "base/languages?ts_cache=0")
        let managedLanguages = languageResponse["result"] as? [[String: Any]] ?? []
        XCTAssertFalse(managedLanguages.isEmpty, "Supported managed language reference required")
        languages = managedLanguages.compactMap {
            guard let id = $0["id"] as? Int, let code = $0["code"] as? String, let name = $0["name"] as? String else { return nil }
            return Language(id: id, code: code, name: name)
        }
        contents = try CarezaarAPI.call("GET", "base/contents?ts_cache=0")["result"] as? [[String: Any]] ?? []
        XCTAssertEqual(languages.count, managedLanguages.count, "Do not silently omit malformed supported language records")
        XCTAssertEqual(Set(languages.map(\.id)).count, languages.count, "Supported language IDs must be unique")
        XCTAssertEqual(Set(languages.map(\.code)).count, languages.count, "Supported language codes must be unique")
        XCTAssertTrue(languages.allSatisfy { !$0.name.isEmpty && !$0.code.isEmpty })
        // Exercise the furthest native picker rows first, while retaining every
        // unique public language exactly once in this complete matrix.
        let boundaryCount = min(2, languages.count)
        let targets = Array(languages.suffix(boundaryCount)) + Array(languages.dropLast(boundaryCount))
        app.launchEnvironment["QA_EMAIL"] = email; app.launchEnvironment["QA_PASSWORD"] = password
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", "ChangeLanguage"]
        app.launch()
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.languages.contains { self.app.buttons[$0.name].firstMatch.exists }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 45), .completed)
        let originals = languages.filter {
            let option = app.buttons[$0.name].firstMatch
            return option.exists && option.isSelected
        }
        XCTAssertEqual(originals.count, 1, "Native initial selected language must be unambiguous")
        guard let original = originals.first else { return }
        originalLanguage = original
        primaryRole = role
        let saveLabels = try languages.map { try text("settings_change_language_save", $0) }
        let initialSave = app.buttons.matching(NSPredicate(format: "label IN %@", saveLabels)).firstMatch
        let initialRecord: [String: Any] = ["initialSelectedLanguageCode": original.code,
            "expectedCurrentLanguageSaveAXLabel": try text("settings_change_language_save", original),
            "observedUnionSaveAXLabel": initialSave.exists ? initialSave.label : "MISSING",
            "unionSaveExists": initialSave.exists,
            "unionSaveIsHittable": initialSave.exists && initialSave.isHittable,
            "unionSaveFrame": rectangle(initialSave.exists ? initialSave.frame : .zero)]
        let initialData = try JSONSerialization.data(withJSONObject: initialRecord, options: [.sortedKeys])
        let initialAttachment = XCTAttachment(data: initialData, uniformTypeIdentifier: "public.json")
        initialAttachment.name = "P17-008-initial-selection-and-observed-save"
        initialAttachment.lifetime = .keepAlways; add(initialAttachment)
        defer {
            if !originalRestored {
                do { try restoreOriginal(original) }
                catch { XCTFail("Native original-language restoration failed") }
            }
        }
        var records = [[String: Any]]()
        for language in targets {
            surfaceEvidence = []
            try saveSelection(language)
            ordinaryRelaunch()
            try assertSurfaces(language, role: role)
            records.append(["languageCode": language.code, "nativeSelected": true,
                            "ordinaryTerminateRelaunch": true, "matchesMessagesProfileHelpFAQSettings": true,
                            "repeatedLoginPOSTs": 0,
                            "englishFallbackKeys": Array(fallbackKeys[language.id] ?? []).sorted(),
                            "surfaceControls": surfaceEvidence,
                            "exactCurrentLanguageSaveCopy": "not_verified_union_action_query"])
            XCTAssertEqual(surfaceEvidence.count, 7, "Every language needs deliberate six-surface plus selected-option evidence")
            // assertSurfaces ends on the real language picker for the next choice.
        }
        XCTAssertEqual(records.count, managedLanguages.count, "Every supported language must produce actual native surface evidence")
        let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        evidence.name = "P17-008-all-supported-managed-language-native-surfaces"; evidence.lifetime = .keepAlways; add(evidence)
    }
}
