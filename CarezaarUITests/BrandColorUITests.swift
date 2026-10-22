import XCTest

/// Client finding (22 Oct 2026): buttons, selected chips, the user's own chat bubble, the send button and
/// the floating add button must use the same brand blue as Android (#007AFE). Each element's colour
/// is read from a screenshot of the running app, not from the code. Screens are opened read-only:
/// nothing is sent or saved. `QA_SHOT_DIR` (absolute) receives the screenshots and the measured colours.
final class BrandColorUITests: XCTestCase {
    private let app = XCUIApplication()
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var measured: [[String: String]] = []

    override func setUp() { continueAfterFailure = true }

    func testBrandBlueElementsRenderAsTheAndroidBrandBlue() throws {
        guard env["QA_EMAIL"] != nil, env["QA_PASSWORD"] != nil, let chat = env["QA_CHAT_ID"],
              let folder = env["QA_SHOT_DIR"], folder.hasPrefix("/") else {
            throw XCTSkip("QA_EMAIL, QA_PASSWORD, QA_CHAT_ID and an absolute QA_SHOT_DIR are required")
        }
        let target = rgb(env["QA_EXPECT_BRAND_HEX"] ?? "007AFE")

        // My Matches: "Edit preferences".
        launch(["--qa-tab", "matches"])
        let edit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'preferences' OR label CONTAINS[c] 'skills'")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 60))
        settle()
        check("matches-edit-preferences-button", edit, at: .leadingInset, target: target, folder: folder)

        // Chat: own bubble, send button empty and with text (nothing is sent).
        launch(["--qa-push", "Chat/\(chat)"])
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 60))
        settle()
        // The message text sits 14 pt inside its bubble: the bubble is sampled just left of the text.
        let own = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Brand colour check'")).firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 30), "the client's own message must be on screen")
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        check("chat-own-bubble", own, at: .leftOfText, target: target, folder: folder)
        // Empty: the button stays blue and tappable and explains an empty message (K4, as on Android).
        // It is grey only on a closed conversation and dimmed only while a message is being sent.
        check("chat-send-button-empty", send, at: .topInset, target: target, folder: folder)
        field.tap(); field.typeText("Hello")
        check("chat-send-button-with-text", send, at: .topInset, target: target, folder: folder)

        // Report an Issue: floating add button.
        launch(["--qa-push", "ReportAnIssue"])
        let add = app.buttons["Report An Issue"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 60))
        settle()
        check("report-issue-floating-add-button", add, at: .topInset, target: target, folder: folder)

        // FAQ: the selected category chip ("All").
        launch(["--qa-push", "FAQ"])
        let selectedChip = app.buttons.matching(NSPredicate(format: "selected == true")).firstMatch
        XCTAssertTrue(selectedChip.waitForExistence(timeout: 60))
        settle()
        check("faq-selected-chip", selectedChip, at: .leadingInset, target: target, folder: folder)

        // Matches: the selected tab of Matches / Requests / History.
        launch(["--qa-push", "ManageMatches"])
        let tabButton = app.buttons["Matches"].firstMatch
        let tab: XCUIElement? = tabButton.waitForExistence(timeout: 30) ? tabButton : nil
        settle()
        if tab == nil {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("manage-matches-not-found.png"))
            measured.append(["element": "manage-matches-buttons-seen", "measured": app.buttons.allElementsBoundByIndex.prefix(20).map(\.label).joined(separator: " | ")])
        }
        XCTAssertNotNil(tab, "the Matches / Requests / History tabs must be on screen")
        if let tab { check("manage-matches-selected-tab", tab, at: .leadingInset, target: target, folder: folder) }

        let report = try JSONSerialization.data(withJSONObject: ["expected": env["QA_EXPECT_BRAND_HEX"] ?? "007AFE", "elements": measured],
                                                options: [.prettyPrinted, .sortedKeys])
        try report.write(to: URL(fileURLWithPath: folder).appendingPathComponent("brand-colors.json"))
    }

    // MARK: - Helpers

    private func launch(_ extra: [String]) {
        app.terminate()
        app.launchEnvironment["QA_EMAIL"] = env["QA_EMAIL"]
        app.launchEnvironment["QA_PASSWORD"] = env["QA_PASSWORD"]
        app.launchArguments = ["--qa-signout", "--qa-login-env", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"] + extra
        app.launch()
    }

    /// Lets loading cards and the initial notification permission prompt clear before sampling.
    private func settle() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 3) { alert.buttons.element(boundBy: 1).tap() }
        let busy = app.staticTexts["Please wait..."]
        _ = busy.waitForNonExistence(timeout: 45)
        Thread.sleep(forTimeInterval: 1.5)
    }

    private enum Spot { case leadingInset, topInset, leftOfText }

    private func check(_ name: String, _ element: XCUIElement, at spot: Spot, target: (Int, Int, Int), folder: String) {
        let shot = XCUIScreen.main.screenshot()
        let f = element.frame
        let point: CGPoint
        switch spot {
        case .leadingInset: point = CGPoint(x: f.minX + 5, y: f.midY)
        case .topInset: point = CGPoint(x: f.midX, y: f.minY + 5)
        case .leftOfText: point = CGPoint(x: f.minX - 6, y: f.midY)
        }
        let seen = color(at: point, in: shot)
        let hex = String(format: "%02X%02X%02X", seen.0, seen.1, seen.2)
        measured.append(["element": name, "measured": hex])
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        let close = abs(seen.0 - target.0) <= 6 && abs(seen.1 - target.1) <= 6 && abs(seen.2 - target.2) <= 6
        XCTAssertTrue(close, "\(name): measured #\(hex), expected #\(String(format: "%02X%02X%02X", target.0, target.1, target.2))")
    }

    /// The pixel at `point` (in points), converted to sRGB.
    private func color(at point: CGPoint, in shot: XCUIScreenshot) -> (Int, Int, Int) {
        guard let image = shot.image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return (0, 0, 0) }
        let scale = CGFloat(image.width) / shot.image.size.width
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0) }
        context.draw(image, in: CGRect(x: -(point.x * scale).rounded(.down), y: -(CGFloat(image.height) - (point.y * scale).rounded(.down) - 1),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private func rgb(_ hex: String) -> (Int, Int, Int) {
        let v = Int(hex, radix: 16) ?? 0
        return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }
}
