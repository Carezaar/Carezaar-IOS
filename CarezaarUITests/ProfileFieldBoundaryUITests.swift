import XCTest

/// P03-011 shared signup-mode form boundaries. Direct Debug rendering bypasses
/// registration/OTP and role handoff; it cannot prove the complete signup journey.
/// No Save/Continue action or photo control is ever tapped.
final class ProfileFieldBoundaryUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app?.terminate() }

    private func launch() {
        app.launchArguments = ["--qa-signout", "--qa-request-counts", "--qa-route", "SignUpProfile",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        XCTAssertTrue(app.textFields["Enter your first name"].waitForExistence(timeout: 45))
    }
    private var next: XCUIElement { app.buttons["Continue"].firstMatch }
    private func replace(_ field: XCUIElement, _ input: String) {
        for _ in 0..<5 where !field.isHittable { app.swipeUp() }
        for _ in 0..<5 where !field.isHittable { app.swipeDown() }
        XCTAssertTrue(field.isHittable); field.tap()
        let existing = field.value as? String ?? ""
        let count = existing == field.placeholderValue ? 0 : existing.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + input)
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["OK", "Done"])).firstMatch
        if done.exists && done.isHittable { done.tap() }
        else if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
    }
    private func noWrite(_ stage: String) {
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.exists)
        for key in ["PATCH /api/users/profile=", "POST /api/users/profile=", "POST /api/auth/register=", "POST /api/users/otp/send="] {
            XCTAssertFalse(ledger.label.contains(key), "\(stage): forbidden account/profile mutation")
        }
    }
    private func selectAdultDate() {
        let picker = app.datePickers.firstMatch
        for _ in 0..<5 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.exists && picker.isHittable); picker.tap()
        let monthYear = app.buttons["DatePicker.Show"]
        XCTAssertTrue(monthYear.waitForExistence(timeout: 5)); monthYear.tap()
        let year = app.pickerWheels.matching(NSPredicate(format: "value MATCHES %@", "[0-9]{4}")).firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 5)); year.adjust(toPickerWheelValue: "1990")
        XCTAssertEqual(year.value as? String, "1990")
        if app.buttons["DatePicker.Hide"].exists { app.buttons["DatePicker.Hide"].tap() }
        else { monthYear.tap() }
        let day = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", " 12")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5)); day.tap()
        let dismiss = app.buttons["PopoverDismissRegion"]
        // Both captured native hierarchies expose this dismissal as Button,
        // not Other. If still presented, use that observed native control.
        if dismiss.exists && dismiss.isHittable { dismiss.tap() }
        XCTAssertTrue(app.buttons["DatePicker.PreviousMonth"].waitForNonExistence(timeout: 5),
                      "Calendar must close before checking the profile field gates")
        let displayedDate = picker.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Date Picker")).firstMatch
        let retainedYear = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            displayedDate.exists && (displayedDate.value as? String)?.contains("1990") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [retainedYear], timeout: 5), .completed,
                       "Actual bound DOB must retain the selected adult year")
    }

    func testSignupProfileRequiredFieldsAndAccentedLongDraftsWithoutSaving() {
        launch()
        XCTAssertTrue(next.exists); XCTAssertFalse(next.isEnabled); noWrite("empty")
        let first = app.textFields["Enter your first name"]
        let last = app.textFields["Enter your last name"]
        let accented = "Élodie"
        let longName = String(repeating: "Álvarez", count: 12)
        replace(first, accented); replace(last, longName)
        XCTAssertEqual(first.value as? String, accented)
        XCTAssertEqual(last.value as? String, longName)
        XCTAssertFalse(next.isEnabled, "Missing gender/date must keep Continue disabled")
        selectAdultDate()
        XCTAssertFalse(next.isEnabled, "Missing gender alone must keep Continue disabled")
        let gender = app.buttons["Select your gender"]
        // The calendar popover fades out after the day tap; until it is gone nothing
        // behind it is hittable, so wait for that before deciding to scroll.
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: gender)], timeout: 5)
        for _ in 0..<5 where !gender.isHittable { app.swipeUp() }
        XCTAssertTrue(gender.isHittable); gender.tap()
        let female = app.buttons["Female"]
        XCTAssertTrue(female.waitForExistence(timeout: 5)); female.tap()
        XCTAssertTrue(next.isEnabled, "All required adult fields must make the native action eligible")
        replace(first, "   ")
        XCTAssertFalse(next.isEnabled, "Whitespace first name must be rejected")
        XCTAssertEqual(last.value as? String, longName)
        replace(first, accented); replace(last, "")
        XCTAssertFalse(next.isEnabled, "Empty last name alone must be rejected")
        XCTAssertEqual(first.value as? String, accented)
        noWrite("all local gates")
        let evidence = XCTAttachment(string: "P03-011 shared signup form: blank gate, missing gender, accented/long local retention, whitespace first name, empty last name. No save. Full role/OTP handoff not exercised.")
        evidence.name = "P03-011-required-draft-subset"; evidence.lifetime = .keepAlways; add(evidence)
    }

    func testSignupProfileUnselectedDateAndNativeAdultCalendarBoundary() {
        launch()
        replace(app.textFields["Enter your first name"], "Synthetic")
        replace(app.textFields["Enter your last name"], "Boundary")
        let gender = app.buttons["Select your gender"]
        for _ in 0..<5 where !gender.isHittable { app.swipeUp() }
        XCTAssertTrue(gender.isHittable); gender.tap()
        XCTAssertTrue(app.buttons["Female"].waitForExistence(timeout: 5)); app.buttons["Female"].tap()
        XCTAssertFalse(next.isEnabled, "Displayed default date must not masquerade as a selected DOB")
        let picker = app.datePickers.firstMatch
        for _ in 0..<5 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.exists && picker.isHittable); picker.tap()
        let forward = app.buttons["DatePicker.NextMonth"]
        XCTAssertTrue(forward.waitForExistence(timeout: 5))
        XCTAssertFalse(forward.isEnabled, "Calendar opens at maximum adult month; newer underage month must be inaccessible")
        noWrite("unselected DOB/calendar boundary")
        let evidence = XCTAttachment(string: "P03-011 subset: unselected DOB blocks submission; native next-month control disabled at adult-limit month. No under-18 DOB injected/selected, no server age-refusal claim, no profile write.")
        evidence.name = "P03-011-adult-picker-subset"; evidence.lifetime = .keepAlways; add(evidence)
    }
}
