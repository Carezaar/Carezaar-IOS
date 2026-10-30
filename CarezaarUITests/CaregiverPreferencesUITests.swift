import XCTest
import UIKit

/// Read-only navigation cases plus one bounded certification persistence test.
/// The persistence case restores the strictly identified owned fixture in teardown.
/// APK ki0.java's caregiver Continue calls px.java case 0, which validates
/// experience/role/services/qualities/language and forwards certifications without
/// an empty guard. Zero certifications therefore must remain supported.
final class CaregiverPreferencesUITests: XCTestCase {
    private var app: XCUIApplication!
    private var restoreFixture: Fixture?
    private var persistenceBackupURL: URL?
    private var persistenceStages: [[String: Any]] = []
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        persistenceBackupURL = nil
        persistenceStages = []
    }

    override func tearDown() {
        app?.terminate()
        if let fixture = restoreFixture {
            restoreOwnedPreferences(fixture)
            restoreFixture = nil
        }
    }

    func testCaregiverCertificationsSaveReopenAndClearPopulatedSelection() throws {
        let fixture = try ownedFixture()
        guard fixture.certificates.count >= 2 else {
            throw XCTSkip("Live certification catalogue needs two distinct entries")
        }
        XCTAssertNotNil(number(fixture.original["lat"]), "Persistence requires a saved fixture latitude")
        XCTAssertNotNil(number(fixture.original["lng"]), "Persistence requires a saved fixture longitude")
        // Durable private full profile + exact official service payload precedes
        // every possible mutation, including an interrupted/lost-ack native Save.
        try preservePersistenceBaseline(fixture)
        // One -> multiple -> empty proves clearing a populated server selection,
        // rather than merely reopening a fixture that started empty.
        for count in [1, 2, 0] {
            try launchSkills(fixture)
            let wanted = Set(fixture.certificates.prefix(count).map(\.id))
            for certificate in fixture.certificates {
                setChip(certificate.label, selected: wanted.contains(certificate.id))
            }
            advance(fixture, title: "signup_form_caregiver_schedule_title")
            advance(fixture, title: "signup_form_caregiver_review_title")
            let save = app.buttons[fixture.text("general_save")].firstMatch
            XCTAssertTrue(save.waitForExistence(timeout: 10) && save.isEnabled, "Native review Save is unavailable")
            // Re-check bearer identity immediately before every production UI save.
            try verifyIdentity(fixture)
            restoreFixture = fixture
            try savePersistenceProgress(restored: false) // before possible transfer/lost ACK
            save.tap()
            XCTAssertTrue(save.waitForNonExistence(timeout: 60), "Native caregiver preference save did not return")
            try assertServerUnchanged(fixture, certificationIds: wanted)

            try launchSkills(fixture)
            for certificate in fixture.certificates {
                let control = chip(certificate.label)
                XCTAssertEqual(control.isSelected, wanted.contains(certificate.id),
                               "Reopened native caregiver certification differs from the saved backend set")
            }
            for (index, certificate) in fixture.certificates.prefix(2).enumerated() {
                let control = chip(certificate.label)
                scrollTo(control)
                proof(control, name: "saved-reopened-certifications-\(count)-chip-\(index + 1)")
            }
            try assertServerUnchanged(fixture, certificationIds: wanted)
            persistenceStages.append(["savedCertificationCount": count,
                "savedCertificationIDs": wanted.sorted(), "actualNativeSaveAndReopen": true,
                "allNonCertificationFieldsUnchanged": true])
            try savePersistenceProgress(restored: false)
        }
    }

    /// Root must compare these timed header-only rasters against the mapped
    /// bundled assets before attributing rotation coverage. Pixel differences alone
    /// are not evidence of which saved type was displayed.
    func testOwnedCaregiverSavedOneAndTwoTypesMatchesHeroWithoutRefresh() throws {
        let fixture = try ownedFixture()
        let bundled = Set(["header_adult", "header_child", "header_pregnancy", "header_senior"])
        let catalogueRows = try catalogue("clienttypes", token: fixture.token)
        var mapped: [Int: String] = [:]
        for row in catalogueRows {
            guard let id = integer(row["id"]), let icon = row["icon"] as? String,
                  icon.hasPrefix("client_") else { continue }
            let image = icon.replacingOccurrences(of: "client_", with: "header_")
            if bundled.contains(image) { mapped[id] = image }
        }
        let originalTypes = ids(fixture.original["clienttype_ids"])
        let preferred = originalTypes + mapped.keys.sorted().filter { !originalTypes.contains($0) }
        var selected: [Int] = [], images = Set<String>()
        for id in preferred {
            if let image = mapped[id], images.insert(image).inserted { selected.append(id) }
            if selected.count == 2 { break }
        }
        guard selected.count == 2 else {
            throw XCTSkip("Requires two live catalogue types mapped to distinct existing bundled header images")
        }
        let title = try XCTUnwrap(fixture.labels["caregiver_matches_page_title"])
        let subtitle = try XCTUnwrap(fixture.labels["caregiver_matches_page_description"])
        let allMatches = try XCTUnwrap(fixture.labels["caregiver_matches_all_matches"])
        XCTAssertFalse(title.isEmpty)
        XCTAssertFalse(subtitle.isEmpty)
        for count in [1, 2] {
            let wanted = Array(selected.prefix(count))
            let before = try profile(fixture.token)
            if Set(ids(before["clienttype_ids"])) != Set(wanted) {
                try verifyIdentity(fixture)
                restoreFixture = fixture // before the first transfer, including lost ACK
                var form = try preferenceForm(fixture)
                form["clienttype_ids"] = wanted.map(String.init).joined(separator: ",")
                let result = try CarezaarAPI.callWithHTTPStatus("PUT", "caregivers/profile", form: form, token: fixture.token)
                XCTAssertEqual(result.status, 200, "Owned hero fixture selection was rejected")
                XCTAssertFalse(CarezaarAPI.result(result.body).isEmpty)
            }
            let saved = try profile(fixture.token)
            // Preference IDs are a selection set, not a promised PUT ordering.
            // MainView rotates in the actual GET profile array order, including
            // any server canonical ordering, so that saved order is authoritative.
            let savedTypes = ids(saved["clienttype_ids"])
            XCTAssertEqual(savedTypes.count, wanted.count, "Saved types have missing or duplicate entries")
            XCTAssertEqual(Set(savedTypes), Set(wanted), "Saved type membership differs from the exact owned selection")
            let orderedAssets = try savedTypes.map { id in
                try XCTUnwrap(mapped[id], "Saved catalogue type lacks an inspected bundled header mapping")
            }
            try assertServerUnchanged(fixture, clientTypeIds: Set(wanted))
            app.terminate()
            app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
            app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
            app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-tab", "matches",
                                   "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
            app.launch()
            let hero = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", title, subtitle)).firstMatch
            XCTAssertTrue(hero.waitForExistence(timeout: 60), "Managed combined Matches hero is unavailable")
            let heading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", allMatches)).firstMatch
            XCTAssertTrue(heading.waitForExistence(timeout: 30), "Matches list heading is unavailable")
            let scroll = app.scrollViews.firstMatch
            XCTAssertTrue(scroll.exists)
            // Capture only a 196-point image slice inside the observed hero and
            // visible scroll viewport. The combined AX frame can be taller than
            // the picture slice; this crop does not prove full text readability.
            // Refuse geometry that could capture any list control or user card.
            // Keep the slice one point inside horizontal edges: combined AX
            // frames can differ from the viewport by floating-point roundoff.
            // Strict containment still applies; no expanded crop or tolerance.
            let rect = CGRect(x: scroll.frame.minX + 1, y: scroll.frame.minY,
                              width: scroll.frame.width - 2, height: 196)
            let geometry: [String: Any] = ["savedTypeCount": count,
                "appFrame": frameNumbers(app.frame), "scrollViewportFrame": frameNumbers(scroll.frame),
                "combinedHeroAXFrame": frameNumbers(hero.frame), "allMatchesHeadingAXFrame": frameNumbers(heading.frame),
                "proposedCropRect": frameNumbers(rect)]
            let geometryAttachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys]),
                                                   uniformTypeIdentifier: "public.json")
            geometryAttachment.name = "owned-caregiver-hero-\(count)-types-anonymous-geometry"
            geometryAttachment.lifetime = .keepAlways
            add(geometryAttachment)
            let visibleHero = hero.frame.intersection(scroll.frame).intersection(app.frame)
            XCTAssertFalse(visibleHero.isNull || visibleHero.isEmpty, "Native hero has no visible safe image region")
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertEqual(rect.height, 196)
            XCTAssertTrue(visibleHero.contains(rect), "Image slice must remain inside the observed hero and viewport")
            XCTAssertGreaterThanOrEqual(heading.frame.minY, rect.maxY, "Unsafe crop overlaps the list heading")
            // Wait until initial profile/Matches reads finish before timing. The
            // unrelated notification poll is permitted and deliberately excluded.
            var baseline = try heroReadCounts()
            var stable = false
            for _ in 0..<12 {
                Thread.sleep(forTimeInterval: 1)
                let next = try heroReadCounts()
                if next == baseline && baseline.values.reduce(0, +) >= 2 { stable = true; break }
                baseline = next
            }
            XCTAssertTrue(stable, "Native hero reads never settled")
            let start = Date()
            var captures: [[String: Any]] = []
            for index in 0...13 {
                if index > 0 { Thread.sleep(forTimeInterval: 2) }
                XCTAssertTrue(hero.exists && hero.label.contains(title) && hero.label.contains(subtitle), "Hero text changed during rotation")
                XCTAssertEqual(try heroReadCounts(), baseline, "Rotation triggered an unnecessary profile/Matches read")
                XCTAssertGreaterThanOrEqual(heading.frame.minY, rect.maxY)
                XCTAssertTrue(hero.frame.intersection(scroll.frame).intersection(app.frame).contains(rect),
                              "Timed image slice left the safe visible hero region")
                let image = app.screenshot().image
                let sourceRaster = try XCTUnwrap(image.cgImage)
                let sx = CGFloat(sourceRaster.width) / app.frame.width, sy = CGFloat(sourceRaster.height) / app.frame.height
                let pixels = CGRect(x: (rect.minX - app.frame.minX) * sx, y: (rect.minY - app.frame.minY) * sy,
                                    width: rect.width * sx, height: rect.height * sy).integral
                let raster = try XCTUnwrap(sourceRaster.cropping(to: pixels))
                let attachment = XCTAttachment(image: UIImage(cgImage: raster))
                attachment.name = "owned-caregiver-hero-\(count)-types-sample-\(index)"
                attachment.lifetime = .keepAlways
                add(attachment)
                captures.append(["sample": index, "elapsedSeconds": Date().timeIntervalSince(start)])
            }
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 24, "Need at least two full two-image cycles")
            try assertServerUnchanged(fixture, clientTypeIds: Set(wanted))
            let evidence: [String: Any] = ["savedTypeCount": count, "orderedMappedAssets": orderedAssets,
                "cropRectPoints": [rect.minX, rect.minY, rect.width, rect.height], "captures": captures,
                "relevantNativeReadCounts": baseline, "titleAndSubtitleStable": true,
                "rasterAssetOrderRequiresIndependentReview": true, "fullHeroTextRasterReadabilityVerified": false,
                "emptyTypeFallbackNativeTested": false]
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "owned-caregiver-hero-\(count)-types-anonymous-timing"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func frameNumbers(_ frame: CGRect) -> [Double] {
        [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
    }

    private func heroReadCounts() throws -> [String: Int] {
        let element = app.staticTexts["qa-request-counts"]
        guard element.exists else { throw URLError(.cannotParseResponse) }
        var result: [String: Int] = [:]
        for line in element.label.split(separator: "\n") {
            guard let split = line.lastIndex(of: "="), let value = Int(line[line.index(after: split)...]) else {
                throw URLError(.cannotParseResponse)
            }
            let key = String(line[..<split])
            if key == "GET /api/caregivers/profile" || key.hasPrefix("GET /api/caregivers/matches") { result[key] = value }
        }
        return result
    }

    private func preferenceForm(_ fixture: Fixture) throws -> [String: String] {
        var form: [String: String] = [:]
        for key in ["commute_id", "experience_id", "role_id", "worktype_id", "lat", "lng", "salary_min", "salary_max"] {
            guard let value = fixture.original[key], !(value is NSNull) else {
                XCTFail("Refusing an incomplete caregiver preference transfer")
                throw URLError(.cannotParseResponse)
            }
            form[key] = string(value)
        }
        for key in ["carecondition_ids", "careday_ids", "carespecial_ids", "certification_ids", "clienttype_ids", "languageskill_ids", "shift_ids"] {
            form[key] = ids(fixture.original[key]).map(String.init).joined(separator: ",")
        }
        return form
    }

    func testCaregiverEqualAndReversedPayRetainInputsWithoutSaving() throws {
        let fixture = try ownedFixture()
        try launchSkills(fixture)
        advance(fixture, title: "signup_form_caregiver_schedule_title")
        let minimum = app.textFields[fixture.text("signup_form_client_minimum")]
        let maximum = app.textFields[fixture.text("signup_form_client_maximum")]
        let error = app.staticTexts.matching(NSPredicate(format: "label == %@", fixture.text("general_salary_min_max"))).firstMatch

        for (low, high, stage) in [("20", "20", "equal-pay"), ("40", "20", "reversed-pay")] {
            replace(minimum, with: low)
            replace(maximum, with: high)
            continueButton(fixture).tap()
            XCTAssertTrue(error.waitForExistence(timeout: 12), "Expected exact managed pay error")
            XCTAssertEqual(minimum.value as? String, low, "Rejected pay changed minimum")
            XCTAssertEqual(maximum.value as? String, high, "Rejected pay changed maximum")
            XCTAssertFalse(app.staticTexts[fixture.text("signup_form_caregiver_review_title")].exists,
                           "Invalid pay advanced to review")
            proof(error, name: "\(stage)-managed-error")
            proof(minimum, name: "\(stage)-minimum-retained")
            proof(maximum, name: "\(stage)-maximum-retained")
            try assertServerUnchanged(fixture)
            XCTAssertTrue(error.waitForNonExistence(timeout: 12), "Validation toast did not finish")
        }
    }

    func testCaregiverZeroOneMultipleCertificationsContinueWithoutSaving() throws {
        let fixture = try ownedFixture()
        guard fixture.certificates.count >= 2 else {
            throw XCTSkip("Live certification catalogue needs two distinct entries")
        }
        for count in [0, 1, 2] {
            try launchSkills(fixture)
            let wanted = Set(fixture.certificates.prefix(count).map(\.id))
            for certificate in fixture.certificates {
                setChip(certificate.label, selected: wanted.contains(certificate.id))
            }
            for certificate in fixture.certificates {
                XCTAssertEqual(chip(certificate.label).isSelected, wanted.contains(certificate.id),
                               "Native certification state differs from the chosen set")
            }
            let first = chip(fixture.certificates[0].label)
            scrollTo(first)
            proof(first, name: "certifications-\(count)-first-chip")
            let second = chip(fixture.certificates[1].label)
            scrollTo(second)
            proof(second, name: "certifications-\(count)-second-chip")
            advance(fixture, title: "signup_form_caregiver_schedule_title")
            proof(app.staticTexts[fixture.text("signup_form_caregiver_schedule_title")],
                  name: "certifications-\(count)-continue-reached-schedule")
            try assertServerUnchanged(fixture)
        }
    }

    /// P03-028 / P03-029 (caregiver): the saved location is kept when the map is opened and
    /// cancelled, and when it is confirmed without moving; nothing is saved (mirrors the client test).
    func testCaregiverSavedLocationPickerCancelAndConfirmKeepSavedPointWithoutSaving() throws {
        let fixture = try ownedFixture()
        let latitude = try XCTUnwrap(number(fixture.original["lat"])), longitude = try XCTUnwrap(number(fixture.original["lng"]))
        let coordinateLabel = String(format: "%.6f , %.6f", latitude, longitude)
        let confirmLabel = fixture.text("general_confirm")
        try launchSkills(fixture)
        advance(fixture, title: "signup_form_caregiver_schedule_title")
        let locationRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", coordinateLabel)).firstMatch
        scrollTo(locationRow)
        XCTAssertTrue(locationRow.waitForExistence(timeout: 10), "Schedule shows the caregiver's exact saved coordinate")
        let original = locationRow.label
        locationRow.tap()
        let confirm = app.buttons[confirmLabel].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "The saved point opens the map with Confirm")
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10), "Native map opened")
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.exists && back.isHittable, "Map offers cancellation")
        back.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10), "Map closed after cancellation")
        XCTAssertEqual(locationRow.label, original, "Cancel kept the saved location")
        locationRow.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        confirm.tap() // no panning, no My Location: the saved point stays selected
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10))
        XCTAssertEqual(locationRow.label, original, "Confirm without moving kept the saved point")
        advance(fixture, title: "signup_form_caregiver_review_title")
        let review = app.staticTexts[coordinateLabel].firstMatch
        scrollTo(review)
        XCTAssertTrue(review.waitForExistence(timeout: 10), "Review keeps the exact saved coordinate")
        try assertServerUnchanged(fixture)
    }

    func testCaregiverEmptyRequiredLanguageShowsManagedValidationWithoutSaving() throws {
        let fixture = try ownedFixture()
        try launchSkills(fixture)
        for language in fixture.languages { setChip(language.label, selected: false) }
        let expected = fixture.text("general_select_one")
            .replacingOccurrences(of: "{PROPERTY}", with: fixture.text("signup_form_caregiver_languageskill"))
        continueButton(fixture).tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label == %@", expected)).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 12), "Required caregiver language must use managed validation")
        XCTAssertFalse(app.staticTexts[fixture.text("signup_form_caregiver_schedule_title")].exists,
                       "Empty required language advanced to schedule")
        proof(error, name: "empty-required-language-managed-error")
        try assertServerUnchanged(fixture)
    }

    private struct Item { let id: Int; let label: String }
    private struct Fixture {
        let userId: String
        let token: String
        let original: [String: Any]
        let labels: [String: String]
        let certificates: [Item]
        let languages: [Item]
        let selectedType: String
        func text(_ slug: String) -> String { labels[slug] ?? slug }
    }

    private func ownedFixture() throws -> Fixture {
        guard let email = env["QA_EMAIL"], !email.isEmpty,
              let password = env["QA_PASSWORD"], !password.isEmpty,
              let expected = env["QA_CG_ID"], !expected.isEmpty else {
            throw XCTSkip("Runner must supply owned caregiver credentials and exact QA_CG_ID")
        }
        let token = try CarezaarAPI.login(email, password)
        let user = try CarezaarAPI.me(token)
        guard !token.isEmpty, string(user["id"]) == expected,
              string(user["role"]).lowercased() == "caregiver" else {
            XCTFail("Refusing credentials that do not match the authorized caregiver identity and role")
            throw URLError(.userAuthenticationRequired)
        }
        let original = try profile(token)
        guard let profileUser = original["user"] as? [String: Any], string(profileUser["id"]) == expected else {
            XCTFail("Caregiver profile does not belong to the authorized identity")
            throw URLError(.userAuthenticationRequired)
        }
        for key in ["clienttype_ids", "carecondition_ids", "carespecial_ids", "languageskill_ids", "shift_ids", "careday_ids"] {
            XCTAssertFalse(ids(original[key]).isEmpty, "Saved caregiver fixture lacks a required selection: \(key)")
        }
        for key in ["experience_id", "role_id", "commute_id", "worktype_id", "salary_min", "salary_max"] {
            XCTAssertNotNil(integer(original[key]), "Saved caregiver fixture lacks a required value: \(key)")
        }
        let contents = try catalogue("contents", token: token)
        var labels: [String: String] = [:]
        for row in contents {
            if let slug = row["slug"] as? String, let label = english(row) { labels[slug] = label }
        }
        for slug in ["signup_form_client_continue", "signup_form_client_minimum", "signup_form_client_maximum",
                     "signup_form_caregiver_skill_title", "signup_form_caregiver_schedule_title",
                     "signup_form_caregiver_review_title", "signup_form_caregiver_languageskill",
                     "general_select_one", "general_salary_min_max", "general_save"] {
            XCTAssertFalse(labels[slug]?.isEmpty ?? true, "Required managed label missing: \(slug)")
        }
        let types = try items("clienttypes", token: token)
        let selected = try XCTUnwrap(types.first(where: { ids(original["clienttype_ids"]).contains($0.id) }),
                                     "Saved caregiver care type absent from live catalogue")
        return Fixture(userId: expected, token: token, original: original, labels: labels,
                       certificates: try items("certifications", token: token),
                       languages: try items("languageskills", token: token), selectedType: selected.label)
    }

    private func launchSkills(_ fixture: Fixture) throws {
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-push", "CaregiverSkills",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        app.passWizardIntro()
        XCTAssertTrue(continueButton(fixture).waitForExistence(timeout: 60), "Caregiver edit wizard did not open")
        let type = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", fixture.selectedType)).firstMatch
        XCTAssertTrue(type.waitForExistence(timeout: 30), "Saved caregiver care type is absent")
        let prefilled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in type.isSelected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [prefilled], timeout: 30), .completed, "Saved caregiver preferences did not prefill")
        advance(fixture, title: "signup_form_caregiver_skill_title")
    }

    private func continueButton(_ fixture: Fixture) -> XCUIElement {
        app.buttons[fixture.text("signup_form_client_continue")].firstMatch
    }

    private func advance(_ fixture: Fixture, title: String) {
        continueButton(fixture).tap()
        XCTAssertTrue(app.staticTexts[fixture.text(title)].waitForExistence(timeout: 15), "Wizard did not reach expected step")
    }

    private func chip(_ label: String) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
        XCTAssertEqual(matches.count, 1, "Managed chip label is ambiguous")
        return matches.firstMatch
    }

    private func setChip(_ label: String, selected: Bool) {
        let control = chip(label)
        scrollTo(control)
        XCTAssertTrue(control.exists && control.isHittable, "Managed selection chip is unavailable")
        if control.isSelected != selected { control.tap() }
        let state = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in control.isSelected == selected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: 3), .completed, "Native chip selection did not update")
    }

    private func replace(_ field: XCUIElement, with value: String) {
        scrollTo(field)
        XCTAssertTrue(field.exists && field.isHittable, "Pay field is unavailable")
        let current = field.value as? String ?? ""
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Caregiver pay input did not obtain keyboard focus")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(value)
        let ok = app.toolbars.buttons["OK"]
        if ok.waitForExistence(timeout: 2) { ok.tap() }
        XCTAssertEqual(field.value as? String, value, "Pay field replacement failed")
    }

    private func scrollTo(_ control: XCUIElement) {
        for _ in 0..<16 {
            if control.exists && control.isHittable && control.frame.minY > 90 && control.frame.maxY < app.frame.maxY - 160 { return }
            if control.exists && control.frame.minY < 90 { app.swipeDown(velocity: .slow) }
            else { app.swipeUp(velocity: .slow) }
        }
    }

    private func proof(_ control: XCUIElement, name: String) {
        // Cropped controls contain only managed text/synthetic pay/selection data.
        // Never attach a full tree, user profile, email, password or token.
        let attachment = XCTAttachment(screenshot: control.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertServerUnchanged(_ fixture: Fixture, certificationIds: Set<Int>? = nil, clientTypeIds: Set<Int>? = nil) throws {
        let current = try profile(fixture.token)
        for key in ["salary_min", "salary_max", "experience_id", "role_id", "commute_id", "worktype_id"] {
            XCTAssertEqual(integer(current[key]), integer(fixture.original[key]), "Navigation changed saved caregiver value: \(key)")
        }
        for key in ["clienttype_ids", "carecondition_ids", "carespecial_ids", "certification_ids", "languageskill_ids", "shift_ids", "careday_ids"] {
            let expected = key == "certification_ids" ? (certificationIds ?? Set(ids(fixture.original[key])))
                : key == "clienttype_ids" ? (clientTypeIds ?? Set(ids(fixture.original[key]))) : Set(ids(fixture.original[key]))
            XCTAssertEqual(Set(ids(current[key])), expected, "Saved caregiver selection differs from expected: \(key)")
        }
        for key in ["lat", "lng"] {
            XCTAssertEqual(number(current[key]), number(fixture.original[key]), "Navigation changed saved caregiver coordinate")
        }
        if persistenceBackupURL != nil {
            let changed = try fullProfileDifferences(current, fixture.original, excludingCertifications: true)
            XCTAssertTrue(changed.isEmpty, "Native certification update changed unrelated profile fields: \(changed.joined(separator: ","))")
        }
    }

    private func verifyIdentity(_ fixture: Fixture) throws {
        let user = try CarezaarAPI.me(fixture.token)
        let current = try profile(fixture.token)
        guard fixture.userId == env["QA_CG_ID"], string(user["id"]) == fixture.userId,
              string(user["role"]).lowercased() == "caregiver",
              let owner = current["user"] as? [String: Any], string(owner["id"]) == fixture.userId else {
            XCTFail("Refusing caregiver persistence or restoration after an identity mismatch")
            throw URLError(.userAuthenticationRequired)
        }
    }

    private func restoreOwnedPreferences(_ fixture: Fixture) {
        do {
            try verifyIdentity(fixture)
            // Exact CaregiverService.sharedFields / APK zv.java PUT contract.
            // No client-only fields, account identity fields or unrelated profile fields.
            let form = try preferenceForm(fixture)
            let response = try CarezaarAPI.callWithHTTPStatus("PUT", "caregivers/profile", form: form, token: fixture.token)
            XCTAssertEqual(response.status, 200, "Owned caregiver preference restoration was rejected")
            XCTAssertFalse(CarezaarAPI.result(response.body).isEmpty, "Restoration response has no caregiver profile")
            try assertServerUnchanged(fixture)
            if persistenceBackupURL != nil {
                let restored = try profile(fixture.token)
                let changed = try fullProfileDifferences(restored, fixture.original, excludingCertifications: false)
                guard changed.isEmpty else {
                    try savePersistenceProgress(restored: false, failureKeys: changed)
                    throw NSError(domain: "CaregiverBaselineRestoration", code: 1)
                }
                try savePersistenceProgress(restored: true)
            }
        } catch {
            try? savePersistenceProgress(restored: false, failureKeys: ["restoration-exception"])
            XCTFail("Owned caregiver restoration failed; inspect the retained private baseline before subsequent mutation tests")
        }
    }

    private func preservePersistenceBaseline(_ fixture: Fixture) throws {
        guard let path = env["QA_CAREGIVER_SKILLS_BACKUP_FILE"], path.hasPrefix("/") else {
            throw XCTSkip("Explicit private durable QA_CAREGIVER_SKILLS_BACKUP_FILE required before any native Save")
        }
        let url = URL(fileURLWithPath: path)
        guard !FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "CaregiverBaselineMustNotBeOverwritten", code: 1)
        }
        try verifyIdentity(fixture)
        let current = try profile(fixture.token)
        XCTAssertTrue(try fullProfileDifferences(current, fixture.original, excludingCertifications: false).isEmpty)
        let form = try preferenceForm(fixture) // exact CaregiverService.sharedFields contract
        let record: [String: Any] = ["schemaVersion": 1, "ownedCaregiverUserID": fixture.userId,
            "fullProfile": fixture.original, "officialServiceFields": form,
            "endpoint": "PUT caregivers/profile", "passwordsOrAuthTokensIncluded": false]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        persistenceBackupURL = url
        try savePersistenceProgress(restored: true)
    }

    private func fullProfileDifferences(_ current: [String: Any], _ baseline: [String: Any],
                                        excludingCertifications: Bool) throws -> [String] {
        var different: [String] = []
        for key in Set(current.keys).union(baseline.keys).sorted() {
            if excludingCertifications && key == "certification_ids" { continue }
            if current[key] == nil || baseline[key] == nil { different.append(key); continue }
            func canonical(_ row: [String: Any]) throws -> Data {
                let value: Any = key.hasSuffix("_ids") ? ids(row[key]).sorted() : (row[key] ?? NSNull())
                return try JSONSerialization.data(withJSONObject: ["value": value], options: [.sortedKeys])
            }
            if try canonical(current) != canonical(baseline) { different.append(key) }
        }
        return different
    }

    private func savePersistenceProgress(restored: Bool, failureKeys: [String] = []) throws {
        guard let backup = persistenceBackupURL else { return }
        let record: [String: Any] = ["nativeSavedReopenedStates": persistenceStages,
            "fullProfileRestoredAndVerified": restored, "failureKeys": failureKeys,
            "unrelatedFieldsCompared": "all top-level and nested user fields; selection arrays sorted without dropping duplicates",
            "officialServiceRestore": "PUT caregivers/profile (all15sharedFields)"]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
        let url = backup.appendingPathExtension("progress.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func profile(_ token: String) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "caregivers/profile", token: token)
        XCTAssertEqual(response.status, 200, "Caregiver profile read failed")
        let result = CarezaarAPI.result(response.body)
        XCTAssertFalse(result.isEmpty, "Caregiver profile response is empty")
        return result
    }

    private func catalogue(_ name: String, token: String) throws -> [[String: Any]] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "base/\(name)?ts_cache=0", token: token)
        XCTAssertEqual(response.status, 200, "Live reference read failed")
        return try XCTUnwrap(response.body["result"] as? [[String: Any]], "Live reference catalogue is malformed")
    }

    private func english(_ row: [String: Any]) -> String? {
        (row["translations"] as? [[String: Any]])?.first(where: { integer($0["language_id"]) == 1 })?["name"] as? String
    }

    private func items(_ name: String, token: String) throws -> [Item] {
        let result = try catalogue(name, token: token).compactMap { row -> Item? in
            guard let id = integer(row["id"]), let label = english(row), !label.isEmpty else { return nil }
            return Item(id: id, label: label)
        }.sorted { $0.id < $1.id }
        XCTAssertEqual(Set(result.map(\.id)).count, result.count, "Live reference ids are duplicated")
        XCTAssertEqual(Set(result.map(\.label)).count, result.count, "Live reference labels need a scoped selector")
        return result
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        return (value as? String).flatMap(Double.init)
    }

    private func ids(_ value: Any?) -> [Int] {
        (value as? [Any] ?? []).compactMap(integer)
    }

    private func string(_ value: Any?) -> String { value.map { String(describing: $0) } ?? "" }
}
