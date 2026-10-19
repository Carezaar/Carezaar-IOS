import XCTest
import Foundation

/// P16-001–004 (client) / P16-008–011 (caregiver), rendering portions only.
/// Root dispatches sequentially with the exact retained owned pair initially NONE.
/// API staging is confined to that pair; no chat send, profile/media or account writes.
final class MatchStateMatrixUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private let marker = "Synthetic state rendering " + UUID().uuidString
    private var cleanupFixture: Fixture?

    private struct Fixture {
        let primaryToken: String, peerToken: String
        let role: String, primaryID: String, peerID: String, peerName: String
        let labels: [String: String]
        var profileEndpoint: String { "\(role == "client" ? "clients/caregivers" : "caregivers/clients")/\(peerID)" }
        var peerEndpoint: String { "\(role == "client" ? "caregivers/clients" : "clients/caregivers")/\(primaryID)" }
        var listEndpoint: String { "\(role == "client" ? "clients" : "caregivers")/matches" }
        func label(_ slug: String, _ fallback: String) -> String {
            guard let value = labels[slug], !value.isEmpty else { return fallback }; return value
        }
    }

    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() {
        app?.terminate()
        if let fixture = cleanupFixture {
            do { try restoreNone(fixture) }
            catch { XCTFail("Owned matrix cleanup failed; preserve diagnostics and inspect retained pair before another run") }
        }
        super.tearDown()
    }

    func testExactOwnedPairCardsAndProfileActionsAcrossNoneSentReceivedActive() throws {
        let f = try preflight()
        let initial = try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)
        let initialPeer = try profile(f.peerEndpoint, token: f.peerToken, expectedUser: f.primaryID)
        guard initial["match_status"] as? String == "none", initialPeer["match_status"] as? String == "none" else {
            throw XCTSkip("Owned pair is not NONE; refusing to disturb another active/requested relationship")
        }
        XCTAssertEqual(try pairStatus(f), "none")
        cleanupFixture = f
        try render("none", fixture: f)

        _ = try createRequest(f, fromPrimary: true)
        XCTAssertEqual(try pairStatus(f), "sent")
        try render("sent", fixture: f)
        try restoreNone(f)

        _ = try createRequest(f, fromPrimary: false)
        XCTAssertEqual(try pairStatus(f), "received")
        try render("received", fixture: f)
        try restoreNone(f) // peer withdraws its own staged incoming request

        let activeID = try createRequest(f, fromPrimary: true)
        _ = try ownedEdge(activeID, fixture: f)
        let accepted = try CarezaarAPI.callWithHTTPStatus("PATCH", "users/matches/\(activeID)/accept", token: f.peerToken)
        XCTAssertTrue((200..<300).contains(accepted.status), "Owned peer acceptance must succeed")
        XCTAssertEqual(try pairStatus(f), "active")
        try render("active", fixture: f)
        try restoreNone(f) // primary unmatches only the exact marker-owned edge
        XCTAssertEqual(try pairStatus(f), "none")
        cleanupFixture = nil
        try record("matrix-owned-none-restored", ["role": f.role, "finalPairState": "none", "stagesRendered": 4,
            "chatSendCovered": false, "confirmationCovered": false, "greenRasterReviewRequired": true])
    }

    /// Bounded Small exposure proof only; never touches deletion inputs/actions.
    func testSmallDeletionFinalLossRowFullyExposesAboveFooterWithoutSubmission() throws {
        let f = try preflight()
        guard let folder = env["QA_SHOT_DIR"], folder.hasPrefix("/") else {
            throw XCTSkip("Explicit private raster folder required")
        }
        let text = try XCTUnwrap(f.labels["delete_account_data_settings"])
        XCTAssertFalse(text.isEmpty)
        launchOwnedRoute("DeleteAccount")
        XCTAssertTrue(app.navigationBars["Delete Account"].waitForExistence(timeout: 60))
        XCTAssertLessThanOrEqual(app.frame.width, 400, "This allocation must use the actual Small viewport")
        XCTAssertLessThanOrEqual(app.frame.height, 700)
        let scroll = app.scrollViews.firstMatch
        let footer = app.buttons[f.label("delete_account_action_delete", "Delete Account")].firstMatch
        XCTAssertTrue(scroll.exists && footer.waitForExistence(timeout: 15))
        XCTAssertFalse(footer.isEnabled, "No reason/acknowledgment was provided; deletion must remain disabled")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.app.staticTexts["Please wait..."].exists && footer.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 45), .completed)
        let target = app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
        func frame(_ rect: CGRect) -> [Double] {
            [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
        }
        func safeViewport() -> CGRect {
            let navigation = app.navigationBars.firstMatch
            let top = max(scroll.frame.minY, navigation.frame.maxY + 4)
            let bottom = min(scroll.frame.maxY, footer.frame.minY - 8)
            return CGRect(x: scroll.frame.minX + 1, y: top,
                          width: scroll.frame.width - 2, height: max(0, bottom - top))
        }
        func save(_ name: String) throws {
            let screenshot = app.screenshot()
            let proof = XCTAttachment(screenshot: screenshot)
            proof.name = "small-deletion-\(f.role)-\(name)"; proof.lifetime = .keepAlways; add(proof)
            let url = URL(fileURLWithPath: folder).appendingPathComponent("small-deletion-\(f.role)-\(name).png")
            try screenshot.pngRepresentation.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let initial: [String: Any] = ["targetExists": target.exists,
            "targetFrame": target.exists ? frame(target.frame) : [0.0, 0.0, 0.0, 0.0], "footerFrame": frame(footer.frame),
            "safeViewport": frame(safeViewport()), "targetHittable": target.exists && target.isHittable]
        try save("before-scroll")
        var drags = 0
        for _ in 0..<12 {
            let safe = safeViewport()
            if target.exists && target.isHittable && safe.contains(target.frame) { break }
            XCTAssertGreaterThan(safe.height, 60)
            let upward = !target.exists || target.frame.maxY > safe.maxY
            let fromY = safe.minY + safe.height * (upward ? 0.75 : 0.25)
            let toY = safe.minY + safe.height * (upward ? 0.25 : 0.75)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: safe.midX, dy: fromY)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: safe.midX, dy: toY)))
            drags += 1
        }
        XCTAssertTrue(target.exists && target.isHittable)
        XCTAssertEqual(target.label, text, "Complete managed final loss label must remain available")
        XCTAssertTrue(safeViewport().contains(target.frame), "Complete final loss label must be above the actual fixed footer")
        XCTAssertFalse(footer.isEnabled)
        XCTAssertTrue(app.staticTexts["qa-request-counts"].exists)
        let deleteRequests = app.staticTexts["qa-request-counts"].label.split(separator: "\n")
            .filter { $0.hasPrefix("DELETE /api/") }
            .compactMap { Int($0.split(separator: "=").last ?? "") }.reduce(0, +)
        XCTAssertEqual(deleteRequests, 0, "Exposure navigation must never attempt deletion")
        try save("fully-exposed")
        let evidence: [String: Any] = ["role": f.role, "viewportPoints": frame(app.frame),
            "managedTarget": text, "before": initial, "afterTargetFrame": frame(target.frame),
            "afterFooterFrame": frame(footer.frame), "afterSafeViewport": frame(safeViewport()),
            "nativeScrollDrags": drags, "completeLabelFullyAboveFooter": true,
            "deleteRemainedDisabled": true, "nativeDELETERequests": deleteRequests,
            "reasonAndAcknowledgmentNeverChanged": true, "sourceOrAuditFiltering": false]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        let url = URL(fileURLWithPath: folder).appendingPathComponent("small-deletion-\(f.role)-exposure.json")
        try data.write(to: url, options: .atomic)
        let proof = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        proof.name = "small-deletion-final-label-exposure-\(f.role)"; proof.lifetime = .keepAlways; add(proof)
    }

    /// Separate diagnostic: actual OS font category is set/read/restored by root.
    /// Never taps a notification; the unchanged strict audit remains authoritative.
    func testExactLowerNotificationLabelsScaleAndRemainExposedWithoutOpening() throws {
        let f = try preflight()
        guard let phase = env["QA_NOTIFICATION_FONT_PHASE"], ["large", "a5"].contains(phase),
              let baselinePath = env["QA_NOTIFICATION_FONT_BASELINE_FILE"], baselinePath.hasPrefix("/"),
              let folder = env["QA_SHOT_DIR"], folder.hasPrefix("/") else {
            throw XCTSkip("Explicit phase, private baseline file and raster folder required")
        }
        let baselineURL = URL(fileURLWithPath: baselinePath)
        var baselineRows: [[String: Any]] = []
        if phase == "a5" {
            let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: baselineURL)) as? [String: Any])
            XCTAssertEqual(baseline["role"] as? String, f.role)
            XCTAssertEqual(baseline["owner"] as? String, f.primaryID)
            baselineRows = try XCTUnwrap(baseline["rows"] as? [[String: Any]])
        }
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/notifications?page=1&perPage=10", token: f.primaryToken)
        XCTAssertEqual(response.status, 200)
        let rows = try XCTUnwrap(response.body["result"] as? [[String: Any]])
        let ids: [Int]
        if phase == "large" {
            ids = rows.prefix(8).dropFirst(4).compactMap { ($0["id"] as? NSNumber)?.intValue }
            guard ids.count == 4 else { throw XCTSkip("Four existing lower first-page owned notifications required; no data seeded") }
        } else {
            ids = try baselineRows.map { try XCTUnwrap(($0["id"] as? NSNumber)?.intValue) }
            let available = Set(rows.compactMap { ($0["id"] as? NSNumber)?.intValue })
            XCTAssertTrue(ids.allSatisfy { available.contains($0) }, "Exact baseline notifications must remain in native first page")
        }
        launchOwnedRoute("Notifications")
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "notification-row-")).firstMatch.waitForExistence(timeout: 30))
        let initialRaster = XCTAttachment(screenshot: app.screenshot())
        initialRaster.name = "notification-font-initial-viewport-\(phase)"
        initialRaster.lifetime = .keepAlways; add(initialRaster)
        let initialHierarchy = XCTAttachment(string: app.debugDescription)
        initialHierarchy.name = "notification-font-initial-hierarchy-\(phase)"
        initialHierarchy.lifetime = .keepAlways; add(initialHierarchy)
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        func expose(_ element: XCUIElement) throws {
            for _ in 0..<24 {
                let viewport = scroll.frame.intersection(app.frame).insetBy(dx: 1, dy: 8)
                if element.exists && element.isHittable && viewport.contains(element.frame) { return }
                if element.exists && element.frame.minY < viewport.minY { scroll.swipeDown(velocity: .slow) }
                else { scroll.swipeUp(velocity: .slow) }
            }
            XCTFail("Exact notification text must become fully exposed within the actual scroll viewport")
            throw NSError(domain: "NotificationFontExposure", code: 1)
        }
        var results: [[String: Any]] = []
        for (index, id) in ids.enumerated() {
            let row = app.buttons.matching(identifier: "notification-row-\(id)").firstMatch
            // Offscreen lower rows can be absent from UIKit's AX snapshot at A5.
            // Scroll the exact existing ID into the tree; do not fabricate a row.
            for _ in 0..<24 where !row.exists { scroll.swipeUp(velocity: .slow) }
            XCTAssertTrue(row.exists, "Exact existing notification must become materialized after bounded native scrolling")
            let initialLabels = row.staticTexts.allElementsBoundByIndex.map(\.label)
            let labels = Array(Set(initialLabels)).sorted()
            XCTAssertEqual(labels.count, 3, "Expected complete partner, event and timestamp text nodes")
            if phase == "a5" {
                let previous = try XCTUnwrap(baselineRows[index]["labels"] as? [[String: Any]])
                XCTAssertEqual(Set(labels), Set(previous.compactMap { $0["text"] as? String }), "Exact managed/name/timestamp text must survive actual OS scaling")
            }
            var measurements: [[String: Any]] = []
            for (labelIndex, text) in labels.enumerated() {
                let element = row.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
                try expose(element)
                XCTAssertEqual(element.label, text)
                let frame = element.frame
                XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
                if phase == "a5" {
                    let previous = try XCTUnwrap(baselineRows[index]["labels"] as? [[String: Any]])
                    let old = try XCTUnwrap(previous.first { $0["text"] as? String == text })
                    XCTAssertGreaterThan(Double(frame.height), try XCTUnwrap(old["height"] as? Double), "Actual OS A5 must enlarge the same text's rendered frame")
                }
                let shot = element.screenshot()
                let name = "notification-font-\(phase)-row-\(index + 1)-text-\(labelIndex + 1)"
                let proof = XCTAttachment(screenshot: shot); proof.name = name; proof.lifetime = .keepAlways; add(proof)
                let file = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
                try shot.pngRepresentation.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                measurements.append(["text": text, "x": Double(frame.minX), "y": Double(frame.minY),
                    "width": Double(frame.width), "height": Double(frame.height), "fullyExposed": true,
                    "viewport": [Double(scroll.frame.minX), Double(scroll.frame.minY), Double(scroll.frame.width), Double(scroll.frame.height)]])
            }
            results.append(["id": id, "labels": measurements])
        }
        XCTAssertEqual(totalMutationCount(method: "POST"), 0)
        XCTAssertEqual(totalMutationCount(method: "PATCH"), 0)
        XCTAssertEqual(totalMutationCount(method: "DELETE"), 0)
        for id in ids { XCTAssertEqual(count("PATCH /api/users/notifications/\(id)/see"), 0) }
        let record: [String: Any] = ["role": f.role, "owner": f.primaryID, "phase": phase,
            "rows": results, "notificationTaps": 0, "actualOSReadbackRequired": true,
            "strictAccessibilityAuditUnchanged": true]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
        let output = phase == "large" ? baselineURL : URL(fileURLWithPath: folder).appendingPathComponent("a5-exact-notification-measurements-private.json")
        try data.write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        let proof = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        proof.name = "notification-font-exact-lower-rows-\(phase)"; proof.lifetime = .keepAlways; add(proof)
    }

    /// Read-only fresh screenshots for the explicitly people-free product baseline.
    /// Raster review remains separate from successful navigation assertions.
    func testCapturePeopleFreeIntroMatchesProfileAndHelpWithoutMutations() throws {
        let f = try preflight()
        guard let folder = env["QA_SHOT_DIR"], folder.hasPrefix("/") else {
            throw XCTSkip("Explicit private absolute QA_SHOT_DIR required for requested raster evidence")
        }
        func save(_ screen: String) throws {
            if screen != "intro" {
                let notificationPoll = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    self.count("GET /api/users/notifications/count") >= 1
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [notificationPoll], timeout: 15), .completed)
            }
            // Keep the actual app/OS notification behavior; wait for its banner
            // to settle so the requested artwork/header raster is unobstructed.
            let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard").descendants(matching: .any)
                .matching(identifier: "NotificationShortLookView").firstMatch
            if banner.waitForExistence(timeout: 2) {
                XCTAssertTrue(banner.waitForNonExistence(timeout: 15), "System notification must finish before the evidence screenshot")
            }
            let image = app.screenshot()
            let name = "people-free-\(f.role)-\(screen)"
            let attachment = XCTAttachment(screenshot: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
            try image.pngRepresentation.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        app.launchArguments = ["--qa-signout", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        XCTAssertTrue(app.buttons["Sign in"].firstMatch.waitForExistence(timeout: 60))
        try save("intro")
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-tab", "matches",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let matchesReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.buttons["Messages"].exists && self.count("GET /api/" + f.listEndpoint) >= 1
                && !self.app.staticTexts["Please wait..."].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matchesReady], timeout: 60), .completed)
        try save("matches")
        let profileTab = try XCTUnwrap(app.buttons.matching(identifier: "Profile").allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.midY > app.frame.midY
        }, "Actual bottom Profile tab must be visible")
        XCTAssertTrue(profileTab.exists && profileTab.isHittable)
        profileTab.tap()
        let edit = app.buttons[f.label("profile_edit", "Edit")]
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        try save("profile")
        launchOwnedRoute("HelpCenter")
        XCTAssertTrue(app.navigationBars["Help Center"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.buttons["Delete Account"].firstMatch.waitForExistence(timeout: 15))
        try save("help")
        XCTAssertEqual(totalMutationCount(method: "POST"), 0)
        XCTAssertEqual(totalMutationCount(method: "PATCH"), 0)
        XCTAssertEqual(totalMutationCount(method: "DELETE"), 0)
        try record("people-free-screen-capture-scope-\(f.role)", ["role": f.role,
            "screens": ["intro", "matches", "profile", "help"], "renderedArtworkReviewRequired": true,
            "profileOrRelationshipMutations": false, "privateFixtureScreenshotPermission": "0600"])
    }

    /// P23-011: direct owned profile coverage does not depend on compatible-list placement.
    /// The unchanged card matrix remains separate and may legitimately skip.
    func testOwnedOutgoingCancelUsesManagedLabelAndDismissThenConfirmRestoresNone() throws {
        let f = try preflight()
        let initial = try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)
        let other = try profile(f.peerEndpoint, token: f.peerToken, expectedUser: f.primaryID)
        guard initial["match_status"] as? String == "none", other["match_status"] as? String == "none" else {
            throw XCTSkip("Outgoing Cancel requires exact retained pair NONE; preserving existing relationship")
        }
        let cancel = try XCTUnwrap(f.labels["general_cancel"], "Managed Cancel must exist")
        let obsolete = try XCTUnwrap(f.labels["match_withdraw_title"], "Current managed withdrawal label must exist for the regression guard")
        XCTAssertEqual(cancel, "Cancel", "This English allocation must retain the governing Cancel contract")
        XCTAssertNotEqual(cancel, obsolete, "Live CMS fixture must expose the distinct Withdraw regression trigger")
        cleanupFixture = f
        let edge = try createRequest(f, fromPrimary: true)
        XCTAssertEqual(try pairStatus(f), "sent") // also asserts the peer is RECEIVED
        _ = try ownedEdge(edge, fixture: f)
        launchOwnedRoute((f.role == "client" ? "CaregiverDetails/" : "ClientDetails/") + f.peerID)
        let outgoing = app.buttons["match-withdraw"]
        XCTAssertTrue(outgoing.waitForExistence(timeout: 45))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            outgoing.isHittable && !self.app.staticTexts["Please wait..."].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        XCTAssertEqual(outgoing.label, cancel)
        XCTAssertNotEqual(outgoing.label, obsolete)
        let endpoint = "DELETE /api/users/matches/\(edge)/withdraw"
        XCTAssertEqual(count(endpoint), 0)
        for shouldConfirm in [false, true] {
            XCTAssertTrue(outgoing.isHittable)
            outgoing.tap()
            let dialog = app.alerts[cancel]
            XCTAssertTrue(dialog.waitForExistence(timeout: 10), "Outgoing confirmation title must be managed Cancel")
            XCTAssertTrue(dialog.staticTexts[cancel].exists)
            let dismiss = dialog.buttons.matching(identifier: "match-confirm-dismiss").firstMatch
            let confirm = dialog.buttons.matching(identifier: "match-action-confirm").firstMatch
            let hierarchy = XCTAttachment(string: dialog.debugDescription)
            hierarchy.name = "owned-outgoing-cancel-alert-hierarchy-\(f.role)"
            hierarchy.lifetime = .keepAlways; add(hierarchy)
            let initialProof = XCTAttachment(screenshot: dialog.screenshot())
            initialProof.name = "owned-outgoing-cancel-before-target-assertion-\(f.role)"
            initialProof.lifetime = .keepAlways; add(initialProof)
            XCTAssertTrue(dismiss.exists && dismiss.isHittable)
            XCTAssertTrue(confirm.exists && confirm.isHittable)
            XCTAssertEqual(dismiss.label, cancel)
            XCTAssertEqual(confirm.label, cancel)
            // UIKit exposes each SwiftUI alert action as nested Button nodes
            // with identical identifier/label/frame. Count distinct hit targets,
            // retaining strict exact-label/identifier assertions on every node.
            let actionNodes = dialog.buttons.allElementsBoundByIndex
            XCTAssertEqual(Set(actionNodes.map(\.identifier)), Set(["match-confirm-dismiss", "match-action-confirm"]))
            XCTAssertTrue(actionNodes.allSatisfy { $0.label == cancel })
            let distinctTargets = Set(actionNodes.map { "\($0.identifier):\(NSCoder.string(for: $0.frame))" })
            XCTAssertEqual(distinctTargets.count, 2)
            XCTAssertFalse(dialog.staticTexts[obsolete].exists)
            let proof = XCTAttachment(screenshot: dialog.screenshot())
            proof.name = "owned-outgoing-cancel-\(shouldConfirm ? "confirm" : "dismiss")-\(f.role)"
            proof.lifetime = .keepAlways; add(proof)
            if shouldConfirm {
                _ = try ownedEdge(edge, fixture: f) // verify exact marker ownership immediately before native mutation
                confirm.tap()
                XCTAssertTrue(dialog.waitForNonExistence(timeout: 10))
                let request = app.buttons["match-request"]
                XCTAssertTrue(request.waitForExistence(timeout: 45), "Confirmed Cancel must restore the NONE profile action")
                XCTAssertFalse(outgoing.exists)
                XCTAssertEqual(count(endpoint), 1, "One actual confirmation must send exactly one withdrawal")
                XCTAssertEqual(try pairStatus(f), "none") // both exact public profiles
            } else {
                dismiss.tap()
                XCTAssertTrue(dialog.waitForNonExistence(timeout: 10))
                XCTAssertEqual(count(endpoint), 0, "Dialog Cancel must preserve the outgoing request without a DELETE")
                XCTAssertEqual(try pairStatus(f), "sent")
                XCTAssertTrue(outgoing.exists && outgoing.isHittable)
            }
        }
        cleanupFixture = nil
        try record("P23-011-native-outgoing-cancel-\(f.role)", ["role": f.role,
            "source": "exact-owned-profile-direct-route", "managedGeneralCancelUsed": true,
            "distinctCMSWithdrawRejected": true, "titleAndBothDialogActionsCancel": true,
            "dismissPreservedSentReceivedWithoutDELETE": true, "confirmedWithdrawalDELETEs": 1,
            "bothProfilesFinalNone": true, "compatibleCardCoverage": false])
    }

    /// R10 uses only the exact retained fixture pair and restores its staged edge.
    /// This checks settled geometry/navigation; raster review verifies the slide itself.
    func testOwnedActiveMatchedCardsRemainBalancedAcrossForegroundAndReopening() throws {
        try matchedCardsBalanced(languageID: 1, languageCode: "en")
    }

    func testOwnedArabicMatchedUsesManagedSelfLabelAndMirroredBalancedCards() throws {
        try matchedCardsBalanced(languageID: 3, languageCode: "ar")
    }

    private func matchedCardsBalanced(languageID: Int, languageCode: String) throws {
        let f = try preflight(languageID: languageID)
        let selfLabel = try XCTUnwrap(f.labels["chat_screen_you"], "Actual CMS self label must exist in the selected language")
        let initial = try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)
        let peerInitial = try profile(f.peerEndpoint, token: f.peerToken, expectedUser: f.primaryID)
        guard initial["match_status"] as? String == "none", peerInitial["match_status"] as? String == "none" else {
            throw XCTSkip("R10 requires exact retained pair NONE; no existing relationship disturbed")
        }
        cleanupFixture = f
        let edge = try createRequest(f, fromPrimary: true)
        _ = try ownedEdge(edge, fixture: f)
        let acceptance = try CarezaarAPI.callWithHTTPStatus("PATCH", "users/matches/\(edge)/accept", token: f.peerToken)
        XCTAssertTrue((200..<300).contains(acceptance.status))
        XCTAssertEqual(try pairStatus(f), "active")
        let route = "Matched/\(f.role == "client" ? "caregivers" : "clients")/\(f.peerID)"
        for _ in 0..<2 {
            launchOwnedRoute(route, languageID: languageID, languageCode: languageCode)
            let own = app.descendants(matching: .any).matching(identifier: "matched-self-photo-card").firstMatch
            let peer = app.descendants(matching: .any).matching(identifier: "matched-partner-photo-card").firstMatch
            XCTAssertTrue(own.waitForExistence(timeout: 45) && peer.exists)
            // Hittability can become true before an entrance spring settles.
            // Require consecutive stable measurements inside the same original
            // five-second deadline; retain strict post-foreground comparisons.
            var previous: (CGRect, CGRect)?
            var stableSamples = 0
            var geometrySamples: [[String: Double]] = []
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let ownFrame = own.frame, peerFrame = peer.frame
                geometrySamples.append(["selfX": ownFrame.midX, "partnerX": peerFrame.midX,
                    "selfWidth": ownFrame.width, "partnerWidth": peerFrame.width])
                if let previous, abs(previous.0.midX - ownFrame.midX) < 0.5,
                   abs(previous.1.midX - peerFrame.midX) < 0.5,
                   abs(previous.0.width - ownFrame.width) < 0.5,
                   abs(previous.1.width - peerFrame.width) < 0.5 {
                    stableSamples += 1
                } else { stableSamples = 0 }
                previous = (ownFrame, peerFrame)
                return stableSamples >= 2 && own.isHittable && peer.isHittable
                    && self.app.frame.contains(ownFrame) && self.app.frame.contains(peerFrame)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            let settlingProof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: geometrySamples, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            settlingProof.name = "R10-entrance-settling-frame-samples"; settlingProof.lifetime = .keepAlways; add(settlingProof)
            if languageCode == "ar" { XCTAssertGreaterThan(own.frame.midX, peer.frame.midX) }
            else { XCTAssertLessThan(own.frame.midX, peer.frame.midX) }
            XCTAssertLessThan(abs(own.frame.width - peer.frame.width), 25)
            XCTAssertTrue(peer.label.contains(f.peerName))
            XCTAssertTrue(own.label.contains(selfLabel), "Matched self label must use the actual selected-language CMS value")
            let ownFrame = own.frame, peerFrame = peer.frame
            XCUIDevice.shared.press(.home); app.activate()
            XCTAssertTrue(own.exists && peer.exists)
            var foregroundSamples: [[String: Double]] = []
            let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let a = own.frame, b = peer.frame
                foregroundSamples.append(["selfX": a.midX, "partnerX": b.midX,
                    "selfWidth": a.width, "partnerWidth": b.width])
                // SpringBoard's foreground zoom can temporarily transform AX
                // rectangles even after activate() returns. Require the original
                // settled geometry, retaining the strict comparison below.
                return abs(a.midX - ownFrame.midX) <= 2 && abs(b.midX - peerFrame.midX) <= 2
                    && abs(a.width - ownFrame.width) <= 2 && abs(b.width - peerFrame.width) <= 2
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
            let foregroundProof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: foregroundSamples, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            foregroundProof.name = "R10-foreground-frame-samples"; foregroundProof.lifetime = .keepAlways; add(foregroundProof)
            XCTAssertEqual(own.frame.midX, ownFrame.midX, accuracy: 2)
            XCTAssertEqual(peer.frame.midX, peerFrame.midX, accuracy: 2)
            XCTAssertEqual(count("GET /api/" + f.profileEndpoint), 1)
            XCTAssertEqual(count("POST /api/users/matches"), 0)
        }
        app.terminate()
        try restoreNone(f)
        XCTAssertEqual(try pairStatus(f), "none")
        cleanupFixture = nil
        try record("R10-owned-matched-card-lifecycle", ["role": f.role, "languageCode": languageCode, "freshPresentations": 2,
            "settledCardsBalanced": true, "foregroundRestoresSettledGeometry": true,
            "oneProfileReadPerOpening": true, "ownedEdgeRestored": true,
            "slideRasterAndReducedMotionReviewRequired": true])
    }

    /// Remaining P16-001–004 / P16-008–011 chat-authorization portions. The
    /// inactive native Send guard is exercised, never a direct negative POST.
    /// ACTIVE opens the already existing owned conversation and types only.
    func testOwnedExistingChatRejectsInactiveDraftSendAndActiveProfileMessageOpensSameChat() throws {
        let f = try preflight()
        let initial = try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)
        let initialPeer = try profile(f.peerEndpoint, token: f.peerToken, expectedUser: f.primaryID)
        guard initial["match_status"] as? String == "none", initialPeer["match_status"] as? String == "none" else {
            throw XCTSkip("Chat guard matrix requires exact owned pair initially NONE; no existing relationship will be disturbed")
        }
        let chatID = try existingOwnedChat(f)
        cleanupFixture = f
        try rejectInactiveSend("none", fixture: f, chatID: chatID)
        _ = try createRequest(f, fromPrimary: true)
        try rejectInactiveSend("sent", fixture: f, chatID: chatID)
        try restoreNone(f)
        _ = try createRequest(f, fromPrimary: false)
        try rejectInactiveSend("received", fixture: f, chatID: chatID)
        try restoreNone(f)

        let matchID = try createRequest(f, fromPrimary: true)
        _ = try ownedEdge(matchID, fixture: f)
        let accepted = try CarezaarAPI.callWithHTTPStatus("PATCH", "users/matches/\(matchID)/accept", token: f.peerToken)
        XCTAssertTrue((200..<300).contains(accepted.status))
        XCTAssertEqual(try pairStatus(f), "active")
        _ = try ownedChat(chatID, fixture: f, active: true)
        launchOwnedRoute((f.role == "client" ? "CaregiverDetails/" : "ClientDetails/") + f.peerID)
        let prefix = f.role == "client" ? "caregiver_details" : "client_details"
        let message = app.buttons[f.label(prefix + "_message", "Message")]
        XCTAssertTrue(message.waitForExistence(timeout: 45), "Active profile must expose its actual Message entry")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            message.isHittable && !self.app.staticTexts["Please wait..."].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        XCTAssertEqual(count("GET /api/" + f.profileEndpoint), 1)
        message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let field = try loadedOwnedComposer(chatID: chatID)
        // Message calls the existing create/find-chat endpoint. Exact same old
        // chat ID and both nested participant identities must still be returned.
        XCTAssertEqual(count("POST /api/users/chats"), 1)
        XCTAssertEqual(try existingOwnedChat(f), chatID, "Active Message must reuse the exact existing conversation")
        let draft = "Synthetic active draft only " + UUID().uuidString
        field.tap(); field.typeText(draft)
        XCTAssertTrue((field.value as? String) == draft)
        XCTAssertTrue(app.buttons["Send"].exists && app.buttons["Send"].isEnabled)
        XCTAssertEqual(chatSendAttempts(), 0, "Active entry/input alone must never send a message")
        let control = XCTAttachment(screenshot: app.buttons["Send"].screenshot())
        control.name = "active-chat-send-enabled-control-only-\(f.role)"; control.lifetime = .keepAlways; add(control)
        let back = app.navigationBars["Chat Messages"].buttons.firstMatch
        XCTAssertTrue(back.exists && back.isHittable)
        XCTAssertTrue((field.value as? String) == draft, "Exact active draft must remain unchanged before Back")
        back.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertFalse(field.exists)
        XCTAssertEqual(chatSendAttempts(), 0)
        let after = try ownedChat(chatID, fixture: f, active: true)
        XCTAssertFalse(chatTexts(after).contains(draft))
        try record("active-owned-existing-chat-entry-\(f.role)", ["role": f.role, "publicState": "active",
            "existingChatReusedAndParticipantsVerified": true, "actualChatGETs": count("GET /api/users/chats/\(chatID)"),
            "profileMessageEntryObserved": true, "syntheticDraftEnteredSendEnabled": true,
            "nativeChatSendPOSTs": 0, "syntheticDraftAbsentFromBackend": true,
            "activeMessageDeliveryCovered": false])
        try restoreNone(f)
        XCTAssertEqual(try pairStatus(f), "none")
        cleanupFixture = nil
    }

    /// P16-005–007 / P16-012–014: current card/profile and native chat guard
    /// after real owned reject, withdraw and unmatch transitions. API staging
    /// does not cover native confirmation dialogs or historical record UI.
    func testOwnedRejectedWithdrawnEndedTransitionsRenderNoneAndRestrictNativeChatSend() throws {
        let f = try preflight()
        let initial = try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)
        let other = try profile(f.peerEndpoint, token: f.peerToken, expectedUser: f.primaryID)
        guard initial["match_status"] as? String == "none", other["match_status"] as? String == "none" else {
            throw XCTSkip("Post-transition matrix requires exact owned pair initially NONE; preserving existing relationship")
        }
        let chatID = try existingOwnedChat(f)
        cleanupFixture = f

        let rejected = try createRequest(f, fromPrimary: true)
        XCTAssertEqual(try pairStatus(f), "sent")
        _ = try ownedEdge(rejected, fixture: f)
        // Native UserService.rejectMatch uses DELETE; OpenAPI returns 204.
        let rejection = try deleteOwnedEdge("users/matches/\(rejected)/reject", token: f.peerToken)
        XCTAssertEqual(rejection, 204, "Exact owned recipient must reject its pending request")
        XCTAssertEqual(try pairStatus(f), "none")
        try render("none", fixture: f)
        try rejectInactiveSend("none", fixture: f, chatID: chatID)
        try recordPostTransition("rejected", fixture: f)

        let withdrawn = try createRequest(f, fromPrimary: true)
        XCTAssertEqual(try pairStatus(f), "sent")
        _ = try ownedEdge(withdrawn, fixture: f)
        let withdrawal = try deleteOwnedEdge("users/matches/\(withdrawn)/withdraw", token: f.primaryToken)
        XCTAssertEqual(withdrawal, 204, "Exact owned requester must withdraw its pending request")
        XCTAssertEqual(try pairStatus(f), "none")
        try render("none", fixture: f)
        try rejectInactiveSend("none", fixture: f, chatID: chatID)
        try recordPostTransition("withdrawn", fixture: f)

        let ended = try createRequest(f, fromPrimary: true)
        _ = try ownedEdge(ended, fixture: f)
        let acceptance = try CarezaarAPI.callWithHTTPStatus("PATCH", "users/matches/\(ended)/accept", token: f.peerToken)
        XCTAssertTrue((200..<300).contains(acceptance.status))
        XCTAssertEqual(try pairStatus(f), "active")
        _ = try ownedChat(chatID, fixture: f, active: true)
        _ = try ownedEdge(ended, fixture: f)
        let unmatch = try deleteOwnedEdge("users/matches/\(ended)", token: f.primaryToken)
        XCTAssertEqual(unmatch, 200, "Exact owned primary must end only its marked active edge")
        XCTAssertEqual(try pairStatus(f), "none")
        try render("none", fixture: f)
        try rejectInactiveSend("none", fixture: f, chatID: chatID)
        try recordPostTransition("ended", fixture: f)
        XCTAssertEqual(try pairStatus(f), "none")
        cleanupFixture = nil
    }

    private func recordPostTransition(_ transition: String, fixture f: Fixture) throws {
        try record("owned-post-\(transition)-state-and-chat-\(f.role)", ["role": f.role,
            "transition": transition, "staging": "exact-marker-owned-public-API-transition",
            "bothCurrentPublicProfilesState": "none", "currentOwnedCardActiveBadgePresent": false,
            "currentProfileRequestPresent": true, "currentProfileMessagePresent": false,
            "nativeChatMetadataInactive": true, "nativeBlockedSendPOSTs": 0,
            "nativeBlockedDraftPreservedAndAbsentFromBackend": true,
            "nativeConfirmationDialogCovered": false, "historySchemaOrHistoryUICovered": false])
    }

    private func existingOwnedChat(_ f: Fixture) throws -> Int {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/chats?page=1&perPage=50", token: f.primaryToken)
        XCTAssertEqual(response.status, 200)
        let rows = try XCTUnwrap(response.body["result"] as? [[String: Any]])
        let rowsForPair = rows.filter { row in
            nestedUserID(row, side: f.role) == f.primaryID
                && nestedUserID(row, side: f.role == "client" ? "caregiver" : "client") == f.peerID
        }
        guard !rowsForPair.isEmpty else { throw XCTSkip("Owned pair lacks an existing chat; no conversation fixture will be created") }
        XCTAssertEqual(rowsForPair.count, 1, "Owned existing conversation must be unambiguous")
        return try XCTUnwrap(rowsForPair.first?["id"] as? Int)
    }

    private func nestedUserID(_ row: [String: Any], side: String) -> String {
        let user = (row[side] as? [String: Any])?["user"] as? [String: Any]
        return user?["id"].map { String(describing: $0) } ?? ""
    }

    private func ownedChat(_ id: Int, fixture f: Fixture, active: Bool) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/chats/\(id)", token: f.primaryToken)
        XCTAssertEqual(response.status, 200, "Exact owned chat metadata must remain readable")
        let row = try XCTUnwrap(response.body["result"] as? [String: Any])
        XCTAssertTrue((row["id"] as? Int) == id)
        XCTAssertTrue(nestedUserID(row, side: f.role) == f.primaryID
            && nestedUserID(row, side: f.role == "client" ? "caregiver" : "client") == f.peerID,
                      "Chat must resolve only to the exact retained owned pair")
        let peer = try XCTUnwrap(row[f.role == "client" ? "caregiver" : "client"] as? [String: Any])
        XCTAssertEqual(peer["is_match"] as? Bool, active, "Chat metadata must reflect the actual current relationship")
        return row
    }

    private func chatTexts(_ row: [String: Any]) -> [String] {
        (row["messages"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
    }

    private func launchOwnedRoute(_ route: String, languageID: Int = 1, languageCode: String = "en") {
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts", "--qa-push", route,
                               "-carezaar.languageId", String(languageID), "-carezaar.languageCode", languageCode]
        app.launch()
    }

    private func loadedOwnedComposer(chatID: Int) throws -> XCUIElement {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 45))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            field.isHittable && !self.app.staticTexts["Please wait..."].exists
                && self.count("GET /api/users/chats/\(chatID)") >= 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        XCTAssertEqual(app.textFields.count, 1)
        XCTAssertEqual(field.placeholderValue, "Type a message...")
        XCTAssertTrue(app.navigationBars["Chat Messages"].exists)
        XCTAssertEqual(chatSendAttempts(), 0)
        return field
    }

    private func chatSendAttempts() -> Int {
        app.staticTexts["qa-request-counts"].label.split(separator: "\n")
            .filter { $0.hasPrefix("POST /api/users/chats/") }
            .compactMap { Int($0.split(separator: "=").last ?? "") }.reduce(0, +)
    }

    /// Parity v3 K2: a conversation with someone who is no longer a match is closed:
    /// the managed note sits above a disabled typing box and a grey Send.
    private func rejectInactiveSend(_ status: String, fixture f: Fixture, chatID: Int) throws {
        XCTAssertEqual(try pairStatus(f), status)
        _ = try ownedChat(chatID, fixture: f, active: false)
        launchOwnedRoute("Chat/\(chatID)")
        let field = try loadedOwnedComposer(chatID: chatID)
        let managed = f.label("chat_screen_match_check", "You can only send messages to your current matches.")
        let note = app.descendants(matching: .any)["chat-closed-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 15), "Inactive conversation must show the closed note")
        XCTAssertTrue(note.label.contains(managed), "Closed note must use the exact managed current-matches text")
        XCTAssertFalse(field.isEnabled, "Inactive conversation must turn the typing box off")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.exists && !send.isEnabled, "Inactive conversation Send must be grey")
        let before = count("GET /api/users/chats/\(chatID)")
        send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let proof = XCTAttachment(screenshot: note.screenshot())
        proof.name = "owned-\(status)-chat-closed-note-\(f.role)"; proof.lifetime = .keepAlways; add(proof)
        XCTAssertEqual(count("GET /api/users/chats/\(chatID)"), before,
                       "Requirement 14 uses the already loaded inactive relationship without another Send preflight")
        XCTAssertEqual(chatSendAttempts(), 0, "Inactive native guard must prevent every message POST")
        XCTAssertEqual(try pairStatus(f), status)
        try record("owned-\(status)-native-send-guard-\(f.role)", ["role": f.role, "publicState": status,
            "loadedInactiveMetadataUsed": true, "additionalSendPreflightGETs": 0, "nativeChatSendPOSTs": 0,
            "managedCurrentMatchesRestrictionObserved": true, "composerDisabled": true,
            "directNegativeBackendPOSTPerformed": false])
    }

    private func preflight(languageID: Int = 1) throws -> Fixture {
        let required = ["QA_EMAIL", "QA_PASSWORD", "QA_CLIENT_EMAIL", "QA_CLIENT_PASSWORD",
                        "QA_CG_EMAIL", "QA_CG_PASSWORD", "QA_CLIENT_USER_ID", "QA_CG_ID"]
        guard required.allSatisfy({ !(env[$0] ?? "").isEmpty }) else {
            throw XCTSkip("Explicit primary plus both retained owned role credentials/IDs required")
        }
        let clientID = env["QA_CLIENT_USER_ID"]!, caregiverID = env["QA_CG_ID"]!
        XCTAssertTrue(clientID != caregiverID)
        func auth(_ email: String, _ password: String, role: String, id: String) throws -> (String, [String: Any]) {
            let token = try CarezaarAPI.login(email, password)
            let user = try CarezaarAPI.me(token)
            guard !token.isEmpty, user["role"] as? String == role,
                  user["id"].map({ String(describing: $0) }) == id,
                  user["email"] as? String == email else {
                XCTFail("Mutation fixture failed exact private role/email/user-ID authorization")
                throw URLError(.userAuthenticationRequired)
            }
            return (token, user)
        }
        let client = try auth(env["QA_CLIENT_EMAIL"]!, env["QA_CLIENT_PASSWORD"]!, role: "client", id: clientID)
        let caregiver = try auth(env["QA_CG_EMAIL"]!, env["QA_CG_PASSWORD"]!, role: "caregiver", id: caregiverID)
        let primaryToken = try CarezaarAPI.login(env["QA_EMAIL"]!, env["QA_PASSWORD"]!)
        let primary = try CarezaarAPI.me(primaryToken)
        let role = primary["role"] as? String ?? ""
        let id = primary["id"].map { String(describing: $0) } ?? ""
        guard !primaryToken.isEmpty,
              (role == "client" && id == clientID && primary["email"] as? String == env["QA_CLIENT_EMAIL"])
                || (role == "caregiver" && id == caregiverID && primary["email"] as? String == env["QA_CG_EMAIL"]),
              primary["email"] as? String == env["QA_EMAIL"] else {
            XCTFail("Primary runner is outside the exact owned pair")
            throw URLError(.userAuthenticationRequired)
        }
        let peer = role == "client" ? caregiver : client
        let name = [peer.1["first_name"] as? String, peer.1["last_name"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertFalse(name.isEmpty)
        let contents = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0", token: primaryToken)
        XCTAssertEqual(contents.status, 200)
        let rows = try XCTUnwrap(contents.body["result"] as? [[String: Any]])
        var labels = [String: String]()
        for row in rows {
            guard let slug = row["slug"] as? String, let translation = (row["translations"] as? [[String: Any]])?.first(where: {
                ($0["language_id"] as? NSNumber)?.intValue == languageID || ($0["language_id"] as? String) == String(languageID)
            }), let name = translation["name"] as? String else { continue }
            labels[slug] = name
        }
        return Fixture(primaryToken: primaryToken, peerToken: peer.0, role: role, primaryID: id,
                       peerID: role == "client" ? caregiverID : clientID, peerName: name, labels: labels)
    }

    private func profile(_ endpoint: String, token: String, expectedUser: String) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", endpoint, token: token)
        XCTAssertEqual(response.status, 200)
        let row = try XCTUnwrap(response.body["result"] as? [String: Any])
        let user = try XCTUnwrap(row["user"] as? [String: Any])
        XCTAssertTrue(user["id"].map { String(describing: $0) } == expectedUser,
                      "Relationship reference must resolve only to the exact owned counterpart")
        return row
    }

    private func pairStatus(_ f: Fixture) throws -> String {
        let primary = try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)
        let peer = try profile(f.peerEndpoint, token: f.peerToken, expectedUser: f.primaryID)
        let status = try XCTUnwrap(primary["match_status"] as? String)
        let inverse = ["none": "none", "sent": "received", "received": "sent", "active": "active"]
        XCTAssertEqual(peer["match_status"] as? String, inverse[status])
        XCTAssertEqual(primary["is_match"] as? Bool, status == "active")
        XCTAssertEqual(peer["is_match"] as? Bool, status == "active")
        if status != "none" {
            let id = try XCTUnwrap(primary["match_id"] as? Int)
            XCTAssertGreaterThan(id, 0)
            XCTAssertEqual(peer["match_id"] as? Int, id)
            _ = try ownedEdge(id, fixture: f)
        }
        return status
    }

    private func ownedEdge(_ id: Int, fixture f: Fixture) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/matches/\(id)", token: f.primaryToken)
        XCTAssertEqual(response.status, 200)
        let row = try XCTUnwrap(response.body["result"] as? [String: Any])
        func userID(_ side: String) -> String {
            let user = (row[side] as? [String: Any])?["user"] as? [String: Any]
            return user?["id"].map { String(describing: $0) } ?? ""
        }
        guard userID(f.role) == f.primaryID,
              userID(f.role == "client" ? "caregiver" : "client") == f.peerID,
              row["introduction"] as? String == marker else {
            XCTFail("Refusing mutation/cleanup of an edge outside this run's exact marked owned pair")
            throw URLError(.userAuthenticationRequired)
        }
        return row
    }

    private func createRequest(_ f: Fixture, fromPrimary: Bool) throws -> Int {
        XCTAssertEqual(try pairStatus(f), "none", "Each stage must start without a relationship")
        let response = try CarezaarAPI.callWithHTTPStatus("POST", "users/matches",
            form: ["partner_id": fromPrimary ? f.peerID : f.primaryID, "introduction": marker],
            token: fromPrimary ? f.primaryToken : f.peerToken)
        XCTAssertTrue((200..<300).contains(response.status), "Owned staging request must succeed once")
        let row = try XCTUnwrap(response.body["result"] as? [String: Any])
        let id = try XCTUnwrap(row["id"] as? Int)
        _ = try ownedEdge(id, fixture: f)
        return id
    }

    private func restoreNone(_ f: Fixture) throws {
        let p = try profile(f.profileEndpoint, token: f.primaryToken, expectedUser: f.peerID)
        let status = try XCTUnwrap(p["match_status"] as? String)
        if status == "none" { return }
        let id = try XCTUnwrap(p["match_id"] as? Int)
        _ = try ownedEdge(id, fixture: f)
        let suffix: String, token: String
        switch status {
        case "sent": suffix = "/withdraw"; token = f.primaryToken
        case "received": suffix = "/withdraw"; token = f.peerToken
        case "active": suffix = ""; token = f.primaryToken
        default: XCTFail("Unrecognized pair state blocks cleanup"); throw URLError(.cannotParseResponse)
        }
        let statusCode = try deleteOwnedEdge("users/matches/\(id)\(suffix)", token: token)
        XCTAssertTrue((200..<300).contains(statusCode), "Exact owned staged-edge cleanup must succeed")
        XCTAssertEqual(try pairStatus(f), "none")
    }

    private func render(_ status: String, fixture f: Fixture) throws {
        XCTAssertEqual(try pairStatus(f), status)
        // The independent snapshot must use the same first page as native:
        // APIConfiguration.defaultPageSize=10; OpenAPI permits only 10/25/50.
        let response = try CarezaarAPI.callWithHTTPStatus("GET", f.listEndpoint + "?page=1&perPage=10&sort=distance", token: f.primaryToken)
        XCTAssertEqual(response.status, 200)
        let rows = try XCTUnwrap(response.body["result"] as? [[String: Any]])
        let owned = rows.filter { (($0["user"] as? [String: Any])?["id"]).map { String(describing: $0) } == f.peerID }
        guard owned.count == 1 else { throw XCTSkip("Owned peer excluded from first-page compatible Matches; cannot manufacture a native card") }
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-request-counts",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let distance = f.label("general_miles_away", "mile(s) away")
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", f.peerName, distance)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 60), "Exact owned compatible card must render")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            card.isHittable && !self.app.staticTexts["Please wait..."].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        XCTAssertGreaterThanOrEqual(count("GET /api/" + f.listEndpoint), 1,
                                    "Owned card must come from the primary role's actual native list request")
        XCTAssertGreaterThanOrEqual(count("GET /api/auth/info"), 1)
        let oppositeList = f.role == "client" ? "caregivers/matches" : "clients/matches"
        XCTAssertEqual(count("GET /api/" + oppositeList), 0, "Native fixture must not load the opposite role's Matches")
        let badge = card.descendants(matching: .any)["active-match-icon"].firstMatch
        let activeBadgePresent = badge.exists
        XCTAssertEqual(activeBadgePresent, status == "active", "Only the active owned card may display the actual match badge")
        if status == "active" {
            XCTAssertTrue(badge.isHittable)
            let proof = XCTAttachment(screenshot: badge.screenshot())
            proof.name = "owned-active-match-icon-only-\(f.role)"; proof.lifetime = .keepAlways; add(proof)
        }
        let actionIDs = ["match-request", "match-withdraw", "match-reject", "match-accept", "match-unmatch"]
        for id in actionIDs { XCTAssertFalse(card.buttons[id].exists, "Card must not expose profile-only relationship actions") }
        XCTAssertEqual(count("GET /api/" + f.profileEndpoint), 0)
        card.tap()
        let expectedIDs: [String] = switch status {
        case "none": ["match-request"]
        case "sent": ["match-withdraw"]
        case "received": ["match-reject", "match-accept"]
        default: ["match-unmatch"]
        }
        XCTAssertTrue(app.buttons[expectedIDs[0]].waitForExistence(timeout: 40))
        for id in actionIDs {
            XCTAssertEqual(app.buttons[id].exists, expectedIDs.contains(id), "Profile action set must match exact public state")
        }
        let expectedLabels = ["match-request": f.label("match_match_button", "Request a Match"),
            "match-withdraw": f.label("general_cancel", "Cancel"),
            "match-reject": f.label("match_reject_title", f.label("match_reject", "Reject")),
            "match-accept": f.label("match_accept_title", "Accept"), "match-unmatch": f.label("match_unmatch_title", "Unmatch")]
        for id in expectedIDs {
            XCTAssertEqual(app.buttons[id].label, expectedLabels[id])
            XCTAssertTrue(app.buttons[id].isHittable)
            let actionProof = XCTAttachment(screenshot: app.buttons[id].screenshot())
            actionProof.name = "owned-\(status)-\(id)-control-only-\(f.role)"
            actionProof.lifetime = .keepAlways; add(actionProof)
        }
        let pending = app.staticTexts[f.label("match_pending_acceptance", "Pending Acceptance")]
        XCTAssertEqual(pending.exists, status == "sent")
        let prefix = f.role == "client" ? "caregiver_details" : "client_details"
        let message = app.buttons[f.label(prefix + "_message", "Message")]
        XCTAssertEqual(message.exists, status == "active")
        if status == "active" { XCTAssertTrue(message.isHittable) }
        if status == "received" {
            let reject = app.buttons["match-reject"], accept = app.buttons["match-accept"]
            if abs(reject.frame.midY - accept.frame.midY) < 8 { XCTAssertLessThan(reject.frame.midX, accept.frame.midX) }
            else { XCTAssertLessThan(reject.frame.midY, accept.frame.midY) }
        }
        XCTAssertEqual(count("GET /api/" + f.profileEndpoint), 1, "One opening requires exactly one partner profile GET")
        for method in ["POST", "PATCH", "DELETE"] {
            XCTAssertEqual(totalMutationCount(method: method), 0, "Rendering must not perform native backend mutations")
        }
        XCTAssertEqual(try pairStatus(f), status, "Native rendering must preserve staged public state")
        try record("owned-state-render-\(status)-\(f.role)", ["role": f.role, "publicState": status,
            "activeCardBadgePresent": activeBadgePresent, "profileActions": expectedIDs,
            "messagePresent": message.exists, "pendingAcceptancePresent": pending.exists,
            "profileGETs": 1, "nativeMutationAttempts": 0, "badgeColorRequiresRasterReview": status == "active"])
    }

    private func count(_ key: String) -> Int {
        let ledger = app.staticTexts["qa-request-counts"]
        XCTAssertTrue(ledger.exists)
        let prefix = key + "="
        return ledger.label.split(separator: "\n").first { $0.hasPrefix(prefix) }.flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
    }
    /// OpenAPI withdrawal succeeds with 204/no JSON. A status-only mutation
    /// helper avoids misclassifying successful cleanup as a decoding failure.
    /// Caller has already verified the exact marker-owned edge and pair IDs.
    private func deleteOwnedEdge(_ path: String, token: String) throws -> Int {
        var request = URLRequest(url: URL(string: path, relativeTo: CarezaarAPI.base)!)
        request.httpMethod = "DELETE"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        var result: Result<Int, Error> = .failure(URLError(.unknown))
        URLSession.shared.dataTask(with: request) { _, response, error in
            defer { done.signal() }
            if let error { result = .failure(error); return }
            guard let response = response as? HTTPURLResponse else {
                result = .failure(URLError(.badServerResponse)); return
            }
            result = .success(response.statusCode)
        }.resume()
        done.wait()
        return try result.get()
    }
    private func totalMutationCount(method: String) -> Int {
        app.staticTexts["qa-request-counts"].label.split(separator: "\n").filter { $0.hasPrefix(method + " /api/users/matches") }
            .compactMap { Int($0.split(separator: "=").last ?? "") }.reduce(0, +)
    }
    private func record(_ name: String, _ values: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        let proof = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        proof.name = name; proof.lifetime = .keepAlways; add(proof)
    }
}
