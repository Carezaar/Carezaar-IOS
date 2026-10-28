import XCTest

/// Actual native wizard round trips. These tests mutate only the explicitly owned
/// client fixture and restore its original preferences. Map cases navigate only;
/// they never pan the map, request a new point, or save preferences.
final class PreferencesUpdateUITests: XCTestCase {
    private var app: XCUIApplication!
    private var restoreFixture: Fixture?
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app.terminate()
        if let fixture = restoreFixture { restore(fixture); restoreFixture = nil }
        // No tree dumps, credential screenshots, account identifiers or token output.
    }

    func testEqualAndReversedPayUseManagedErrorAndRetainInputs() throws {
        let fixture = try ownedFixture()
        launchPreferences(fixture: fixture)
        advance(to: .skills, fixture: fixture)
        advance(to: .schedule, fixture: fixture)
        let minimum = app.textFields[fixture.text("signup_form_client_minimum")]
        let maximum = app.textFields[fixture.text("signup_form_client_maximum")]
        let salaryError = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", fixture.text("general_salary_min_max"))).firstMatch

        replace(minimum, with: "20")
        replace(maximum, with: "20")
        continueButton(fixture).tap()
        XCTAssertTrue(salaryError.waitForExistence(timeout: 12), "Equal pay must show the server-managed standard error")
        XCTAssertEqual(minimum.value as? String, "20", "Minimum changed after rejected equality")
        XCTAssertEqual(maximum.value as? String, "20", "Maximum changed after rejected equality")
        XCTAssertFalse(app.staticTexts[fixture.text("signup_form_client_review")].exists, "Invalid equality advanced to review")
        XCTAssertTrue(salaryError.waitForNonExistence(timeout: 12), "First validation toast must finish before testing the next attempt")

        replace(minimum, with: "40")
        replace(maximum, with: "20")
        continueButton(fixture).tap()
        XCTAssertTrue(salaryError.waitForExistence(timeout: 12), "Reversed pay must show the same managed error")
        XCTAssertEqual(minimum.value as? String, "40", "Minimum changed after rejected reversal")
        XCTAssertEqual(maximum.value as? String, "20", "Maximum changed after rejected reversal")
        XCTAssertFalse(app.staticTexts[fixture.text("signup_form_client_review")].exists, "Invalid reversal advanced to review")
        let unchanged = try profile(fixture.token)
        XCTAssertEqual(integer(unchanged["salary_min"]), integer(fixture.original["salary_min"]))
        XCTAssertEqual(integer(unchanged["salary_max"]), integer(fixture.original["salary_max"]))
    }

    func testNoClientCertificationsContinueSaveAndReopen() throws {
        let fixture = try ownedFixture()
        restoreFixture = fixture
        try certificationRoundTrip([], fixture: fixture, firstLaunch: true)
    }

    func testOneAndMultipleClientCertificationsSaveAndReopen() throws {
        let fixture = try ownedFixture()
        guard fixture.certifications.count >= 2 else {
            throw XCTSkip("The live certification catalogue needs two distinct entries for the multiple-selection case.")
        }
        restoreFixture = fixture
        try certificationRoundTrip([fixture.certifications[0].id], fixture: fixture, firstLaunch: true)
        try certificationRoundTrip(Array(fixture.certifications.prefix(2)).map(\.id), fixture: fixture, firstLaunch: false)
    }

    func testPreviouslyPopulatedClientCertificationsCanBeClearedAndReopened() throws {
        let fixture = try ownedFixture()
        let first = try XCTUnwrap(fixture.certifications.first, "Live certification catalogue is empty")
        restoreFixture = fixture
        // Establish a real saved, reopened nonempty baseline before clearing it.
        // Starting from an already-empty profile cannot prove this transition.
        try certificationRoundTrip([first.id], fixture: fixture, firstLaunch: true)
        try certificationRoundTrip([], fixture: fixture, firstLaunch: false)
    }

    /// P03-030 / P09-002: the connection fails on the first save (the request never reaches
    /// the server). The wizard stays on the review step with every input, shows the managed
    /// connection message, and the explicit second Save stores the same values once.
    func testConnectionFailureDuringSaveKeepsInputsAndRetrySavesOnce() throws {
        let fixture = try ownedFixture()
        restoreFixture = fixture
        let wanted = fixture.certifications.prefix(1).map(\.id)
        launchPreferences(fixture: fixture, extra: ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-fail-once", "PUT", "clients/profile"])
        advance(to: .skills, fixture: fixture)
        for certificate in fixture.certifications { setCertificate(certificate, selected: wanted.contains(certificate.id)) }
        advance(to: .schedule, fixture: fixture)
        advance(to: .review, fixture: fixture)
        let save = app.buttons[fixture.text("general_save")].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap()
        let failure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", fixture.text("general_network_title"))).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 30), "a failed save shows the managed connection message")
        XCTAssertTrue(save.exists, "the wizard stays on the review step after a failed save")
        XCTAssertTrue(app.staticTexts[fixture.text("signup_form_client_review")].exists, "still on review with the entered values")
        let unchanged = try profile(fixture.token)
        XCTAssertEqual(Set(ids(unchanged["certification_ids"])), Set(ids(fixture.original["certification_ids"])), "nothing was saved by the failed attempt")
        sleep(4) // let the error toast clear the Save button
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 60), "the explicit retry saves and returns")
        let saved = try profile(fixture.token)
        XCTAssertEqual(Set(ids(saved["certification_ids"])), Set(wanted), "the retry stored the entered values")
        let ledger = app.staticTexts["qa-request-counts"].label
        let puts = ledger.split(separator: "\n").first { $0.hasPrefix("PUT /api/clients/profile=") }.flatMap { Int($0.split(separator: "=").last ?? "") } ?? 0
        // The refused first Save never reached the server. Writes are never retried
        // automatically (Technical Alignment, 26 Oct), so the explicit retry is the second PUT.
        XCTAssertEqual(puts, 2, "one refused attempt plus one explicit retry, nothing else")
    }

    func testSavedLocationPickerCancelAndConfirmContinueWithoutSaving() throws {
        try savedLocationNavigation()
    }

    func testSavedLocationContinuesWithPreviouslyDeniedPhonePermission() throws {
        // Root must independently configure and verify denied location permission
        // for this simulator/app before setting this attestation. The environment
        // flag does not alter authorization and is not proof of CoreLocation state.
        guard env["QA_LOCATION_PERMISSION_DENIED"] == "1" else {
            throw XCTSkip("Requires independently verified simulator location denial; set QA_LOCATION_PERMISSION_DENIED=1 only after recording that prerequisite.")
        }
        try savedLocationNavigation()
    }

    private func savedLocationNavigation() throws {
        let fixture = try ownedFixture()
        let latitude = try XCTUnwrap(number(fixture.original["lat"]))
        let longitude = try XCTUnwrap(number(fixture.original["lng"]))
        let coordinateLabel = String(format: "%.6f , %.6f", latitude, longitude)
        let confirmLabel = try XCTUnwrap(fixture.labels["general_confirm"], "Managed map Confirm label is missing")
        XCTAssertFalse(confirmLabel.isEmpty)

        launchPreferences(fixture: fixture)
        advance(to: .skills, fixture: fixture)
        advance(to: .schedule, fixture: fixture)
        let locationRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", coordinateLabel)).firstMatch
        scrollTo(locationRow)
        XCTAssertTrue(locationRow.waitForExistence(timeout: 10), "Schedule did not show the fixture's exact saved coordinate")
        let originalLocationLabel = locationRow.label

        locationRow.tap()
        let confirm = app.buttons[confirmLabel].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "A saved point should open the map with Confirm available")
        XCTAssertTrue(confirm.isEnabled, "The existing point is already a valid selection")
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10), "Native map did not open")
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.exists && back.isHittable, "Map must offer cancellation")
        back.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10), "Map did not close after cancellation")
        XCTAssertTrue(locationRow.waitForExistence(timeout: 10))
        XCTAssertEqual(locationRow.label, originalLocationLabel, "Cancel changed the saved location summary")

        locationRow.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        // Confirm the initial selection without touching Map or My location.
        // This verifies persisted-point behavior, not physical phone GPS.
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10), "Map did not close after confirming the existing point")
        XCTAssertTrue(locationRow.waitForExistence(timeout: 10))
        XCTAssertEqual(locationRow.label, originalLocationLabel, "Confirm without panning changed the initial coordinate")
        advance(to: .review, fixture: fixture)
        let reviewCoordinate = app.staticTexts[coordinateLabel].firstMatch
        scrollTo(reviewCoordinate)
        XCTAssertTrue(reviewCoordinate.waitForExistence(timeout: 10), "Review did not retain the exact existing coordinate")
        XCTAssertTrue(app.buttons[fixture.text("general_save")].exists, "Review must be reached before any save")

        let unchanged = try profile(fixture.token)
        for key in ["clienttype_id", "salary_min", "salary_max"] {
            XCTAssertEqual(integer(unchanged[key]), integer(fixture.original[key]), "Read-only map navigation changed a server preference")
        }
        for key in ["carecondition_ids", "careday_ids", "carespecial_ids", "certification_ids", "commute_ids", "experience_ids", "gender_ids", "languageskill_ids", "role_ids", "shift_ids", "worktype_ids"] {
            XCTAssertEqual(Set(ids(unchanged[key])), Set(ids(fixture.original[key])), "Read-only map navigation changed a server selection")
        }
        XCTAssertEqual(number(unchanged["lat"]), latitude, "Read-only map navigation changed the server latitude")
        XCTAssertEqual(number(unchanged["lng"]), longitude, "Read-only map navigation changed the server longitude")
    }

    private enum Step { case skills, schedule, review }
    private struct Certificate { let id: Int; let label: String }
    private struct Fixture {
        let token: String
        let original: [String: Any]
        let labels: [String: String]
        let certifications: [Certificate]
        let careTypeLabel: String
        func text(_ slug: String) -> String { labels[slug] ?? slug }
    }

    private func ownedFixture() throws -> Fixture {
        guard env["QA_OWNED_CLIENT_FIXTURE"] == "1",
              let email = env["QA_EMAIL"], !email.isEmpty,
              let password = env["QA_PASSWORD"], !password.isEmpty,
              let expectedUserId = env["QA_CLIENT_USER_ID"], !expectedUserId.isEmpty else {
            throw XCTSkip("Root must provide credentials and the exact user id of its owned client fixture, with QA_OWNED_CLIENT_FIXTURE=1.")
        }
        let token = try CarezaarAPI.login(email, password)
        XCTAssertFalse(token.isEmpty, "Owned client fixture sign-in failed")
        let user = try CarezaarAPI.me(token)
        XCTAssertTrue(string(user["id"]) == expectedUserId, "Refusing a fixture with an unexpected user identity")
        XCTAssertTrue(string(user["role"]).lowercased() == "client", "Refusing to mutate a non-client fixture")
        let original = try profile(token)
        let profileUser = original["user"] as? [String: Any] ?? [:]
        XCTAssertTrue(string(profileUser["id"]) == expectedUserId, "Client preferences do not belong to the authorized fixture")
        // Preserve the setup's synthetic QA coordinates. These are fixture locations,
        // never labelled as the phone's location and never replaced with made-up points.
        XCTAssertNotNil(number(original["lat"]), "Owned fixture needs its already-saved QA latitude")
        XCTAssertNotNil(number(original["lng"]), "Owned fixture needs its already-saved QA longitude")
        for key in ["carecondition_ids", "carespecial_ids", "experience_ids", "role_ids", "languageskill_ids", "commute_ids", "shift_ids", "careday_ids", "worktype_ids", "gender_ids"] {
            XCTAssertFalse(ids(original[key]).isEmpty, "Fixture is missing an existing required preference selection")
        }
        XCTAssertNotNil(integer(original["clienttype_id"]), "Fixture has no existing client type")
        let content = try CarezaarAPI.call("GET", "base/contents?ts_cache=0", token: token)
        var labels: [String: String] = [:]
        for row in content["result"] as? [[String: Any]] ?? [] {
            guard let slug = row["slug"] as? String,
                  let translation = (row["translations"] as? [[String: Any]])?.first(where: { integer($0["language_id"]) == 1 }),
                  let text = translation["name"] as? String else { continue }
            labels[slug] = text
        }
        for slug in ["general_salary_min_max", "signup_form_client_minimum", "signup_form_client_maximum", "signup_form_client_continue", "signup_form_client_tell_us_about_needs", "signup_form_client_schedule_preferences", "signup_form_client_review", "general_save"] {
            XCTAssertFalse(labels[slug]?.isEmpty ?? true, "Required managed test label is missing: \(slug)")
        }
        let catalogue = try CarezaarAPI.call("GET", "base/certifications?ts_cache=0", token: token)
        let certificates = (catalogue["result"] as? [[String: Any]] ?? []).compactMap { row -> Certificate? in
            guard let id = integer(row["id"]),
                  let translation = (row["translations"] as? [[String: Any]])?.first(where: { integer($0["language_id"]) == 1 }),
                  let label = translation["name"] as? String, !label.isEmpty else { return nil }
            return Certificate(id: id, label: label)
        }.sorted { $0.id < $1.id }
        XCTAssertEqual(Set(certificates.map(\.id)).count, certificates.count, "Certification identifiers are duplicated")
        XCTAssertEqual(Set(certificates.map(\.label)).count, certificates.count, "Ambiguous certification labels need a scoped selector")
        let types = try CarezaarAPI.call("GET", "base/clienttypes?ts_cache=0", token: token)
        guard let type = (types["result"] as? [[String: Any]])?.first(where: { integer($0["id"]) == integer(original["clienttype_id"]) }),
              let translation = (type["translations"] as? [[String: Any]])?.first(where: { integer($0["language_id"]) == 1 }),
              let typeLabel = translation["name"] as? String, !typeLabel.isEmpty else {
            throw XCTSkip("The existing client type is absent from the live English reference catalogue.")
        }
        return Fixture(token: token, original: original, labels: labels, certifications: certificates, careTypeLabel: typeLabel)
    }

    private func launchPreferences(fixture: Fixture, retainSession: Bool = false, extra: [String] = []) {
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["-carezaar.languageId", "1", "-carezaar.languageCode", "en", "--qa-push", "ClientPreferences"] + extra
        if !retainSession { app.launchArguments += ["--qa-signout", "--qa-login-env"] }
        app.launch()
        let continueControl = continueButton(fixture)
        XCTAssertTrue(continueControl.waitForExistence(timeout: 60), "Native edit wizard did not open")
        // Edit mode has no Get Started screen and must prefill before interaction.
        let typeCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", fixture.careTypeLabel)).firstMatch
        XCTAssertTrue(typeCard.waitForExistence(timeout: 30), "Saved client type card is missing")
        let selected = NSPredicate { _, _ in typeCard.isSelected }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: nil)], timeout: 30), .completed,
                       "Saved client type did not prefill")
    }

    private func continueButton(_ fixture: Fixture) -> XCUIElement {
        app.buttons[fixture.text("signup_form_client_continue")].firstMatch
    }

    private func advance(to step: Step, fixture: Fixture) {
        continueButton(fixture).tap()
        let slug: String
        switch step {
        case .skills: slug = "signup_form_client_tell_us_about_needs"
        case .schedule: slug = "signup_form_client_schedule_preferences"
        case .review: slug = "signup_form_client_review"
        }
        XCTAssertTrue(app.staticTexts[fixture.text(slug)].waitForExistence(timeout: 15), "Wizard did not reach the expected next step")
    }

    private func certificationRoundTrip(_ wanted: [Int], fixture: Fixture, firstLaunch: Bool) throws {
        launchPreferences(fixture: fixture, retainSession: !firstLaunch)
        advance(to: .skills, fixture: fixture)
        for certificate in fixture.certifications { setCertificate(certificate, selected: wanted.contains(certificate.id)) }
        // No manual map interaction: the wizard must use the fixture's saved point.
        advance(to: .schedule, fixture: fixture)
        advance(to: .review, fixture: fixture)
        let save = app.buttons[fixture.text("general_save")].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 60), "Native preference save did not return")
        let saved = try profile(fixture.token)
        XCTAssertEqual(Set(ids(saved["certification_ids"])), Set(wanted), "Saved certification ids differ from native UI selections")
        XCTAssertEqual(number(saved["lat"]), number(fixture.original["lat"]), "Save unexpectedly changed the synthetic QA latitude")
        XCTAssertEqual(number(saved["lng"]), number(fixture.original["lng"]), "Save unexpectedly changed the synthetic QA longitude")
        launchPreferences(fixture: fixture, retainSession: true)
        advance(to: .skills, fixture: fixture)
        for certificate in fixture.certifications {
            let chip = certificateChip(certificate)
            scrollTo(chip)
            XCTAssertEqual(chip.isSelected, wanted.contains(certificate.id), "Reopened certification selection differs from persisted ids")
        }
    }

    private func certificateChip(_ certificate: Certificate) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", certificate.label))
        XCTAssertEqual(matches.count, 1, "Certification chip selector is ambiguous")
        return matches.firstMatch
    }

    private func setCertificate(_ certificate: Certificate, selected: Bool) {
        let chip = certificateChip(certificate)
        scrollTo(chip)
        XCTAssertTrue(chip.exists && chip.isHittable, "Certification chip is unavailable")
        if chip.isSelected != selected { chip.tap() }
        let state = NSPredicate { _, _ in chip.isSelected == selected }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: state, object: nil)], timeout: 3), .completed,
                       "Certification selection did not update")
    }

    private func replace(_ field: XCUIElement, with text: String) {
        scrollTo(field)
        XCTAssertTrue(field.exists && field.isHittable, "Pay field unavailable")
        // The native selection menu can dismiss focus on the modern simulator.
        // Move to the actual field's trailing edge and replace by backspacing;
        // avoid treating a successful Select All query as keyboard-focus proof.
        let current = field.value as? String ?? ""
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Pay input did not obtain keyboard focus")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(text)
        let ok = app.toolbars.buttons["OK"]
        if ok.waitForExistence(timeout: 2) { ok.tap() }
        XCTAssertEqual(field.value as? String, text, "Pay field replacement did not take effect")
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<16 {
            if element.exists && element.isHittable && element.frame.minY > 90 && element.frame.maxY < app.frame.maxY - 160 { return }
            if element.exists && element.frame.minY < 90 { app.swipeDown(velocity: .slow) }
            else { app.swipeUp(velocity: .slow) }
        }
    }

    private func profile(_ token: String) throws -> [String: Any] {
        let response = try CarezaarAPI.call("GET", "clients/profile", token: token)
        let result = CarezaarAPI.result(response)
        XCTAssertFalse(result.isEmpty, "Owned client profile read failed")
        return result
    }

    private func restore(_ fixture: Fixture) {
        var form: [String: String] = [:]
        for key in ["clienttype_id", "lat", "lng", "salary_min", "salary_max"] {
            if let value = fixture.original[key], !(value is NSNull) { form[key] = string(value) }
        }
        for key in ["carecondition_ids", "careday_ids", "carespecial_ids", "certification_ids", "commute_ids", "experience_ids", "gender_ids", "languageskill_ids", "role_ids", "shift_ids", "worktype_ids"] {
            form[key] = ids(fixture.original[key]).map(String.init).joined(separator: ",")
        }
        do {
            let response = try CarezaarAPI.call("PUT", "clients/profile", form: form, token: fixture.token)
            XCTAssertFalse(CarezaarAPI.result(response).isEmpty, "Owned fixture restoration was rejected")
            let restored = try profile(fixture.token)
            for key in form.keys where key.hasSuffix("_ids") {
                XCTAssertEqual(Set(ids(restored[key])), Set(ids(fixture.original[key])), "Owned fixture restoration changed a selection")
            }
            for key in ["clienttype_id", "salary_min", "salary_max"] {
                XCTAssertEqual(integer(restored[key]), integer(fixture.original[key]), "Owned fixture restoration changed a scalar preference")
            }
            XCTAssertEqual(number(restored["lat"]), number(fixture.original["lat"]))
            XCTAssertEqual(number(restored["lng"]), number(fixture.original["lng"]))
        } catch { XCTFail("Owned fixture preferences could not be restored; root must inspect privately before subsequent mutation tests.") }
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        return (value as? String).flatMap(Int.init)
    }
    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        return (value as? String).flatMap(Double.init)
    }
    private func ids(_ value: Any?) -> [Int] { (value as? [Any] ?? []).compactMap(integer) }
    private func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
}
