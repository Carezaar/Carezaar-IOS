import XCTest
import UIKit

/// Native read-only boundaries shared by both roles. The runner selects the role
/// through QA_EMAIL/QA_PASSWORD. No issue submission, account deletion or mail send.
final class HelpSettingsBoundaryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app?.terminate() }

    private func launch(_ route: String) throws {
        guard let email = env["QA_EMAIL"], !email.isEmpty,
              let password = env["QA_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Owned primary role credentials missing")
        }
        app.launchEnvironment["QA_EMAIL"] = email
        app.launchEnvironment["QA_PASSWORD"] = password
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", route,
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
    }

    private func count(_ key: String) -> Int {
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 5), "Actual native transport summary required")
        let prefix = key + "="
        let line = ledger.label.split(separator: "\n").first { $0.hasPrefix(prefix) }
        return line.flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
    }

    private func evidence(_ name: String, _ record: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.exists && element.isHittable, "Required native control unreachable")
    }

    private func dismissKeyboard() {
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["OK", "Done"])).firstMatch
        if done.exists && done.isHittable { done.tap() }
        else if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
    }

    /// A long category can be wider than the SE viewport, making its AX center
    /// unhittable even while part of the genuine button is visible. Use observed
    /// viewport geometry; selection and reference membership remain mandatory.
    private func selectCategory(_ chip: XCUIElement, in strip: XCUIElement) {
        XCTAssertTrue(strip.exists && chip.exists, "Native category strip/button missing")
        for _ in 0..<24 {
            let viewport = strip.frame.intersection(app.frame).insetBy(dx: 8, dy: 2)
            let visible = chip.frame.intersection(viewport)
            if !visible.isNull && visible.width >= 24 && visible.height >= 16 {
                let point = strip.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                    .withOffset(CGVector(dx: visible.midX - strip.frame.minX,
                                         dy: visible.midY - strip.frame.minY))
                point.tap()
                let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in chip.isSelected }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                               "Tapping the visible exact category must select it")
                return
            }
            // Short drags avoid sweeping past a partially visible long chip.
            let moveLeft = chip.frame.midX > viewport.midX
            strip.coordinate(withNormalizedOffset: CGVector(dx: moveLeft ? 0.75 : 0.25, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: strip.coordinate(withNormalizedOffset:
                    CGVector(dx: moveLeft ? 0.35 : 0.65, dy: 0.5)))
        }
        XCTFail("Exact category never exposed a usable visible button region")
    }

    func testPasswordConfirmationShowsManagedMessageAndCancelDoesNotWrite() throws {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0")
        XCTAssertEqual(response.status, 200)
        let contents = try XCTUnwrap(response.body["result"] as? [[String: Any]])
        func text(_ slug: String) throws -> String {
            let row = try XCTUnwrap(contents.first { $0["slug"] as? String == slug })
            return try XCTUnwrap((row["translations"] as? [[String: Any]])?.first {
                ($0["language_id"] as? NSNumber)?.intValue == 1
            }?["name"] as? String)
        }
        try launch("ChangePassword")
        let fields = app.secureTextFields
        XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 45))
        XCTAssertEqual(fields.count, 3)
        for (index, value) in ["Synthetic-old-password1!", "Synthetic-new-password1!", "Synthetic-new-password1!"].enumerated() {
            let field = fields.element(boundBy: index)
            scrollTo(field); field.tap(); field.typeText(value)
            dismissKeyboard()
        }
        let change = app.buttons[try text("settings_change_password_change_password")]
        scrollTo(change); XCTAssertTrue(change.isEnabled); change.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let title = alert.staticTexts[try text("settings_change_password_dialog_title")]
        let message = alert.staticTexts[try text("settings_change_password_dialog_message")]
        let confirm = alert.buttons[try text("settings_change_password_dialog_confirm")]
        XCTAssertTrue(title.exists && message.exists && confirm.exists)
        XCTAssertGreaterThan(message.frame.midY, title.frame.midY)
        XCTAssertLessThan(message.frame.midY, confirm.frame.midY)
        let proof = XCTAttachment(screenshot: alert.screenshot())
        proof.name = "R5-managed-password-confirmation-only"; proof.lifetime = .keepAlways; add(proof)
        alert.buttons[try text("settings_change_password_dialog_deny")].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertEqual(count("PATCH /api/users/password/change"), 0)
        XCTAssertEqual(count("POST /api/users/password/change"), 0)
        try evidence("R5-password-confirmation-cancel", ["managedMessagePresent": true,
            "messageBetweenTitleAndButtons": true, "passwordMutationRequests": 0])
    }

    /// P15-004 expansion/collapse portion; P04-024 Back. Complements the older
    /// expansion-only test with collapse semantics and actual no-refetch evidence.
    func testFAQAnswerCollapsesAndBackReturnsWithoutRefetch() throws {
        try launch("FAQ")
        let question = app.buttons["What is Carezaar?"]
        XCTAssertTrue(question.waitForExistence(timeout: 45))
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", try CarezaarAPI.faqAnswerOpening(question: "What is Carezaar?"))).firstMatch
        XCTAssertFalse(question.isSelected); XCTAssertFalse(answer.exists)
        let baseline = count("GET /api/base/faqs")
        question.tap()
        XCTAssertTrue(answer.waitForExistence(timeout: 5)); XCTAssertTrue(question.isSelected)
        question.tap()
        XCTAssertFalse(answer.exists); XCTAssertFalse(question.isSelected)
        question.tap()
        XCTAssertTrue(answer.waitForExistence(timeout: 5)); XCTAssertTrue(question.isSelected)
        XCTAssertEqual(count("GET /api/base/faqs"), baseline, "Expansion must use startup FAQ cache")
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["Messages"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(question.exists)
        try evidence("P15-004-P04-024-collapse-boundary", ["expandedCollapsedReexpanded": true,
                     "selectionSemantics": true, "extraFAQGETs": count("GET /api/base/faqs") - baseline,
                     "backReturnedToMain": true])
    }

    /// P15-003 category traversal uses public reference reads for independent
    /// expected membership. Those reads occur in the test runner, outside the
    /// app transport ledger; they never mutate backend reference data.
    func testFAQCategoriesFilterAndAllRestoresWithoutAdditionalDownloads() throws {
        let categoryResponse = try CarezaarAPI.call("GET", "base/faq_categories?ts_cache=0")
        let faqResponse = try CarezaarAPI.call("GET", "base/faqs?ts_cache=0")
        let categories = categoryResponse["result"] as? [[String: Any]] ?? []
        let faqs = faqResponse["result"] as? [[String: Any]] ?? []
        XCTAssertFalse(categories.isEmpty, "Public managed category reference required")
        XCTAssertFalse(faqs.isEmpty, "Public FAQ reference required")
        func english(_ object: [String: Any], key: String) -> String? {
            let translations = object["translations"] as? [[String: Any]] ?? []
            return translations.first { ($0["language_id"] as? Int) == 1 }?[key] as? String
        }
        try launch("FAQ")
        let all = app.buttons["All"]
        XCTAssertTrue(all.waitForExistence(timeout: 45)); XCTAssertTrue(all.isSelected)
        let faqBaseline = count("GET /api/base/faqs")
        let categoryBaseline = count("GET /api/base/faq_categories")
        var checked = 0
        for category in categories {
            guard let id = category["id"] as? Int, let title = english(category, key: "title"), !title.isEmpty else {
                XCTFail("Reference category lacks English identity/title"); return
            }
            let chip = app.buttons[title]
            // Actual nested horizontal ScrollView contains the category chips.
            // Its index follows FAQ's outer vertical then inner horizontal view.
            let strip = app.scrollViews.element(boundBy: 1)
            XCTAssertTrue(strip.exists, "Native category strip missing")
            selectCategory(chip, in: strip)
            XCTAssertTrue(chip.isSelected); XCTAssertFalse(all.isSelected)
            for faq in faqs {
                guard let question = english(faq, key: "question"), !question.isEmpty else { continue }
                let expected = (faq["faq_category_id"] as? Int) == id
                XCTAssertEqual(app.buttons[question].exists, expected,
                               "Rendered FAQ membership differs from public category reference")
            }
            checked += 1
        }
        let strip = app.scrollViews.element(boundBy: 1)
        selectCategory(all, in: strip); XCTAssertTrue(all.isSelected)
        for faq in faqs {
            if let question = english(faq, key: "question"), !question.isEmpty {
                XCTAssertTrue(app.buttons[question].exists, "All must restore each managed FAQ question")
            }
        }
        XCTAssertEqual(count("GET /api/base/faqs"), faqBaseline)
        XCTAssertEqual(count("GET /api/base/faq_categories"), categoryBaseline)
        try evidence("P15-003-category-boundary", ["categoriesChecked": checked, "allSelectedAfterReset": all.isSelected,
                     "extraFAQGETs": count("GET /api/base/faqs") - faqBaseline,
                     "extraCategoryGETs": count("GET /api/base/faq_categories") - categoryBaseline])
    }

    /// P04-024 needs every actual FAQ action, beyond the existing one-answer
    /// boundary. Independent public HTML decoding verifies complete answer text.
    func testEveryManagedFAQAnswerExpandsCollapsesAndBackReturnsWithoutRefetch() throws {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "base/faqs?ts_cache=0")
        XCTAssertEqual(response.status, 200)
        let rows = try XCTUnwrap(response.body["result"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 14, "The reviewed live FAQ inventory changed; reconcile every identity before acceptance")
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "•", with: " ")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let references = try rows.map { row -> (id: Int, question: String, answer: String) in
            let id = try XCTUnwrap((row["id"] as? NSNumber)?.intValue)
            let translation = try XCTUnwrap((row["translations"] as? [[String: Any]])?.first {
                ($0["language_id"] as? NSNumber)?.intValue == 1
            })
            let question = try XCTUnwrap(translation["question"] as? String)
            let html = try XCTUnwrap(translation["answer"] as? String)
            let decoded = try NSAttributedString(data: Data(html.utf8), options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ], documentAttributes: nil).string
            XCTAssertFalse(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(normalized(decoded).isEmpty)
            return (id, question, normalized(decoded))
        }
        XCTAssertEqual(Set(references.map(\.id)).count, 14)
        XCTAssertEqual(Set(references.map(\.question)).count, 14, "Every managed question needs a distinct native target")
        try launch("FAQ")
        XCTAssertTrue(app.buttons["All"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.buttons["All"].isSelected)
        let faqBaseline = count("GET /api/base/faqs")
        let categoryBaseline = count("GET /api/base/faq_categories")
        func answer(_ reference: (id: Int, question: String, answer: String)) -> XCUIElement? {
            app.staticTexts.allElementsBoundByIndex.first { normalized($0.label) == reference.answer }
        }
        func revealQuestion(_ question: XCUIElement) {
            for _ in 0..<24 {
                let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 4 : app.frame.minY + 80
                let viewport = CGRect(x: app.frame.minX + 8, y: top,
                    width: app.frame.width - 16, height: app.frame.maxY - top - 24)
                let visible = question.frame.intersection(viewport)
                if question.exists && question.isHittable && !visible.isNull
                    && visible.height >= min(44, question.frame.height) { return }
                if question.frame.midY < viewport.midY { app.swipeDown(velocity: .slow) }
                else { app.swipeUp(velocity: .slow) }
            }
            XCTFail("Exact managed FAQ question never became genuinely reachable")
        }
        var checked = [[String: Any]]()
        for reference in references {
            let question = app.buttons[reference.question]
            XCTAssertTrue(question.exists, "Managed FAQ question is missing from the actual All list")
            revealQuestion(question)
            XCTAssertTrue(question.isHittable)
            XCTAssertFalse(question.isSelected)
            XCTAssertNil(answer(reference), "Collapsed question must not already expose its answer")
            question.tap()
            let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                question.isSelected && answer(reference) != nil
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed,
                           "The complete rendered answer must match this exact managed question")
            let text = try XCTUnwrap(answer(reference))
            XCTAssertEqual(normalized(text.label), reference.answer)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "FAQ-\(reference.id)-actual-expanded-public-content"
            image.lifetime = .keepAlways; add(image)
            revealQuestion(question)
            XCTAssertTrue(question.isHittable)
            question.tap()
            let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !question.isSelected && answer(reference) == nil
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed)
            XCTAssertEqual(count("GET /api/base/faqs"), faqBaseline)
            XCTAssertEqual(count("GET /api/base/faq_categories"), categoryBaseline)
            let record: [String: Any] = ["faqID": reference.id, "question": reference.question,
                "fullManagedAnswerMatched": true, "expandedSelected": true,
                "collapsedDeselectedAndAnswerAbsent": true, "extraFAQGETs": 0, "extraCategoryGETs": 0]
            checked.append(record)
            try evidence("P04-024-FAQ-\(reference.id)-actual-toggle", record)
        }
        XCTAssertEqual(checked.count, 14)
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.exists && back.isHittable); back.tap()
        XCTAssertTrue(app.buttons["Messages"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["All"].exists)
        XCTAssertFalse(app.navigationBars["FAQ"].exists)
        XCTAssertEqual(count("GET /api/base/faqs"), faqBaseline)
        XCTAssertEqual(count("GET /api/base/faq_categories"), categoryBaseline)
        try evidence("P04-024-all-managed-FAQ-controls", ["questions": checked,
            "checkedCount": checked.count, "backReturnedToMain": true,
            "extraFAQGETs": 0, "extraCategoryGETs": 0])
    }

    /// Support-form required gates complement the prior blank Subject test:
    /// nonblank Subject/empty Description, then whitespace-only Subject while
    /// preserving the typed draft. Never creates a support issue.
    func testSupportRequiredDescriptionAndWhitespaceSubjectPreserveDraftWithoutPOST() throws {
        try launch("ReportAnIssue")
        let addIssue = app.buttons["Report An Issue"].firstMatch
        XCTAssertTrue(addIssue.waitForExistence(timeout: 45))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            addIssue.isHittable && !addIssue.frame.isEmpty && self.app.frame.contains(addIssue.frame)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed,
                       "Native report button must finish loading and be reachable")
        addIssue.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let subject = app.textFields["Enter your issue subject..."]
        XCTAssertTrue(subject.waitForExistence(timeout: 15), "Actual native issue composer must open")
        subject.tap(); subject.typeText("Synthetic boundary subject")
        dismissKeyboard()
        XCTAssertEqual(subject.value as? String, "Synthetic boundary subject",
                       "Exact nonblank synthetic Subject is required before Description validation")
        let submit = app.buttons["Submit"].firstMatch
        scrollTo(submit); submit.tap()
        let descriptionError = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Description: ")).firstMatch
        XCTAssertTrue(descriptionError.waitForExistence(timeout: 5))
        XCTAssertEqual(subject.value as? String, "Synthetic boundary subject")
        XCTAssertEqual(count("POST /api/users/issues"), 0)
        scrollTo(subject); subject.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "Actual Subject must hold keyboard focus before replacing its text")
        // A center tap on SE places the caret before the trailing word. The
        // failed native hierarchy retained '   subject'. Move to the observed
        // field's trailing edge before deleting, then verify exact delivery.
        subject.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        subject.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                count: "Synthetic boundary subject".count + 1) + "   ")
        XCTAssertEqual(subject.value as? String, "   ",
                       "Whitespace-only Subject must be delivered before its required-field validation")
        dismissKeyboard(); scrollTo(submit)
        XCTAssertEqual(subject.value as? String, "   ", "Scrolling must preserve the exact whitespace draft")
        XCTAssertEqual(count("POST /api/users/issues"), 0)
        let whitespaceShot = XCTAttachment(screenshot: subject.screenshot())
        whitespaceShot.name = "support-synthetic-whitespace-subject-before-submit"
        whitespaceShot.lifetime = .keepAlways; add(whitespaceShot)
        submit.tap()
        let subjectError = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Subject: ")).firstMatch
        XCTAssertTrue(subjectError.waitForExistence(timeout: 5))
        XCTAssertEqual(subject.value as? String, "   ", "Whitespace draft must survive local rejection")
        XCTAssertEqual(count("POST /api/users/issues"), 0)
        XCTAssertTrue(submit.exists, "Validation must leave composer open")
        try evidence("support-required-gates-native", ["descriptionRequiredObserved": true,
                     "whitespaceSubjectRequiredObserved": true, "draftRetained": true, "issuePOSTs": 0])
    }

    /// P05-012/P04-034 external activation requires an installed mail handler.
    /// Returning via activate never presses Send in that external application.
    func testContactEmailExternalActivationAndReturnPreserveHelpCenter() throws {
        try launch("HelpCenter")
        let email = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Email Us")).firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 45)); scrollTo(email)
        XCTAssertTrue(email.label.contains("support@carezaar.com"), "Visible managed contact address incorrect")
        email.tap()
        let external = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.state != .runningForeground
        }, object: nil)
        guard XCTWaiter.wait(for: [external], timeout: 5) == .completed else {
            throw XCTSkip("Simulator did not open an external mail handler; external-link return is unverified")
        }
        app.activate()
        XCTAssertTrue(email.waitForExistence(timeout: 10) && email.isHittable)
        XCTAssertTrue(app.buttons["Delete Account"].exists)
        XCTAssertFalse(app.buttons["Report An Issue"].exists)
        XCTAssertEqual(count("POST /api/users/issues"), 0)
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["Messages"].firstMatch.waitForExistence(timeout: 10))
        try evidence("P05-012-P04-034-external-return", ["externalActivationObserved": true,
                     "nativeHelpCenterRestored": true, "backReturnedToMain": true, "issuePOSTs": 0,
                     "externalRecipientVerification": "not_observed_no_mail_send"])
    }
}
