import XCTest

/// A screen-by-screen walk through one role's app, on that role's own simulator, saving a
/// screenshot at every step (`QA_SHOT_DIR`) for visual review. Account from `QA_EMAIL` /
/// `QA_PASSWORD`; `QA_PREFIX` names the screenshots (e.g. "cg" or "cl").
final class RoleWalkthroughTests: XCTestCase {
    var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var prefix: String { env["QA_PREFIX"] ?? "role" }

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private func shot(_ name: String) {
        guard let dir = env["QA_SHOT_DIR"] else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(prefix)-\(name).png"))
    }

    private func launch(_ extra: [String] = [], ready: XCUIElement? = nil) {
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"] ?? ""
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"] ?? ""
        app.launchArguments = ["--qa-signout", "--qa-login-env"] + extra
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 8) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue((ready ?? app.buttons["Messages"]).waitForExistence(timeout: 40), "Requested screen did not load")
        settle()
    }

    /// Waits for the "Please wait…" card to clear.
    private func settle(_ extra: UInt32 = 1) {
        let busy = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch
        _ = busy.waitForNonExistence(timeout: 30)
        sleep(extra)
    }

    private func tapTab(_ label: String) {
        let tab = app.buttons.matching(identifier: label).allElementsBoundByIndex.filter(\.isHittable).max { $0.frame.minY < $1.frame.minY }
        guard let tab else { XCTFail("Visible tab missing: \(label)"); return }
        tab.tap()
        XCTAssertTrue(tab.waitForSelected(timeout: 10), "Tab did not become selected: \(label)")
        settle()
    }

    /// Managed labels observed in the current server content for supported languages.
    private func saveButton() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Save Changes", "Enregistrer les modifications", "حفظ التغييرات"])).firstMatch
    }

    func test0_CreateAccountFormWithoutSubmission() {
        app.launchArguments = ["--qa-signout", "--qa-push", "SignUpCredentials/client"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 5) { springboard.buttons["Allow"].tap() }
        let email = app.textFields["Enter your email address..."]
        XCTAssertTrue(email.waitForExistence(timeout: 60))
        email.tap(); email.typeText("someone@example.com")
        // iOS's own password AutoFill sheet can open on the first tap; close it first.
        func typeSecure(_ field: XCUIElement, _ text: String) {
            field.tap()
            if app.buttons["Close"].waitForExistence(timeout: 2) { app.buttons["Close"].tap(); field.tap() }
            field.typeText(text)
        }
        typeSecure(app.secureTextFields["Enter your password..."], "Example1!")
        typeSecure(app.secureTextFields["Confirm Password"], "Example1!")
        app.swipeDown(); sleep(1)
        shot("50-create-account-filled")
        let continueButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Continue")).firstMatch
        XCTAssertTrue(continueButton.exists, "Create account continuation control missing")
        XCTAssertEqual(email.value as? String, "someone@example.com", "Entered email was not preserved")
        // Form rendering only: never accept terms or submit an account using this
        // non-owned example address. Signup integration is a separate owned-fixture test.
        XCTAssertFalse(app.alerts.firstMatch.exists, "A signup action was triggered while only filling the form")
    }

    func test1_MainTabsSortAndDetail() {
        launch()
        shot("01-matches")
        let sort = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sort")).firstMatch
        if sort.waitForExistence(timeout: 10) { sort.tap(); sleep(1); shot("02-sort-sheet")
            let pay = app.buttons["Pay Rate"].firstMatch
            if pay.exists { pay.tap(); settle(2) } else { app.swipeDown() }
            shot("03-sorted-pay")
        }
        app.swipeUp(); app.swipeUp(); settle(); shot("04-matches-scrolled")
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        let card = app.buttons.matching(NSPredicate(format: "identifier == %@", "MatchCard")).firstMatch
        let firstCard = card.exists ? card : app.scrollViews.buttons.element(boundBy: 2)
        if firstCard.waitForExistence(timeout: 5) { firstCard.tap(); settle(2); shot("05-detail-top"); app.swipeUp(); sleep(1); shot("06-detail-lower")
            let request = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Request a Match")).firstMatch
            if request.exists { request.tap(); settle(2); shot("07-request-gate") }
        }
        launch(); tapTab("Messages"); shot("08-messages")
        tapTab("Profile"); shot("09-profile"); app.swipeUp(); sleep(1); shot("10-profile-lower")
    }

    func test2_Lists() {
        launch(["--qa-push", "Notifications"], ready: app.buttons["BackButton"]); shot("11-notifications")
        launch(["--qa-push", "Favorites"], ready: app.buttons["BackButton"]); shot("12-favorites")
        launch(["--qa-push", "ManageMatches"], ready: app.buttons["BackButton"]); shot("13-manage-matches")
        for tab in ["Requests", "History"] { app.buttons[tab].firstMatch.tap(); settle(2); shot("14-manage-\(tab.lowercased())") }
        launch(["--qa-push", "HelpCenter"], ready: app.buttons["BackButton"]); shot("15-help")
        launch(["--qa-push", "FAQ"], ready: app.buttons["BackButton"]); shot("16-faq")
    }

    func test3_FormsAndValidation() {
        launch(["--qa-push", "ReportAnIssue"], ready: app.buttons["BackButton"]); shot("17-report-list")
        let add = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Add", "Report")).allElementsBoundByIndex.last
        add?.tap(); sleep(1); shot("18-report-form")
        let submit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Submit")).firstMatch
        if submit.exists { submit.tap(); sleep(1); shot("19-report-empty-submit") }
        launch(["--qa-push", "ChangePassword"], ready: app.buttons["BackButton"])
        let fields = app.secureTextFields.allElementsBoundByIndex
        if fields.count >= 3 {
            fields[0].tap(); fields[0].typeText("Example1!")
            fields[1].tap(); fields[1].typeText("Newpass1!")
            // The keyboard can cover the last field on smaller phones; scroll to it first.
            if !fields[2].isHittable { app.swipeUp() }
            fields[2].tap(); fields[2].typeText("Different1!")
        }
        shot("20-change-password-mismatch")
        launch(["--qa-push", "DeleteAccount"], ready: app.buttons["BackButton"]); shot("21-delete-account"); app.swipeUp(); sleep(1); shot("22-delete-account-lower")
        launch(["--qa-push", "ProfileEdit"], ready: app.buttons["BackButton"]); shot("23-profile-edit")
        launch(["--qa-push", "HelpCenter"], ready: app.buttons["BackButton"]); shot("24-help-center")
    }

    func test4_FrenchAndArabic() {
        defer {
            launch(["--qa-push", "ChangeLanguage"], ready: app.buttons["BackButton"])
            let english = app.buttons["English"].firstMatch
            XCTAssertTrue(english.waitForExistence(timeout: 10), "English option missing during restoration")
            if english.exists {
                english.tap()
                let save = saveButton()
                XCTAssertTrue(save.exists, "Managed Save Changes control missing during restoration")
                if save.exists { save.tap() }
                settle(3)
            }
            XCTAssertTrue(app.buttons["Profile"].waitForExistence(timeout: 10), "English UI was not restored")
            shot("34-back-to-english")
        }
        for (lang, tag, matches, messages, profile, heading, notifications, deleteTitle) in [
            ("Français", "fr", "Correspondances", "Messages", "Profil", "Mes correspondances", "Notifications", "Supprimer le compte"),
            ("عربي", "ar", "المطابقات", "الرسائل", "الملف الشخصي", "مطابقاتي", "الإشعارات", "حذف الحساب")
        ] {
            launch(["--qa-push", "ChangeLanguage"], ready: app.buttons["BackButton"])
            let option = app.buttons[lang].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 10), "Language option missing: \(tag)")
            option.tap()
            let save = saveButton()
            XCTAssertTrue(save.exists && save.isHittable, "Managed Save Changes control unavailable")
            save.tap()
            settle(3)
            XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 15), "Translated matches screen did not render: \(tag)")
            let matchTab = app.buttons.matching(identifier: matches).allElementsBoundByIndex.filter(\.isHittable).max { $0.frame.minY < $1.frame.minY }
            let messageTab = app.buttons.matching(identifier: messages).allElementsBoundByIndex.filter(\.isHittable).max { $0.frame.minY < $1.frame.minY }
            let profileTab = app.buttons.matching(identifier: profile).allElementsBoundByIndex.filter(\.isHittable).max { $0.frame.minY < $1.frame.minY }
            XCTAssertNotNil(matchTab, "Translated Matches tab missing")
            XCTAssertNotNil(messageTab, "Translated Messages tab missing")
            XCTAssertNotNil(profileTab, "Translated Profile tab missing")
            if let matchTab, let messageTab, let profileTab {
                if tag == "ar" {
                    XCTAssertGreaterThan(matchTab.frame.midX, messageTab.frame.midX, "Arabic tab order must use RTL")
                    XCTAssertGreaterThan(messageTab.frame.midX, profileTab.frame.midX, "Arabic Profile tab must be leftmost")
                } else {
                    XCTAssertLessThan(matchTab.frame.midX, messageTab.frame.midX, "French tab order must use LTR")
                }
            }
            shot("30-\(tag)-matches")
            tapTab(messages)
            XCTAssertTrue(app.staticTexts[messages].exists, "Translated Messages heading missing")
            shot("31-\(tag)-messages")
            tapTab(profile)
            XCTAssertTrue(app.staticTexts[profile].exists, "Translated Profile heading missing")
            shot("31-\(tag)-profile")
            launch(["--qa-push", "Notifications"], ready: app.buttons["BackButton"])
            XCTAssertTrue(app.navigationBars[notifications].exists, "Translated Notifications screen missing")
            shot("32-\(tag)-notifications")
            launch(["--qa-push", "DeleteAccount"], ready: app.buttons["BackButton"])
            XCTAssertTrue(app.navigationBars[deleteTitle].exists, "Translated Delete Account screen missing")
            shot("33-\(tag)-delete")
        }
    }
}
