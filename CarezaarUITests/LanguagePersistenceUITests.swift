import XCTest

/// P08-003 native selection plus process persistence. Runner selects the owned
/// primary role; direct launch overrides never select a language in this test.
final class LanguagePersistenceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private struct Language { let id: Int; let code: String; let name: String }
    private var languages: [Language] = []
    private var contents: [[String: Any]] = []
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app?.terminate() }

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
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", try text(key, language))).firstMatch
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.exists && row.isHittable); row.tap()
    }
    private func saveSelection(_ chosen: Language) throws {
        let option = app.buttons[chosen.name].firstMatch
        for _ in 0..<8 where !option.isHittable { app.swipeUp() }
        for _ in 0..<8 where !option.isHittable { app.swipeDown() }
        XCTAssertTrue(option.exists && option.isHittable); option.tap(); XCTAssertTrue(option.isSelected)
        let saveLabels = try languages.map { try text("settings_change_language_save", $0) }
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", saveLabels)).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in save.exists && save.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed); save.tap()
    }
    private func ordinaryRelaunch() {
        app.terminate(); app.launchEnvironment = [:]
        app.launchArguments = ["--qa-request-counts"] // Read-only observability only.
        app.launch()
    }
    private func assertSurfaces(_ language: Language, role: String) throws {
        try tapTab("bottom_navigation_matches", language)
        XCTAssertTrue((try renderedText("\(role)_matches_page_title", language)).waitForExistence(timeout: 30))
        try tapTab("bottom_navigation_messages", language)
        XCTAssertTrue((try renderedText("messages_title", language)).waitForExistence(timeout: 15))
        try tapTab("bottom_navigation_profile", language)
        XCTAssertTrue((try renderedText("profile_description", language)).waitForExistence(timeout: 15))
        try menu("profile_help_center_title", language)
        XCTAssertTrue((try renderedText("contact_support_subtitle", language)).waitForExistence(timeout: 15))
        app.navigationBars.buttons.firstMatch.tap()
        try menu("profile_faq_title", language)
        let all = app.buttons[try text("general_all", language)]
        XCTAssertTrue(all.waitForExistence(timeout: 15)); XCTAssertTrue(all.isSelected)
        app.navigationBars.buttons.firstMatch.tap()
        try menu("profile_change_language_title", language)
        XCTAssertTrue((try renderedText("settings_change_language_app_title", language)).waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons[language.name].firstMatch.isSelected, "Persisted native picker selection differs from chosen language")
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.exists)
        XCTAssertFalse(ledger.label.contains("POST /api/auth/login="), "Ordinary relaunch must use persisted session, not repeat login")
    }

    func testEnglishFrenchArabicNativeSelectionPersistsAcrossOrdinaryRelaunch() throws {
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
        let targets = try ["en", "fr", "ar"].map { code -> Language in
            guard let language = languages.first(where: { $0.code == code }) else { throw URLError(.cannotParseResponse) }
            return language
        }
        app.launchEnvironment["QA_EMAIL"] = email; app.launchEnvironment["QA_PASSWORD"] = password
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", "ChangeLanguage"]
        app.launch()
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.languages.contains { self.app.buttons[$0.name].firstMatch.exists }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 45), .completed)
        let originals = languages.filter { app.buttons[$0.name].firstMatch.isSelected }
        XCTAssertEqual(originals.count, 1, "Native initial selected language must be unambiguous")
        guard let original = originals.first else { return }
        defer {
            do {
                app.terminate(); app.launchEnvironment = [:]
                app.launchArguments = ["--qa-request-counts", "--qa-push", "ChangeLanguage"]
                app.launch()
                XCTAssertTrue(app.buttons[original.name].firstMatch.waitForExistence(timeout: 30))
                try saveSelection(original)
                ordinaryRelaunch()
                try tapTab("bottom_navigation_profile", original)
                try menu("profile_change_language_title", original)
                XCTAssertTrue(app.buttons[original.name].firstMatch.isSelected, "Original language must remain restored after ordinary relaunch")
            } catch { XCTFail("Native original-language restoration failed") }
        }
        var records = [[String: Any]]()
        for language in targets {
            try saveSelection(language)
            ordinaryRelaunch()
            try assertSurfaces(language, role: role)
            records.append(["languageCode": language.code, "nativeSelected": true,
                            "ordinaryTerminateRelaunch": true, "matchesMessagesProfileHelpFAQSettings": true,
                            "repeatedLoginPOSTs": 0])
            // assertSurfaces ends on the real language picker for the next choice.
        }
        XCTAssertEqual(records.count, 3)
        let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        evidence.name = "P08-003-three-language-native-persistence"; evidence.lifetime = .keepAlways; add(evidence)
    }
}
