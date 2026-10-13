import XCTest
import CryptoKit

/// Controlled Debug location inputs, never physical GPS or OS permission proof.
/// Real owned profile GETs provide the other required wizard fields; no location
/// or preference mutations are authorized by these read-only boundary tests.
final class LocationBoundaryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var openingProfileReads = 0
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private struct Fixture {
        let token: String, role: String, id: String, endpoint: String, route: String
        let original: [String: Any], labels: [String: String]
        func text(_ key: String) throws -> String {
            guard let value = labels[key], !value.isEmpty else { throw URLError(.cannotParseResponse) }
            return value
        }
    }
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() { app?.terminate(); super.tearDown() }

    func testControlledCachedPhoneInitializesWizardWithoutOpeningMap() throws {
        let f = try fixture()
        try launchSchedule(f, mode: "available")
        try requireLocationEvent(mode: "available", phase: "cached", accepted: true, stale: false)
        let coordinate = "39.828300 , -98.579500"
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", coordinate)).firstMatch
        try reveal(row); XCTAssertTrue(row.exists)
        XCTAssertFalse(app.maps.firstMatch.exists, "Wizard initialization must not need map interaction")
        proof(row, name: "P03-021-controlled-cached-coordinate-only")
        try advance(f, step: 3)
        let value = app.staticTexts[coordinate].firstMatch
        try reveal(value); XCTAssertTrue(value.exists)
        proof(value, name: "P03-021-controlled-review-coordinate-only")
        try assertBackendUnchanged(f)
        try record("P03-021-controlled-cached-native", ["role": f.role, "mapOpened": false, "reviewRetainsExactControlledFix": true, "cachedPublisherAttested": true])
    }

    func testStaleCachedLocationIsUsedSilentlyInWizardAndMap() throws {
        let f = try fixture()
        try launchSchedule(f, mode: "stale")
        try requireLocationEvent(mode: "stale", phase: "cached", accepted: true, stale: true)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "39.828300 , -98.579500")).firstMatch
        try reveal(row)
        XCTAssertFalse(app.staticTexts["Last known location"].exists,
                       "Oct13 R15: last-known location must initialize silently")
        row.tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Last known location"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Location is unavailable.")).firstMatch.exists)
        XCTAssertTrue((try visibleButton(try f.text("general_confirm"))).isEnabled)
        try tapVisibleMapBack()
        try assertBackendUnchanged(f)
        try record("R15-controlled-stale-silent-native", ["role": f.role,
            "cachedCoordinateRetained": true, "wizardAndMapNoticesAbsent": true, "profileMutations": 0])
    }

    func testControlledNoFixMapContinuesSilentlyAndFinalSaveOffersMapWithoutWrites() throws {
        let f = try fixture()
        try launchSchedule(f, mode: "none")
        try requireLocationEvent(mode: "none", phase: "delivery", accepted: false, stale: false)
        try openNoFixMap(f)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", try f.text("general_confirm")))
            .allElementsBoundByIndex.contains { $0.exists && $0.isHittable })
        let mapContinue = try visibleButton(try f.text("general_continue"))
        XCTAssertTrue(mapContinue.isEnabled)
        proof(mapContinue, name: "P03-026-controlled-unselected-map-continue-only")
        mapContinue.tap()
        XCTAssertTrue(app.maps.firstMatch.waitForNonExistence(timeout: 10))
        try assertScheduleNil(f)
        try openNoFixMap(f)
        XCTAssertTrue((try visibleButton(try f.text("general_continue"))).isEnabled,
                      "Reopened automatic viewport must still have no selected point")
        try tapVisibleMapBack()
        try advance(f, step: 3)
        try assertReviewNil(f)
        XCTAssertEqual(try profileMutationCount(), 0)
        let save = try visibleButton(try f.text("general_save"))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10), "No-fix Save must offer actual manual map selection")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Location is unavailable.")).firstMatch.exists)
        XCTAssertTrue((try visibleButton(try f.text("general_continue"))).isEnabled)
        XCTAssertEqual(try profileMutationCount(), 0)
        try tapVisibleMapBack()
        try assertReviewNil(f)
        let reviewBack = try visibleButton("Back")
        reviewBack.tap()
        let scheduleKey = f.role == "client" ? "signup_form_client_schedule_preferences" : "signup_form_caregiver_schedule_title"
        XCTAssertTrue(app.staticTexts[try f.text(scheduleKey)].waitForExistence(timeout: 10))
        try openNoFixMap(f)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Location is unavailable.")).firstMatch.exists)
        XCTAssertTrue((try visibleButton(try f.text("general_continue"))).isEnabled)
        XCTAssertEqual(try profileMutationCount(), 0)
        try tapVisibleMapBack()
        try assertScheduleNil(f)
        try assertBackendUnchanged(f)
        try record("P03-023-024-026-controlled-no-fix-native", ["role": f.role,
            "scheduleContinuedWithoutLocation": true, "automaticMapViewportNeverSelected": true,
            "mapReopenedUnselected": true, "reviewLocationNil": true, "finalSaveMapOfferedWithoutNotices": true,
            "manualMapOfferedAfterSave": true, "ordinaryReopenRemainsSilent": true,
            "englishOnlyNoticesAbsent": true, "actualBackendCoordinateRequirementTested": false])
    }

    func testControlledInvalidAccuracyRangeAndFutureFixNeverBecomeSelections() throws {
        let f = try fixture()
        for mode in ["negative-accuracy", "out-of-range", "future"] {
            try launchSchedule(f, mode: mode)
            try requireLocationEvent(mode: mode, phase: "delivery", accepted: false, stale: false)
            try assertScheduleNil(f)
            try openNoFixMap(f)
            XCTAssertTrue((try visibleButton(try f.text("general_continue"))).isEnabled)
            try tapVisibleMapBack()
            try advance(f, step: 3)
            try assertReviewNil(f)
            try assertBackendUnchanged(f)
            try record("P03-025-controlled-\(mode)-native", ["role": f.role, "invalidFixRejectedByRealFilter": true,
                "wizardLocationNil": true, "mapUnselected": true, "reviewLocationNil": true])
        }
    }

    func testControlledManualMapChoiceSurvivesActualLaterPhoneFixWithoutSaving() throws {
        let f = try fixture()
        try launchSchedule(f, mode: "late-valid")
        try requireLocationEvent(mode: "late-valid", phase: "waiting-manual", accepted: false, stale: false)
        try openNoFixMap(f)
        let map = app.maps.firstMatch
        XCTAssertTrue(map.exists && map.isHittable)
        // Inset points come from the observed native map, away from header/footer controls.
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.1)
        let events = app.staticTexts["qa-location-fixture"]
        let delivered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            events.exists && self.manualDeliveryProof(events.label) != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [delivered], timeout: 15), .completed,
                       "Same map provider must attest actual manual selection followed by actual late publisher delivery")
        let causal = try XCTUnwrap(manualDeliveryProof(events.label))
        let confirm = try visibleButton(try f.text("general_confirm"))
        XCTAssertTrue(confirm.isEnabled)
        proof(confirm, name: "P03-027-controlled-late-fix-manual-confirm-only")
        confirm.tap()
        XCTAssertTrue(app.maps.firstMatch.waitForNonExistence(timeout: 10))
        let row = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*-?[0-9]+\\.[0-9]{6} , -?[0-9]+\\.[0-9]{6}.*")).firstMatch
        try reveal(row)
        let pattern = "-?[0-9]+\\.[0-9]{6} , -?[0-9]+\\.[0-9]{6}"
        let range = try XCTUnwrap(row.label.range(of: pattern, options: .regularExpression))
        let selected = String(row.label[range])
        let digest = SHA256.hash(data: Data(selected.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, causal.digest,
                       "Native confirmed row must retain exactly the manually selected center across late phone delivery")
        XCTAssertNotEqual(selected, "39.828300 , -98.579500", "Manual choice must not become the later controlled phone fix")
        proof(row, name: "P03-027-controlled-manual-coordinate-row-only")
        try advance(f, step: 3)
        let review = app.staticTexts.matching(NSPredicate(format: "label == %@", selected)).firstMatch
        try reveal(review)
        proof(review, name: "P03-027-controlled-manual-review-coordinate-only")
        try assertBackendUnchanged(f)
        try record("P03-027-controlled-map-manual-late-native", ["role": f.role,
            "sameProviderManualThenActualLateDelivery": true, "manualCount": causal.count,
            "nativeConfirmedAndReviewDigestMatchesManualChoice": true, "validSaveAttempted": false,
            "postReturnWizardLaterFixTested": false])
    }

    private func manualDeliveryProof(_ history: String) -> (digest: String, count: Int)? {
        let rows = history.split(separator: "\n").map { line -> [String: String] in
            var fields: [String: String] = [:]
            for item in line.split(separator: " ") {
                let pieces = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if pieces.count == 2 { fields[String(pieces[0])] = String(pieces[1]) }
            }
            return fields
        }
        guard let late = rows.last(where: { $0["mode"] == "late-valid" && $0["phase"] == "late-after-manual" }),
              late["accepted"] == "true", late["stale"] == "false",
              let provider = late["provider"], let digest = late["selectedDigest"],
              digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let countText = late["manualCount"], let count = Int(countText), count > 0,
              let panIndex = rows.firstIndex(where: { $0["provider"] == provider && $0["phase"] == "manual-pan" }),
              let lateIndex = rows.lastIndex(where: { $0["provider"] == provider && $0["phase"] == "late-after-manual" }), panIndex < lateIndex,
              let position = rows.last(where: { $0["provider"] == provider && $0["phase"] == "manual-position" }),
              position["selectedDigest"] == digest, position["manualCount"] == countText else { return nil }
        return (digest, count)
    }

    private func launchSchedule(_ f: Fixture, mode: String) throws {
        app.terminate()
        app.launchEnvironment = ["QA_EMAIL": env["QA_EMAIL"]!, "QA_PASSWORD": env["QA_PASSWORD"]!,
            "QA_CLIENT_USER_ID": env["QA_CLIENT_USER_ID"]!, "QA_CG_ID": env["QA_CG_ID"]!]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", f.route,
            "--qa-location-fixture", mode, "--qa-owned-profile-no-location", "GET", f.endpoint,
            "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let attestation = app.staticTexts["qa-profile-no-location"]
        XCTAssertTrue(attestation.waitForExistence(timeout: 60))
        XCTAssertEqual(attestation.label, "path=\(f.endpoint) owned=true latitude=nil longitude=nil")
        let busy = app.staticTexts[try f.text("loading_please_wait")]
        let profileBusy = app.staticTexts[try f.text("loading_profile_get")]
        let headingKey = f.role == "client" ? "signup_form_client_select_care_type" : "signup_form_caregiver_supported_client_types_title"
        let heading = app.staticTexts[try f.text(headingKey)]
        let next = app.buttons[try f.text("signup_form_client_continue")].firstMatch
        let prefilled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            heading.exists && next.exists && next.isHittable && next.isEnabled
                && !busy.exists && !profileBusy.exists
                && self.app.buttons.allElementsBoundByIndex.contains { $0.exists && $0.isSelected }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [prefilled], timeout: 30), .completed,
                       "Actual wizard care-type selection must be prefilled and loading finished before Continue")
        openingProfileReads = try ledger()["GET /api/" + f.endpoint] ?? 0
        XCTAssertGreaterThanOrEqual(openingProfileReads, 1,
            "Actual owned profile read is required; Main Matches and wizard may independently fetch it")
        try record("controlled-location-opening-\(mode)-native", ["role": f.role,
            "wizardHeadingObserved": true, "actualPrefilledCareTypeSelected": true,
            "loadingFinishedBeforeContinue": true])
        try advance(f, step: 1)
        try advance(f, step: 2)
        XCTAssertEqual(try profileMutationCount(), 0)
    }
    private func requireLocationEvent(mode: String, phase: String, accepted: Bool, stale: Bool) throws {
        let label = app.staticTexts["qa-location-fixture"]
        let expected = "mode=\(mode) phase=\(phase) accepted=\(accepted) stale=\(stale)"
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            label.exists && label.label.contains(expected)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: 15), .completed,
                       "Actual synthetic publisher/filter delivery attestation required")
        guard label.exists, label.label.contains(expected) else { throw URLError(.cannotParseResponse) }
    }
    private func visibleButton(_ label: String) throws -> XCUIElement {
        let candidates = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            candidates.allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        return try XCTUnwrap(candidates.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            .max(by: { $0.frame.midY < $1.frame.midY }))
    }
    private func assertScheduleNil(_ f: Fixture) throws {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", try f.text("signup_form_client_location_hint"))).firstMatch
        try reveal(row); XCTAssertTrue(row.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Location is unavailable.")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Last known location"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*-?[0-9]+\\.[0-9]{6} , -?[0-9]+\\.[0-9]{6}.*")).count, 0)
    }
    private func openNoFixMap(_ f: Fixture) throws {
        try assertScheduleNil(f)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", try f.text("signup_form_client_location_hint"))).firstMatch
        try reveal(row); row.tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue((try visibleButton(try f.text("general_continue"))).isEnabled)
    }
    private func tapVisibleMapBack() throws {
        let back = try visibleButton("Back")
        back.tap(); XCTAssertTrue(app.maps.firstMatch.waitForNonExistence(timeout: 10))
    }
    private func assertReviewNil(_ f: Fixture) throws {
        let title = app.staticTexts[try f.text("signup_form_client_location")].firstMatch
        try reveal(title)
        let view = try XCTUnwrap(app.scrollViews.allElementsBoundByIndex
            .filter { $0.exists && $0.frame.width > app.frame.width * 0.5 && $0.frame.height > 60 }
            .max(by: { $0.frame.height < $1.frame.height }))
        let save = try visibleButton(try f.text("general_save"))
        var visibleValue: XCUIElement?
        for upward in [true, false] {
            for _ in 0..<24 {
                if title.exists {
                    let adjacent = app.staticTexts.matching(NSPredicate(format: "label == %@", "—"))
                        .allElementsBoundByIndex.filter {
                            $0.exists && $0.frame.minY >= title.frame.maxY
                                && $0.frame.minY - title.frame.maxY < 80
                        }.min(by: { $0.frame.minY < $1.frame.minY })
                    if let value = adjacent, title.isHittable, value.isHittable,
                       view.frame.contains(title.frame), view.frame.contains(value.frame),
                       title.frame.maxY <= save.frame.minY, value.frame.maxY <= save.frame.minY {
                        visibleValue = value; break
                    }
                }
                // Revealing the heading alone can leave its value beneath the
                // observed Save footer. Reveal both actual native texts together.
                view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.75 : 0.25))
                    .press(forDuration: 0.1, thenDragTo: view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.25 : 0.75)), withVelocity: .slow, thenHoldForDuration: 0.1)
            }
            if visibleValue != nil { break }
        }
        if visibleValue == nil {
            try record("controlled-location-empty-review-visibility-failure", ["role": f.role,
                "locationHeadingExists": title.exists, "locationHeadingHittable": title.exists && title.isHittable,
                "locationHeadingMinY": title.exists ? title.frame.minY : -1,
                "emptyValueCount": app.staticTexts.matching(NSPredicate(format: "label == %@", "—")).count,
                "scrollMinY": view.frame.minY, "scrollMaxY": view.frame.maxY, "saveFooterMinY": save.frame.minY])
        }
        let value = try XCTUnwrap(visibleValue, "Actual adjacent Location emdash must be fully visible above Save footer")
        XCTAssertEqual(value.label, "—")
        XCTAssertLessThan(value.frame.minY - title.frame.maxY, 80, "Observed adjacent Location review value must be empty")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "-?[0-9]+\\.[0-9]{6} , -?[0-9]+\\.[0-9]{6}")).count, 0)
        proof(value, name: "controlled-location-empty-review-value-only")
    }

    private func fixture() throws -> Fixture {
        guard let email = env["QA_EMAIL"], !email.isEmpty,
              let password = env["QA_PASSWORD"], !password.isEmpty,
              let clientID = env["QA_CLIENT_USER_ID"], !clientID.isEmpty,
              let caregiverID = env["QA_CG_ID"], !caregiverID.isEmpty, clientID != caregiverID else {
            throw XCTSkip("Exact retained owned identity and distinct opaque pair IDs required")
        }
        let token = try CarezaarAPI.login(email, password)
        guard !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let me = try CarezaarAPI.me(token)
        let role = me["role"] as? String ?? "", id = me["id"].map { String(describing: $0) } ?? ""
        guard me["email"] as? String == email,
              (role == "client" && id == clientID) || (role == "caregiver" && id == caregiverID) else {
            XCTFail("Exact owned primary ID, role and credential binding required")
            throw URLError(.userAuthenticationRequired)
        }
        let endpoint = role == "client" ? "clients/profile" : "caregivers/profile"
        let original = try profile(endpoint, token: token, expectedID: id)
        let arrays = ["carecondition_ids", "carespecial_ids", "languageskill_ids", "shift_ids", "careday_ids"]
            + (role == "client" ? ["experience_ids", "role_ids", "commute_ids", "worktype_ids", "gender_ids"] : ["clienttype_ids"])
        let scalars = role == "client" ? ["clienttype_id"] : ["experience_id", "role_id", "commute_id", "worktype_id", "salary_min", "salary_max"]
        guard arrays.allSatisfy({ !(original[$0] as? [Any] ?? []).isEmpty }),
              scalars.allSatisfy({ original[$0] != nil && !(original[$0] is NSNull) }) else {
            throw XCTSkip("Owned real saved fixture lacks required wizard fields; this test never stages them")
        }
        let contents = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: token)
        guard contents.status == 200, let rows = contents.body["result"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        var labels: [String: String] = [:]
        for row in rows {
            if let key = row["slug"] as? String, let translations = row["translations"] as? [[String: Any]],
               let value = translations.first(where: { $0["language_id"] as? Int == 1 })?["name"] as? String {
                labels[key] = value
            }
        }
        return Fixture(token: token, role: role, id: id, endpoint: endpoint,
                       route: role == "client" ? "ClientPreferences" : "CaregiverSkills", original: original, labels: labels)
    }
    private func profile(_ endpoint: String, token: String, expectedID: String) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", endpoint, token: token)
        guard response.status == 200, let result = response.body["result"] as? [String: Any],
              let user = result["user"] as? [String: Any],
              user["id"].map({ String(describing: $0) }) == expectedID else { throw URLError(.cannotParseResponse) }
        return result
    }
    private func assertBackendUnchanged(_ f: Fixture) throws {
        let after = try profile(f.endpoint, token: f.token, expectedID: f.id)
        let keys = ["lat", "lng", "clienttype_id", "clienttype_ids", "carecondition_ids", "carespecial_ids", "experience_id", "experience_ids", "role_id", "role_ids", "certification_ids", "languageskill_ids", "commute_id", "commute_ids", "shift_ids", "careday_ids", "worktype_id", "worktype_ids", "gender_ids", "salary_min", "salary_max"]
        for key in keys {
            let old = f.original[key] ?? NSNull(), new = after[key] ?? NSNull()
            let oldData = try JSONSerialization.data(withJSONObject: [old], options: [.sortedKeys])
            let newData = try JSONSerialization.data(withJSONObject: [new], options: [.sortedKeys])
            XCTAssertEqual(newData, oldData, "Read-only native location flow must preserve server preference field: \(key)")
        }
        XCTAssertEqual(try profileMutationCount(), 0)
    }
    private func ledger() throws -> [String: Int] {
        let element = app.staticTexts["qa-request-counts"]
        guard element.exists, !element.label.isEmpty else { throw URLError(.cannotParseResponse) }
        var values: [String: Int] = [:]
        for line in element.label.split(separator: "\n") {
            guard let equals = line.lastIndex(of: "="), let count = Int(line[line.index(after: equals)...]) else { throw URLError(.cannotParseResponse) }
            values[String(line[..<equals])] = count
        }
        return values
    }
    private func profileMutationCount() throws -> Int {
        try ledger().filter { entry in
            ["POST", "PUT", "PATCH", "DELETE"].contains { verb in
                ["/api/clients", "/api/caregivers"].contains { path in
                    entry.key == verb + " " + path || entry.key == verb + " " + path + "/profile"
                }
            }
        }.values.reduce(0, +)
    }
    private func advance(_ f: Fixture, step: Int) throws {
        let button = app.buttons[try f.text("signup_form_client_continue")].firstMatch
        XCTAssertTrue(button.exists && button.isHittable && button.isEnabled)
        button.tap()
        let keys = f.role == "client"
            ? ["signup_form_client_tell_us_about_needs", "signup_form_client_schedule_preferences", "signup_form_client_review"]
            : ["signup_form_caregiver_skill_title", "signup_form_caregiver_schedule_title", "signup_form_caregiver_review_title"]
        XCTAssertTrue(app.staticTexts[try f.text(keys[step - 1])].waitForExistence(timeout: 15))
    }
    private func reveal(_ element: XCUIElement) throws {
        let views = app.scrollViews.allElementsBoundByIndex.filter { $0.exists && $0.frame.width > app.frame.width * 0.5 && $0.frame.height > 60 }
        let view = try XCTUnwrap(views.max(by: { $0.frame.height < $1.frame.height }))
        for upward in [true, false] {
            for _ in 0..<24 {
                if element.exists && element.isHittable && view.frame.contains(element.frame) { return }
                view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.75 : 0.25))
                    .press(forDuration: 0.1, thenDragTo: view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.25 : 0.75)), withVelocity: .slow, thenHoldForDuration: 0.1)
            }
        }
        XCTAssertTrue(element.exists && element.isHittable && view.frame.contains(element.frame))
        guard element.exists && element.isHittable && view.frame.contains(element.frame) else { throw URLError(.cannotParseResponse) }
    }
    private func proof(_ element: XCUIElement, name: String) {
        XCTAssertTrue(element.exists && element.isHittable)
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func record(_ name: String, _ outcomes: [String: Any]) throws {
        var values = outcomes
        values["controlledDebugLocationOnly"] = true; values["physicalGPSVerified"] = false
        values["OSLocationPermissionVerified"] = false; values["profileMutationRequests"] = try profileMutationCount()
        values["actualOpeningOwnedProfileGETs"] = openingProfileReads
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
