import XCTest

/// Root records actual Simulator content_size before each invocation. Default
/// baseline and A5 comparison run separately on the same role/device allocation.
/// Caption queries require the labelled StaticText. SwiftUI may expose its
/// enclosing button bounds; root compares safe raster crops for glyph scaling.
final class ChromeDynamicTypeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private struct Language { let id: Int; let code: String; let name: String }
    private var languages: [Language] = []
    private var contents: [[String: Any]] = []
    private var busyLabel: String?
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    private var originalLanguage: Language?
    private var originalRestored = false
    override func tearDown() {
        if let originalLanguage, !originalRestored {
            let priorFailurePolicy = continueAfterFailure
            continueAfterFailure = true
            do { try restoreOriginal(originalLanguage) }
            catch { XCTFail("Native chrome-test original-language teardown restoration failed") }
            continueAfterFailure = priorFailurePolicy
        }
        app?.terminate()
        super.tearDown()
    }

    private func text(_ key: String, _ language: Language) throws -> String {
        guard let item = contents.first(where: { $0["slug"] as? String == key }),
              let translations = item["translations"] as? [[String: Any]],
              let value = translations.first(where: { $0["language_id"] as? Int == language.id })?["name"] as? String,
              !value.isEmpty else {
            XCTFail("Independent managed translation missing for required surface")
            throw URLError(.cannotParseResponse)
        }
        return value
    }
    private func renderedText(_ key: String, _ language: Language) throws -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", try text(key, language))).firstMatch
    }
    private func tapTab(_ key: String, _ language: Language) throws {
        let label = try text(key, language)
        let candidates = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            candidates.allElementsBoundByIndex.contains { $0.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        guard let tab = candidates.allElementsBoundByIndex.filter(\.isHittable).max(by: { $0.frame.midY < $1.frame.midY }) else {
            XCTFail("Visible native managed tab unavailable"); return
        }
        tab.tap(); XCTAssertTrue(tab.isSelected)
    }
    private func menu(_ key: String, _ language: Language) throws {
        let expected = try text(key, language)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", expected)).firstMatch
        let scrollView = try verticalScrollView()
        let tabLabels = try ["bottom_navigation_matches", "bottom_navigation_messages", "bottom_navigation_profile"]
            .map { try text($0, language) }
        func tabFrames() -> [CGRect] {
            tabLabels.compactMap { label in
                app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
                    .filter { $0.exists && $0.isHittable }.max(by: { $0.frame.midY < $1.frame.midY })?.frame
            }
        }
        func visibleTarget() -> CGRect? {
            guard row.exists, row.isHittable else { return nil }
            let tabs = tabFrames()
            guard tabs.count == 3, let footerTop = tabs.map(\.minY).min() else { return nil }
            let aboveFooter = CGRect(x: app.frame.minX, y: app.frame.minY, width: app.frame.width,
                                     height: max(0, footerTop - app.frame.minY - 2))
            let visible = row.frame.intersection(scrollView.frame.insetBy(dx: 8, dy: 8))
                .intersection(app.frame).intersection(aboveFooter)
            guard !visible.isNull, visible.width >= 44, visible.height >= 44 else { return nil }
            return visible
        }
        // Actual A5 profile rows can be several thousand points below this
        // short content viewport. Keep the reveal bounded, but allow enough
        // native content-only travel before reversing direction.
        let maximumGesturesPerDirection = 32
        var revealDirections: [[String: Any]] = []
        for direction in [true, false] {
            if visibleTarget() != nil { break }
            let beforeExists = row.exists
            let beforeFrame = beforeExists ? row.frame : CGRect.zero
            var attempts = 0
            var observedRowMovement = false
            var previousFrame: CGRect? = beforeExists ? beforeFrame : nil
            while attempts < maximumGesturesPerDirection && visibleTarget() == nil {
                scrollInside(scrollView, upward: direction)
                attempts += 1
                if row.exists {
                    let currentFrame = row.frame
                    if let previousFrame, abs(currentFrame.minY - previousFrame.minY) > 1 {
                        observedRowMovement = true
                    }
                    previousFrame = currentFrame
                }
            }
            let afterExists = row.exists
            let afterFrame = afterExists ? row.frame : CGRect.zero
            revealDirections.append([
                "direction": direction ? "upward" : "downward", "gestureCount": attempts,
                "maximumGestures": maximumGesturesPerDirection,
                "beforeExists": beforeExists, "afterExists": afterExists,
                "beforeRowFrame": frame(beforeFrame), "afterRowFrame": frame(afterFrame),
                "observedRowMovement": observedRowMovement,
                "netRowMovementY": beforeExists && afterExists ? Double(afterFrame.minY - beforeFrame.minY) : 0,
                "safeVisibleTapRegionFound": visibleTarget() != nil,
                "boundExhausted": attempts == maximumGesturesPerDirection && visibleTarget() == nil
            ])
        }
        let target = visibleTarget()
        let exists = row.exists
        let diagnostic: [String: Any] = ["languageCode": language.code, "controlIdentifier": key,
            "expectedAXLabelPrefix": expected, "observedAXLabel": exists ? row.label : "MISSING",
            "exists": exists, "isHittable": exists && row.isHittable,
            "rowFrame": frame(exists ? row.frame : .zero), "contentViewport": frame(scrollView.frame),
            "actualBottomTabFrames": tabFrames().map { frame($0) },
            "visibleTapRegion": frame(target ?? .zero), "safeVisibleTapRegionFound": target != nil,
            "boundedNativeBothDirectionReveal": true,
            "revealDirections": revealDirections]
        let data = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        evidence.name = "\(language.code)-\(key)-native-menu-before-tap"
        evidence.lifetime = .keepAlways; add(evidence)
        XCTAssertTrue(exists && row.isHittable && target != nil,
                      "Exact native menu row needs a real visible target inside content and above tabs")
        guard let target, exists, row.isHittable else { throw URLError(.cannotParseResponse) }
        XCTAssertTrue(row.label.hasPrefix(expected))
        // Derive a point from actual visible row geometry; do not demand that a
        // long A5 row fit the whole viewport or tap its footer-covered center.
        let dx = (target.midX - row.frame.minX) / row.frame.width
        let dy = (target.midY - row.frame.minY) / row.frame.height
        row.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
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
    private func saveSelection(_ chosen: Language) throws {
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
            "controlIdentifier": "language_picker_option_before_tap", "expectedOptionLabel": chosen.name,
            "observedOptionLabel": exists ? option.label : "MISSING", "exists": exists,
            "isHittable": exists && option.isHittable, "fullyVisibleAboveSave": visible,
            "optionFrame": geometry(rect), "pickerFrame": geometry(picker.frame),
            "saveFrame": geometry(save.exists ? save.frame : .zero), "expectedSaveLabels": saveLabels,
            "observedSaveLabel": save.exists ? save.label : "MISSING",
            "scopedBothDirectionsBounded": true]
        let data = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "\(chosen.code)-native-picker-before-tap-geometry"
        attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(visible, "Entire native option must be inside picker and above Save footer")
        guard visible else { throw URLError(.cannotParseResponse) }
        option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            option.exists && option.isSelected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                       "Actual language row must be selected before Save can be pressed")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in save.exists && save.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed); save.tap()
    }
    private func ordinaryRelaunch() {
        app.terminate(); app.launchEnvironment = [:]
        app.launchArguments = ["--qa-request-counts"] // Read-only observability only.
        app.launch()
    }
    private func restoreOriginal(_ original: Language) throws {
        app.terminate(); app.launchEnvironment = [:]
        app.launchArguments = ["--qa-request-counts", "--qa-push", "ChangeLanguage"]
        app.launch()
        XCTAssertTrue(app.buttons[original.name].firstMatch.waitForExistence(timeout: 30))
        try saveSelection(original)
        ordinaryRelaunch()
        try tapTab("bottom_navigation_profile", original)
        try menu("profile_change_language_title", original)
        let option = app.buttons[original.name].firstMatch
        XCTAssertTrue(option.exists && option.isSelected, "Original native language must persist after cleanup relaunch")
        originalRestored = option.exists && option.isSelected
        let result = XCTAttachment(string: originalRestored
            ? "Original native language restored and selected after ordinary relaunch."
            : "Original native language restoration remains unverified.")
        result.name = "chrome-native-language-cleanup-result"; result.lifetime = .keepAlways; add(result)
    }
    private func withOwnedPicker(_ body: (Language, String) throws -> Void) throws {
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
        languages = (languageResponse["result"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? Int, let code = $0["code"] as? String, let name = $0["name"] as? String else { return nil }
            return Language(id: id, code: code, name: name)
        }
        contents = try CarezaarAPI.call("GET", "base/contents?ts_cache=0")["result"] as? [[String: Any]] ?? []
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
        defer {
            if !originalRestored {
                do { try restoreOriginal(original) }
                catch { XCTFail("Native chrome-test original-language restoration failed") }
            }
        }
        try body(original, role)
    }

    private func phase(_ expected: String) throws -> URL {
        guard env["QA_CHROME_TEXT_SIZE_PHASE"] == expected,
              let path = env["QA_CHROME_BASELINE_FILE"], path.hasPrefix("/"),
              !path.contains("Carezaar-IOS/") else {
            throw XCTSkip("Requires root OS text-size proof and a private per-device baseline path")
        }
        return URL(fileURLWithPath: path)
    }
    private func english() throws -> Language {
        guard let english = languages.first(where: { $0.code == "en" }) else { throw URLError(.cannotParseResponse) }
        return english
    }
    private func tab(_ key: String, _ language: Language) throws -> XCUIElement {
        let label = try text(key, language)
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            buttons.allElementsBoundByIndex.contains { $0.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        guard let button = buttons.allElementsBoundByIndex.filter(\.isHittable).max(by: { $0.frame.midY < $1.frame.midY }) else {
            throw URLError(.cannotParseResponse)
        }
        return button
    }
    private func frame(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }
    private func waitForVisible(_ element: XCUIElement, name: String, heading: XCUIElement? = nil) {
        let busy = app.staticTexts.matching(NSPredicate(format: "label == %@", busyLabel ?? "Please wait...")).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && element.isHittable && !busy.exists && (heading?.exists ?? true)
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 30)
        if result != .completed {
            let exists = element.exists
            let diagnostic: [String: Any] = ["controlIdentifier": name, "exists": exists,
                "observedAXLabel": exists ? element.label : "MISSING", "isHittable": exists && element.isHittable,
                "controlFrame": frame(exists ? element.frame : .zero), "viewport": frame(app.frame),
                "managedBusyIndicatorVisible": busy.exists, "roleHeadingRequired": heading != nil,
                "requiredRoleHeadingExists": heading?.exists ?? false,
                "loadedWithoutBusy": !busy.exists]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = name + "-native-readiness-diagnostic"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        XCTAssertEqual(result, .completed, "Loaded native chrome/control must become visible and hittable without busy overlay")
    }
    private func crop(_ element: XCUIElement, _ name: String) {
        waitForVisible(element, name: name)
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func measure(_ language: Language, role: String, capture: String) throws -> [String: Any] {
        busyLabel = try text("loading_please_wait", language)
        let brand = app.staticTexts.matching(NSPredicate(format: "label == %@", "Carezaar")).firstMatch
        let roleHeading = try renderedText("\(role)_matches_page_title", language)
        waitForVisible(brand, name: "\(capture)-\(language.code)-brand-loaded", heading: roleHeading)
        XCTAssertTrue(app.frame.insetBy(dx: -0.5, dy: -0.5).contains(brand.frame), "Brand outside viewport")
        crop(brand, "\(capture)-\(language.code)-brand")
        var output: [String: Any] = ["role": role, "viewport": frame(app.frame), "brand": frame(brand.frame)]
        let headings = ["\(role)_matches_page_title", "messages_title", "profile_description"]
        for (index, key) in ["bottom_navigation_matches", "bottom_navigation_messages", "bottom_navigation_profile"].enumerated() {
            let button = try tab(key, language)
            button.tap(); XCTAssertTrue(button.isSelected)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertTrue(app.frame.insetBy(dx: -0.5, dy: -0.5).contains(button.frame), "Tab target outside viewport")
            let label = try text(key, language)
            let caption = button.descendants(matching: .staticText).matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(caption.exists, "Caption StaticText with the managed label required; bounds alone do not prove glyph size")
            XCTAssertEqual(caption.label, label)
            XCTAssertTrue(button.frame.insetBy(dx: -0.5, dy: -0.5).contains(caption.frame), "Caption outside tab bounds")
            XCTAssertTrue(app.frame.insetBy(dx: -0.5, dy: -0.5).contains(caption.frame), "Caption outside viewport")
            crop(caption, "\(capture)-\(language.code)-\(key)-caption")
            XCTAssertTrue((try renderedText(headings[index], language)).waitForExistence(timeout: 20), "Correct owned-role destination heading missing")
            output[key] = ["expectedAXLabel": label, "observedAXLabel": caption.label,
                           "captionFrame": frame(caption.frame), "targetFrame": frame(button.frame), "selected": button.isSelected]
        }
        return output
    }
    private func openLanguage(_ language: Language) throws {
        try tapTab("bottom_navigation_profile", language)
        try menu("profile_change_language_title", language)
    }
    private func assertScrolling(_ language: Language) throws {
        let heading = try renderedText("profile_description", language)
        let before = heading.frame
        scrollInside(try verticalScrollView(), upward: true)
        XCTAssertTrue(!heading.exists || heading.frame.minY < before.minY - 1,
                      "Profile content must actually scroll at A5")
        try menu("profile_help_center_title", language)
        XCTAssertTrue((try renderedText("contact_support_subtitle", language)).waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
    }

    func testRecordDefaultRenderedBrandAndTabCaptionBaseline() throws {
        let url = try phase("default")
        try withOwnedPicker { _, role in
            let en = try english(); try saveSelection(en); ordinaryRelaunch()
            let measured = try measure(en, role: role, capture: "default")
            let data = try JSONSerialization.data(withJSONObject: measured, options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
        }
    }
    func testA5RenderedBrandAndAllTabCaptionsGrowAndRemainUsable() throws {
        let url = try phase("a5")
        let baseline = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        try withOwnedPicker { _, role in
            let en = try english(); try saveSelection(en); ordinaryRelaunch()
            let actual = try measure(en, role: role, capture: "A5")
            XCTAssertEqual(baseline["role"] as? String, role)
            XCTAssertEqual(baseline["viewport"] as? [String: Double], actual["viewport"] as? [String: Double], "Baseline must be same device viewport")
            let oldBrand = baseline["brand"] as? [String: Double] ?? [:]
            let newBrand = actual["brand"] as? [String: Double] ?? [:]
            XCTAssertGreaterThan(newBrand["height"] ?? 0, (oldBrand["height"] ?? 0) + 1, "Rendered brand must grow from default to actual A5")
            for key in ["bottom_navigation_matches", "bottom_navigation_messages", "bottom_navigation_profile"] {
                let old = (baseline[key] as? [String: Any])?["captionFrame"] as? [String: Double] ?? [:]
                let new = (actual[key] as? [String: Any])?["captionFrame"] as? [String: Double] ?? [:]
                XCTAssertGreaterThan(new["height"] ?? 0, (old["height"] ?? 0) + 1, "Actual caption must grow at A5")
            }
            try assertScrolling(en)
            let data = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
            let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            evidence.name = "A5-native-chrome-geometry-and-labels"; evidence.lifetime = .keepAlways; add(evidence)
        }
    }
    func testA5FrenchAndArabicTabCaptionsRemainCompleteAndReachCorrectDestinations() throws {
        _ = try phase("a5")
        try withOwnedPicker { _, role in
            for code in ["fr", "ar"] {
                guard let language = languages.first(where: { $0.code == code }) else { throw URLError(.cannotParseResponse) }
                try saveSelection(language); ordinaryRelaunch()
                let actual = try measure(language, role: role, capture: "A5")
                try assertScrolling(language)
                let data = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
                let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                evidence.name = "A5-\(code)-native-chrome-safe-controls"; evidence.lifetime = .keepAlways; add(evidence)
                try openLanguage(language)
            }
        }
    }
}
