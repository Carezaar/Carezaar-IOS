import XCTest

/// Full client signup through the UI: credentials → email OTP (read from a
/// disposable mail.tm inbox) → profile → care wizard with the map → Main.
final class SignupTests: XCTestCase {
    var app: XCUIApplication!
    private var nativeSignupAccountFile: String?
    private var expectedSyntheticLocation: (lat: Double, lng: Double)?
    private var signupAllMatchesLabel: String?

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        if let run = testRun, run.hasSucceeded == false { dump("failure") }
        // Credential/OTP forms and profile email labels must not enter shared evidence.
        guard !hasSensitiveScreen else {
            print("Signup evidence screenshot omitted on a credential or OTP screen.")
            return
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        if let dir = ProcessInfo.processInfo.environment["QA_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name)-end.png"))
        }
    }

    private var hasSensitiveScreen: Bool {
        if app.secureTextFields.count > 0 { return true }
        if app.textFields.matching(NSPredicate(format: "label CONTAINS[c] %@", "email")).firstMatch.exists { return true }
        if app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "One-time code")).firstMatch.exists { return true }
        return app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@",
            ".*[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}.*")).firstMatch.exists
    }

    /// iOS offers "Use Strong Password?" on sign-up forms; a person can close it and
    /// type their own, which is what the test does.
    func typeSecure(_ field: XCUIElement, _ text: String) {
        field.tap()
        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 2) { close.tap(); field.tap() }
        field.typeText(text)
    }

    /// Forms move their main button out of the way while typing; the keyboard's OK
    /// puts the keyboard away and brings it back.
    func dismissKeyboard() {
        let ok = app.toolbars.buttons["OK"]
        if app.keyboards.count > 0, ok.waitForExistence(timeout: 2) { ok.tap(); sleep(1) }
    }

    func dump(_ tag: String) {
        // Log structural diagnostics only: debugDescription includes entered values.
        print("Signup UI \(tag): textFields=\(app.textFields.count), secureFields=\(app.secureTextFields.count), alerts=\(app.alerts.count)")
    }

    /// A fresh password for each disposable account, meeting the app's rules (8+
    /// characters, upper and lower case, a number, a symbol). Nothing is hard-coded.
    static func newPassword() -> String { "Qa\(Int.random(in: 100_000...999_999))z!" }

    func testClientSignup() throws { _ = try signUp(caregiver: false) }

    func testCaregiverSignup() throws { _ = try signUp(caregiver: true) }

    /// Uses only the already-completed disposable signup account supplied by root.
    /// No new signup, photo access, upload, account deletion or token corruption.
    func testDisposablePasswordChangeSignsOutAndRequiresExplicitNewPasswordSignIn() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let file = environment["QA_DISPOSABLE_CREDENTIAL_FILE"], !file.isEmpty else {
            throw XCTSkip("Root must supply the private credential file of its completed disposable client signup.")
        }
        let url = URL(fileURLWithPath: file)
        var record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let email = try XCTUnwrap(record["email"] as? String)
        let oldPassword = try XCTUnwrap(record["password"] as? String)
        let expectedRole = try XCTUnwrap(record["role"] as? String)
        try requirePasswordProof(["client", "caregiver"].contains(expectedRole), "Only a completed disposable signup role is authorized")
        try requirePasswordProof(!email.isEmpty && !oldPassword.isEmpty, "Disposable credentials are incomplete")
        try requirePasswordProof(email.lowercased() != environment["QA_EMAIL"]?.lowercased(), "Refusing to change the retained client fixture password")
        try requirePasswordProof(email.lowercased() != environment["QA_CG_EMAIL"]?.lowercased(), "Refusing to change the retained caregiver fixture password")

        app.terminate()
        app.launchArguments = ["--qa-signout", "--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let welcomeSignIn = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(welcomeSignIn.waitForExistence(timeout: 60), "Welcome did not open for native sign-in")
        welcomeSignIn.tap()
        let emailField = app.textFields["Enter your email address..."]
        XCTAssertTrue(emailField.waitForExistence(timeout: 20), "Native sign-in form did not open")
        emailField.tap(); emailField.typeText(email)
        typeSecure(app.secureTextFields["Enter your password..."], oldPassword)
        dismissKeyboard()
        let signIn = app.buttons["Sign In"].firstMatch
        XCTAssertTrue(signIn.exists && signIn.isEnabled, "Native Sign In is not ready")
        signIn.tap()
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60), "Disposable client did not sign in")
        openProfileRow("Change Password")
        XCTAssertTrue(app.navigationBars["Change Password"].waitForExistence(timeout: 15))
        var next = Self.newPassword()
        while next == oldPassword { next = Self.newPassword() }
        typeSecure(app.secureTextFields["Enter your current password..."], oldPassword)
        typeSecure(app.secureTextFields["Enter your new password..."], next)
        typeSecure(app.secureTextFields["Confirm your new password..."], next)
        dismissKeyboard()
        let change = app.buttons["Change Password"].firstMatch
        XCTAssertTrue(change.isEnabled, "Valid password change remained disabled")
        change.tap()
        let confirm = app.alerts.buttons["Confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Password change confirmation did not open")
        // Acknowledged PATCH can change the password even if session recovery
        // fails. Retain the candidate privately before the irreversible request.
        record["pending_password"] = next
        try JSONSerialization.data(withJSONObject: record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        confirm.tap()
        let returnedToStart = welcomeSignIn.waitForExistence(timeout: 60)

        // Capture actual app state before separate verification logins can affect
        // backend sessions. Delay failure until the proven secret is retained.
        let settingsImmediatelyAfterAcknowledgment = app.navigationBars["Change Password"].exists
        let welcomeImmediatelyAfterAcknowledgment = welcomeSignIn.exists
        let requestCounts = app.staticTexts["qa-request-counts"]
        let immediateLedger = requestCounts.exists ? requestCounts.label : "Request-count ledger unavailable"
        let immediateState = XCTAttachment(string: "settings=\(settingsImmediatelyAfterAcknowledgment) welcome=\(welcomeImmediatelyAfterAcknowledgment)\n" + immediateLedger)
        immediateState.name = "password-immediate-post-ack-state-and-request-counts"
        immediateState.lifetime = .keepAlways
        add(immediateState)
        if !hasSensitiveScreen, let dir = environment["QA_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/password-immediate-post-ack-private.png"))
        }

        // Store only a backend-proven change, before later UI/session assertions
        // can fail, so the disposable account remains recoverable.
        func loginForm(_ password: String) -> [String: String] {
            ["email": email, "password": password, "version_app": "1.0.0", "os": "iOS", "version_os": "26"]
        }
        let newLogin = try CarezaarAPI.callWithHTTPStatus("POST", "auth/login", form: loginForm(next))
        try requirePasswordProof((200..<300).contains(newLogin.status), "New-password verification did not return HTTP success")
        let newToken = try XCTUnwrap(CarezaarAPI.result(newLogin.body)["access_token"] as? String)
        try requirePasswordProof(!newToken.isEmpty, "New-password verification returned no usable token")
        let identity = try CarezaarAPI.callWithHTTPStatus("GET", "auth/info", token: newToken)
        try requirePasswordProof((200..<300).contains(identity.status), "Account identity verification did not return HTTP success")
        let currentUser = CarezaarAPI.result(identity.body)
        try requirePasswordProof((currentUser["email"] as? String)?.lowercased() == email.lowercased()
                                 && currentUser["role"] as? String == expectedRole, "Backend authenticated a different account or role")
        let oldLogin = try CarezaarAPI.callWithHTTPStatus("POST", "auth/login", form: loginForm(oldPassword))
        // Verified contract: owned-account-baseline.json records HTTP400 and
        // exactly this English backend message. No empty-token inference.
        try requirePasswordProof(oldLogin.status == 400 && oldLogin.body["message"] as? String == "Invalid Credentials!"
                                 && CarezaarAPI.result(oldLogin.body)["access_token"] == nil,
                                 "Old-password refusal was not the explicit verified backend credential rejection")
        record["password"] = next
        record.removeValue(forKey: "pending_password")
        try JSONSerialization.data(withJSONObject: record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)

        let afterProof = XCTAttachment(string: requestCounts.exists ? requestCounts.label : "Request-count ledger unavailable")
        afterProof.name = "password-after-api-proof-request-counts"
        afterProof.lifetime = .keepAlways
        add(afterProof)
        try requirePasswordProof(returnedToStart, "Verified password change must return to the start screen")
        try requirePasswordProof(!settingsImmediatelyAfterAcknowledgment && welcomeImmediatelyAfterAcknowledgment,
                                 "Confirmed change must end authenticated settings before verification API calls")
        XCTAssertFalse(textContaining("Password changed successfully.").exists)
        XCTAssertFalse(app.buttons["Messages"].exists)
        let presence = app.staticTexts["qa-token-presence"]
        XCTAssertEqual(presence.label, "accessPresent=false;refreshPresent=false")
        XCTAssertTrue(immediateLedger.contains("POST /api/auth/login=1"), "Only the user's initial sign-in is permitted")
        XCTAssertTrue(immediateLedger.contains("PATCH /api/users/password/change=1"), "Password change must be sent once")

        // Ordinary relaunch must stay signed out; it cannot restore old credentials.
        app.terminate()
        app.launchArguments = ["--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        XCTAssertTrue(welcomeSignIn.waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["Messages"].exists)
        XCTAssertEqual(presence.label, "accessPresent=false;refreshPresent=false")
        XCTAssertFalse(requestCounts.label.contains("POST /api/auth/login="))
        XCTAssertFalse(requestCounts.label.contains("GET /api/auth/info="))

        // The user explicitly enters the proven new password in the real form.
        welcomeSignIn.tap()
        XCTAssertTrue(emailField.waitForExistence(timeout: 20))
        emailField.tap(); emailField.typeText(email)
        typeSecure(app.secureTextFields["Enter your password..."], next)
        dismissKeyboard()
        XCTAssertTrue(signIn.isEnabled); signIn.tap()
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        XCTAssertTrue(requestCounts.label.contains("POST /api/auth/login=1"))
        XCTAssertEqual(presence.label, "accessPresent=true;refreshPresent=true")
        app.terminate()
        app.launchArguments = ["--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        XCTAssertFalse(requestCounts.label.contains("POST /api/auth/login="), "Saved new credentials restore without a hidden login")
        openProfileTab()
        XCTAssertTrue(textContaining("Manage your personal information").exists)
        XCTAssertFalse(welcomeSignIn.exists)

    }

    /// Opt-in repair of the exact new caregiver fixture after the retained DOB failure.
    /// Never re-registers or resubmits a role entity; one profile save is journaled first.
    func testRepairOwnedCaregiverBirthDateWithSingleNativeProfileSave() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_OWNED_CAREGIVER_DOB_REPAIR"] == "1", let file = env["QA_ACCOUNT_FILE"] else {
            throw XCTSkip("Primary must authorize this exact new-owned caregiver DOB repair")
        }
        var record = try NativeLifecycleFixture.read(file)
        let provenance = try XCTUnwrap(record["native_provenance"] as? [String: Any])
        let email = try XCTUnwrap(record["email"] as? String)
        let password = try XCTUnwrap(record["password"] as? String)
        let id = try XCTUnwrap(record["user_id"] as? String)
        let marker = try XCTUnwrap(provenance["marker"] as? String)
        try requirePasswordProof(provenance["purpose"] as? String == "carezaar-native-final-qa"
            && provenance["role"] as? String == "caregiver" && record["role"] as? String == "caregiver"
            && provenance["size"] as? String == "modern"
            && provenance["stage"] as? String == "mainIdentityVerified"
            && provenance["provider_create_attempts"] as? Int == 1
            && provenance["app_registration_attempts"] as? Int == 1
            && email.hasPrefix("carezaar-native-\(marker)@") && !id.isEmpty
            && id != env["QA_CG_ID"] && id != env["QA_CLIENT_USER_ID"]
            && record["native_dob_repair"] == nil && record["deleted"] as? Bool != true,
            "Exact unmodified new caregiver checkpoint is required; no repair replay")
        let retained = ["QA_EMAIL", "QA_CLIENT_EMAIL", "QA_CG_EMAIL"].compactMap { env[$0]?.lowercased() }
        try requirePasswordProof(!retained.contains(email.lowercased()), "Retained fixture refused")
        let token = try requireAcceptedLogin(email, password: password, role: "caregiver")
        func ownRead(_ path: String) throws -> [String: Any] {
            let response = try CarezaarAPI.callWithHTTPStatus("GET", path, token: token)
            try requirePasswordProof(response.status == 200, "Owned profile proof requires HTTP200")
            let result = CarezaarAPI.result(response.body)
            let user: [String: Any]
            if path == "auth/info" { user = result }
            else { user = try XCTUnwrap(result["user"] as? [String: Any]) }
            try requirePasswordProof(user["id"].map { String(describing: $0) } == id,
                                    "Exact owned immutable identity must match before/after repair")
            if path == "auth/info" {
                try requirePasswordProof(user["email"] as? String == email && user["role"] as? String == "caregiver",
                                         "Owned auth identity must retain its exact email/role")
            }
            return result
        }
        let contents = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0")
        try requirePasswordProof(contents.status == 200, "Managed labels must load before repair")
        let rows = try XCTUnwrap(contents.body["result"] as? [[String: Any]])
        let label = try XCTUnwrap(rows.first { $0["slug"] as? String == "caregiver_matches_all_matches" })
        signupAllMatchesLabel = try XCTUnwrap((label["translations"] as? [[String: Any]])?.first {
            ($0["language_id"] as? NSNumber)?.intValue == 1 || ($0["language_id"] as? String) == "1"
        }?["name"] as? String)
        app.launchArguments = ["--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        var nativeSetupLoginAttempts = 0
        if !app.buttons["Messages"].waitForExistence(timeout: 20) {
            let welcome = app.buttons["Sign in"].firstMatch
            try requirePasswordProof(welcome.exists && welcome.isHittable, "Unknown startup state; stop before profile mutation")
            welcome.tap()
            let field = app.textFields["Enter your email address..."]
            try requirePasswordProof(field.waitForExistence(timeout: 20) && field.isHittable, "Native sign-in email field must be available"); field.tap(); field.typeText(email)
            typeSecure(app.secureTextFields["Enter your password..."], password)
            dismissKeyboard()
            try requirePasswordProof(nativeSignupRequestCount("POST /api/auth/login") == 0, "No native login may precede its journaled intent")
            nativeSetupLoginAttempts = 1
            record["native_dob_repair"] = ["stage": "nativeLoginIntent", "profilePostAttempts": 0, "nativeSetupLoginAttempts": 1]
            try NativeLifecycleFixture.save(record, file)
            app.buttons["Sign In"].firstMatch.tap()
            try requirePasswordProof(app.buttons["Messages"].waitForExistence(timeout: 60), "Native sign-in must reach Main before repair")
            try requirePasswordProof(nativeSignupRequestCount("POST /api/auth/login") == 1, "Exactly one native setup login is allowed")
        }
        requireNativeSignupMainLoaded(caregiver: true)
        openProfileTab()
        let ownEmail = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", email, email)).firstMatch
        try requirePasswordProof(ownEmail.exists, "The actual native Profile must identify this new caregiver")
        // Snapshot after any necessary visible sign-in, before entering the edit form.
        let beforeAuth = try ownRead("auth/info")
        let before = try ownRead("caregivers/profile")
        let beforeUser = try XCTUnwrap(before["user"] as? [String: Any])
        try requirePasswordProof(beforeUser["date_of_birth"] as? String == "10/11/1990", "Expected exact pre-repair date_of_birth")
        try requirePasswordProof(beforeAuth["date_of_birth"] as? String == "10/11/1990", "Both GETs must preserve the diagnosed pre-repair day")
        try requirePasswordProof(beforeAuth["first_name"] as? String == "Ios" && beforeAuth["last_name"] as? String == "Caregiver", "Both GETs must identify the expected names")
        try requirePasswordProof(beforeUser["gender_id"] != nil && beforeAuth["gender_id"] != nil && String(describing: beforeUser["gender_id"]!) == String(describing: beforeAuth["gender_id"]!), "Both GETs must agree on the existing gender")
        try requirePasswordProof(beforeUser["first_name"] as? String == "Ios", "Expected exact pre-repair first_name")
        try requirePasswordProof(beforeUser["last_name"] as? String == "Caregiver", "Expected exact pre-repair last_name")
        let photo = beforeUser["photo"]
        try requirePasswordProof(photo == nil || photo is NSNull || (photo as? String)?.isEmpty == true,
                                 "Unexpected photo: stop rather than alter an unreviewed uploaded image")
        let backupFolder = URL(fileURLWithPath: file).deletingLastPathComponent()
            .appendingPathComponent("dob-repair-modern-caregiver", isDirectory: true)
        try requirePasswordProof(!FileManager.default.fileExists(atPath: backupFolder.path), "Existing repair evidence preserved; no replay")
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let backup = backupFolder.appendingPathComponent("before-private.json")
        try JSONSerialization.data(withJSONObject: ["authInfo": beforeAuth, "caregiverProfile": before], options: [.sortedKeys])
            .write(to: backup, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        openProfileEdit()
        try requirePasswordProof(app.textFields["Enter your first name"].value as? String == beforeUser["first_name"] as? String, "First name must remain prefilled")
        try requirePasswordProof(app.textFields["Enter your last name"].value as? String == beforeUser["last_name"] as? String, "Last name must remain prefilled")
        try requirePasswordProof(app.buttons["Female"].exists, "The original chosen gender must remain prefilled")
        try requirePasswordProof(!app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Remove Photo")).firstMatch.exists, "No existing photo may be removed")
        selectAdultDateOfBirth()
        let selected = XCTAttachment(screenshot: app.datePickers.firstMatch.screenshot())
        selected.name = "owned-caregiver-selected-birth-date-before-one-save"
        selected.lifetime = .keepAlways; add(selected)
        let displayedDate = app.datePickers.firstMatch.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Date Picker")).firstMatch
        let observedDate = (displayedDate.value as? String ?? "").lowercased()
        try requirePasswordProof(displayedDate.exists && observedDate.contains("1990") && observedDate.contains("12") && observedDate.contains("oct"), "Actual English DatePicker must display October 12, 1990 before Save")
        let forbidden = ["POST /api/auth/register", "POST /api/users/otp/send", "POST /api/users/otp/verify",
            "POST /api/clients", "POST /api/caregivers", "PUT /api/clients/profile", "PUT /api/caregivers/profile",
            "PATCH /api/users/password/change", "POST /api/users/password/reset", "POST /api/users/issues", "DELETE /api/users"]
        for route in forbidden { try requirePasswordProof(nativeSignupRequestCount(route) == 0, "Forbidden mutation before Save") }
        try requirePasswordProof(nativeSignupRequestCount("POST /api/users/profile") == 0, "No profile Save may precede the intent")
        let actualSave = app.buttons["Save"].firstMatch
        try requirePasswordProof(actualSave.waitForExistence(timeout: 10) && actualSave.isHittable && actualSave.isEnabled, "Exact native Save must be ready before journaling its single intent")
        record = try NativeLifecycleFixture.read(file)
        record["native_dob_repair"] = ["stage": "saveIntent", "profilePostAttempts": 1,
            "baselineFile": backup.path, "nativeSetupLoginAttempts": nativeSetupLoginAttempts, "originalSignupFailureRetained": true]
        try NativeLifecycleFixture.save(record, file)
        saveProfile() // Exactly one real native Save tap; never retry this mutation.
        XCTAssertEqual(nativeSignupRequestCount("POST /api/users/profile"), 1)
        for route in forbidden { XCTAssertEqual(nativeSignupRequestCount(route), 0) }
        let writeCounts = app.staticTexts["qa-request-counts"].label
        let afterAuth = try ownRead("auth/info")
        let after = try ownRead("caregivers/profile")
        try JSONSerialization.data(withJSONObject: ["authInfo": afterAuth, "caregiverProfile": after], options: [.sortedKeys])
            .write(to: backupFolder.appendingPathComponent("after-private.json"), options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupFolder.appendingPathComponent("after-private.json").path)
        let afterUser = try XCTUnwrap(after["user"] as? [String: Any])
        XCTAssertEqual(afterAuth["date_of_birth"] as? String, "10/12/1990")
        XCTAssertEqual(afterUser["date_of_birth"] as? String, "10/12/1990")
        func businessFields(_ input: [String: Any]) throws -> Data {
            var copy = input
            copy.removeValue(forKey: "updated_at") // Expected write clock, not a business field.
            if var user = copy["user"] as? [String: Any] {
                user.removeValue(forKey: "date_of_birth"); user.removeValue(forKey: "updated_at")
                copy["user"] = user
            } else { copy.removeValue(forKey: "date_of_birth") }
            return try JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])
        }
        XCTAssertTrue(try businessFields(before) == businessFields(after), "Every other caregiver/profile field must remain unchanged")
        XCTAssertTrue(try businessFields(beforeAuth) == businessFields(afterAuth), "Names, gender, bio, photo and other user fields must remain unchanged")
        expectedSyntheticLocation = (37.7749, -122.4194)
        try verifyNativeSavedProfileAndOrdinaryRelaunch(accountFile: file, email: email,
            password: password, caregiver: true, expectedID: id)
        record = try NativeLifecycleFixture.read(file)
        record["native_dob_repair"] = ["stage": "complete", "profilePostAttempts": 1,
            "baselineFile": backup.path, "nativeSetupLoginAttempts": nativeSetupLoginAttempts, "originalSignupFailureRetained": true]
        try NativeLifecycleFixture.save(record, file)
        let proof = XCTAttachment(string: "role=caregiver;exactOwnedIdentity=true;DOBBefore11After12=true;nativeProfilePOSTs=1;otherProfileFieldsUnchanged=true;signupEntityOTPWrites=0;ordinaryRelaunchVerified=true;hiddenLogin=false;appResponseHTTPStatusNotExported=true\n" + writeCounts)
        proof.name = "owned-caregiver-single-DOB-repair-anonymous"; proof.lifetime = .keepAlways; add(proof)
    }

    /// Existing new caregiver only. No login, profile/entity/provider mutation or journal write.
    func testOwnedCaregiverCurrentListTabsAndOrdinaryRelaunchReadOnly() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_OWNED_CAREGIVER_READONLY_LISTS"] == "1", let file = env["QA_ACCOUNT_FILE"] else {
            throw XCTSkip("Primary must select the exact preserved caregiver fixture")
        }
        let original = try Data(contentsOf: URL(fileURLWithPath: file))
        let record = try NativeLifecycleFixture.read(file)
        let provenance = try XCTUnwrap(record["native_provenance"] as? [String: Any])
        let repair = try XCTUnwrap(record["native_dob_repair"] as? [String: Any])
        let email = try XCTUnwrap(record["email"] as? String)
        let id = try XCTUnwrap(record["user_id"] as? String)
        let marker = try XCTUnwrap(provenance["marker"] as? String)
        try requirePasswordProof(provenance["purpose"] as? String == "carezaar-native-final-qa"
            && provenance["role"] as? String == "caregiver" && record["role"] as? String == "caregiver"
            && provenance["size"] as? String == "modern" && provenance["stage"] as? String == "signupComplete"
            && provenance["provider_create_attempts"] as? Int == 1 && provenance["app_registration_attempts"] as? Int == 1
            && repair["stage"] as? String == "complete" && repair["profilePostAttempts"] as? Int == 1
            && email.hasPrefix("carezaar-native-\(marker)@") && !id.isEmpty
            && id != env["QA_CG_ID"] && id != env["QA_CLIENT_USER_ID"] && record["deleted"] as? Bool != true,
            "Exact completed new-owned caregiver fixture required")
        let retained = ["QA_EMAIL", "QA_CLIENT_EMAIL", "QA_CG_EMAIL"].compactMap { env[$0]?.lowercased() }
        try requirePasswordProof(!retained.contains(email.lowercased()), "Retained fixture refused")
        let contents = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0")
        try requirePasswordProof(contents.status == 200, "Public managed labels must load")
        let rows = try XCTUnwrap(contents.body["result"] as? [[String: Any]])
        func managed(_ key: String) throws -> String {
            let row = try XCTUnwrap(rows.first { $0["slug"] as? String == key })
            return try XCTUnwrap((row["translations"] as? [[String: Any]])?.first {
                ($0["language_id"] as? NSNumber)?.intValue == 1 || ($0["language_id"] as? String) == "1"
            }?["name"] as? String)
        }
        signupAllMatchesLabel = try managed("caregiver_matches_all_matches")
        let messagesLabel = try managed("bottom_navigation_messages")
        let matchesLabel = try managed("bottom_navigation_matches")
        let profileLabel = try managed("bottom_navigation_profile")
        let emptyMessages = try managed("chat_screen_no_messages_yet")
        let emptyDescription = try managed("chat_screen_empty_description")
        func readOnly() throws {
            let ledger = app.staticTexts["qa-request-counts"]
            try requirePasswordProof(ledger.exists, "Native request witness missing")
            let lines = ledger.label.split(separator: "\n").map(String.init)
            try requirePasswordProof(!lines.isEmpty && lines.allSatisfy { $0.hasPrefix("GET ") }, "Only app GETs allowed; no renew/login/logout/read receipt or mutation")
            try requirePasswordProof(app.staticTexts["qa-token-presence"].label == "accessPresent=true;refreshPresent=true", "Existing saved caregiver pair must remain present")
        }
        func tab(_ label: String) throws {
            let target = try XCTUnwrap(app.buttons.matching(identifier: label).allElementsBoundByIndex
                .filter { $0.isHittable }.max { $0.frame.minY < $1.frame.minY })
            try requirePasswordProof(target.isEnabled, "Native bottom tab unavailable")
            target.tap()
        }
        func owner() throws {
            try tab(profileLabel)
            let ownEmail = app.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@", email, email)).firstMatch
            try requirePasswordProof(ownEmail.waitForExistence(timeout: 15), "Native displayed owner must match exact private caregiver")
            try readOnly()
        }
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        app.launchArguments = ["--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        try requirePasswordProof(app.buttons[messagesLabel].waitForExistence(timeout: 60), "Stored caregiver session must already restore; never login to repair this test")
        requireNativeSignupMainLoaded(caregiver: true)
        try readOnly(); try owner()
        try tab(matchesLabel); requireNativeSignupMainLoaded(caregiver: true); try readOnly()
        capture("current-owned-caregiver-loaded-matches-list")
        try tab(messagesLabel)
        let messagesReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.nativeSignupRequestCount("GET /api/users/chats") >= 1
                && self.app.staticTexts[emptyMessages].exists && self.app.staticTexts[emptyDescription].exists
                && !self.app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Try again")).firstMatch.exists
                && !self.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch.exists
        }, object: nil)
        try requirePasswordProof(XCTWaiter.wait(for: [messagesReady], timeout: 40) == .completed,
            "This unused owned account must load the real empty conversation list; unexpected rows require diagnosis, never opening a chat")
        try readOnly(); capture("current-owned-caregiver-loaded-empty-messages-list")
        try tab(matchesLabel); requireNativeSignupMainLoaded(caregiver: true); try readOnly()
        try owner()
        let before = app.staticTexts["qa-request-counts"].label
        app.terminate(); app.launch()
        try requirePasswordProof(app.buttons[messagesLabel].waitForExistence(timeout: 60), "Ordinary relaunch must retain saved session without login")
        requireNativeSignupMainLoaded(caregiver: true)
        try readOnly(); try owner()
        try requirePasswordProof(try Data(contentsOf: URL(fileURLWithPath: file)) == original, "Read-only proof must preserve exact fixture journal bytes")
        let proof = XCTAttachment(string: "role=caregiver;exactNativeDisplayedOwner=true;currentMatchesLoaded=true;realEmptyMessagesLoaded=true;chatOpened=false;allAppRequestsGET=true;ordinaryRelaunch=true;hiddenLogin=false;fixtureJournalUnchanged=true\nBEFORE\n" + before + "\nRELAUNCH\n" + app.staticTexts["qa-request-counts"].label)
        proof.name = "current-owned-caregiver-list-tabs-readonly-anonymous"; proof.lifetime = .keepAlways; add(proof)
    }

    private enum PasswordProofError: Error { case failed(String) }

    private func requirePasswordProof(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PasswordProofError.failed(message) }
    }

    private func requireAcceptedLogin(_ email: String, password: String, role: String) throws -> String {
        let response = try CarezaarAPI.callWithHTTPStatus("POST", "auth/login", form:
            ["email": email, "password": password, "version_app": "1.0.0", "os": "iOS", "version_os": "26"])
        try requirePasswordProof((200..<300).contains(response.status), "Expected successful credential verification")
        let token = try XCTUnwrap(CarezaarAPI.result(response.body)["access_token"] as? String)
        try requirePasswordProof(!token.isEmpty, "Successful login omitted its access token")
        let identity = try CarezaarAPI.callWithHTTPStatus("GET", "auth/info", token: token)
        let user = CarezaarAPI.result(identity.body)
        try requirePasswordProof((200..<300).contains(identity.status)
            && (user["email"] as? String)?.lowercased() == email.lowercased()
            && user["role"] as? String == role, "Successful login authenticated a different account or role")
        return token
    }

    private func requireExplicitCredentialRefusal(_ email: String, password: String) throws {
        let response = try CarezaarAPI.callWithHTTPStatus("POST", "auth/login", form:
            ["email": email, "password": password, "version_app": "1.0.0", "os": "iOS", "version_os": "26"])
        try requirePasswordProof(response.status == 400 && response.body["message"] as? String == "Invalid Credentials!"
            && CarezaarAPI.result(response.body)["access_token"] == nil,
            "Expected explicit backend credential refusal; empty results alone are not proof")
    }

    private func retainPendingPassword(_ password: String) throws {
        let file = try XCTUnwrap(ProcessInfo.processInfo.environment["QA_ACCOUNT_FILE"])
        let url = URL(fileURLWithPath: file)
        var record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        record["pending_password"] = password
        try JSONSerialization.data(withJSONObject: record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }

    /// Resumes only the still-running, already-OTP-verified native flow. Signup
    /// state is memory-only; this cannot recover a terminated application's flow.
    func testResumeDisposableSignupFromOpenProfile() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QA_RESUME_OPEN_SIGNUP_PROFILE"] == "1",
              environment["QA_SIMULATOR_LOCATION_READY"] == "1",
              let file = environment["QA_ACCOUNT_FILE"] else {
            throw XCTSkip("Requires the retained disposable account file and an independently verified still-open post-OTP profile flow.")
        }
        let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: String])
        let email = try XCTUnwrap(record["email"])
        let role = try XCTUnwrap(record["role"])
        XCTAssertTrue(role == "client" || role == "caregiver", "Unexpected disposable signup role")
        XCTAssertFalse(email.isEmpty)
        XCTAssertNotEqual(email, environment["QA_EMAIL"], "Refusing to resume the retained cross-role client")
        XCTAssertNotEqual(email, environment["QA_CG_EMAIL"], "Refusing to resume the retained cross-role caregiver")
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground,
                      "Signup process is no longer running; memory-only flow cannot be recovered by this test")
        app.activate()
        try completeSignupProfileAndPreferences(caregiver: role == "caregiver")
    }

    /// Parity v3 B1: signing in to an account whose sign-up was never finished shows
    /// the server's message and resumes sign-up at the profile step; finishing the
    /// wizard signs in. `PV3_B1_EMAIL`/`PV3_B1_PASSWORD`/`PV3_B1_ROLE` name a staged,
    /// email-verified disposable account without a role entity.
    func testUnfinishedSignupSignInResumesAtProfileStep() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let email = environment["PV3_B1_EMAIL"], let password = environment["PV3_B1_PASSWORD"],
              let role = environment["PV3_B1_ROLE"], environment["QA_SIMULATOR_LOCATION_READY"] == "1" else {
            throw XCTSkip("Requires a staged unfinished account and simulator location permission/GPS.")
        }
        app.launchArguments = ["--qa-signout", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let signIn = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 40))
        signIn.tap()
        let emailField = app.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 10))
        emailField.tap(); emailField.typeText(email)
        let passwordField = app.secureTextFields.firstMatch
        passwordField.tap(); passwordField.typeText(password)
        app.buttons.matching(NSPredicate(format: "label == %@", "Sign In")).firstMatch.tap()
        let message = app.staticTexts["Your registration is not complete. Please complete your profile to continue."]
        XCTAssertTrue(message.waitForExistence(timeout: 30), "The server's message must be shown")
        // iOS may offer to save the typed password; a person can decline it.
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 4) { notNow.tap() }
        XCTAssertTrue(app.textFields["Enter your first name"].waitForExistence(timeout: 10), "Must open the profile step")
        if let dir = environment["QA_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/B1-profile-step-with-server-message.png"))
        }
        try completeSignupProfileAndPreferences(caregiver: role == "caregiver")
    }

    /// A newly created disposable account through everything that changes it:
    /// photo upload, a profile save that must keep the photo (BE-15), Change Password,
    /// Forgot Password with the real emailed code (a wrong code first), and Delete.
    func testClientAccountLifecycle() throws { try accountLifecycle(caregiver: false) }

    func testCaregiverAccountLifecycle() throws { try accountLifecycle(caregiver: true) }

    private func accountLifecycle(caregiver: Bool) throws {
        guard ProcessInfo.processInfo.environment["QA_SYNTHETIC_GALLERY_READY"] == "1" else {
            throw XCTSkip("Root must prepare an isolated simulator gallery containing only the synthetic QA photo before upload.")
        }
        var password = Self.newPassword()
        let inbox: MailTM.Inbox
        let resume = ProcessInfo.processInfo.environment["QA_RESUME_AFTER_LIFECYCLE_PHOTO"] == "1"
        if resume {
            let environment = ProcessInfo.processInfo.environment
            let file = try XCTUnwrap(environment["QA_ACCOUNT_FILE"])
            let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
            let email = try XCTUnwrap(record["email"] as? String)
            password = try XCTUnwrap(record["password"] as? String)
            try requirePasswordProof(record["role"] as? String == (caregiver ? "caregiver" : "client")
                                     && record["pending_password"] == nil && record["deleted"] as? Bool != true,
                                     "Resume requires the exact interrupted role before password mutation")
            let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let retainedEmails = ["QA_EMAIL", "QA_CG_EMAIL", "QA_CLIENT_EMAIL"].compactMap { environment[$0] }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            try requirePasswordProof(!retainedEmails.contains(normalizedEmail), "Refusing retained fixtures")
            inbox = MailTM.Inbox(address: email, token: try XCTUnwrap(record["inbox_token"] as? String))
            _ = try requireAcceptedLogin(email, password: password, role: caregiver ? "caregiver" : "client")
            app.launchEnvironment["QA_EMAIL"] = email
            app.launchEnvironment["QA_PASSWORD"] = password
            app.launchArguments = ["--qa-signout", "--qa-login-env", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
            app.launch()
            XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60))
        } else {
            inbox = try signUp(caregiver: caregiver, password: password)
        }

        // Photo, then a second save that changes only the bio.
        if !resume {
        openProfileEdit()
        let upload = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Upload Photo")).firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 20)); upload.tap()
        app.buttons["Gallery"].tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "photo grid")
        if app.buttons["Close"].exists { app.buttons["Close"].tap() }
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let crop = app.buttons["Confirm"]
        XCTAssertTrue(crop.waitForExistence(timeout: 15)); crop.tap()
        saveProfile()
        }
        var token = try CarezaarAPI.login(inbox.address, password)
        let firstPhoto = try CarezaarAPI.me(token)["photo"] as? String
        XCTAssertNotNil(firstPhoto, "photo not saved")

        openProfileEdit()
        let bio = app.textFields["Tell us a little about yourself."]
        XCTAssertTrue(bio.waitForExistence(timeout: 20)); scrollTo(bio); bio.tap(); bio.typeText("Lifecycle bio")
        dismissKeyboard()
        saveProfile()
        let afterBio = try CarezaarAPI.me(token)
        XCTAssertEqual(afterBio["bio"] as? String, "Lifecycle bio", "bio not saved")
        XCTAssertNotNil(afterBio["photo"] as? String, "saving the bio removed the photo (BE-15)")

        // October13 supersedes the earlier retained-session lifecycle policy.
        openProfileRow("Change Password")
        let previousPasswordForChange = password
        let next = Self.newPassword()
        typeSecure(app.secureTextFields["Enter your current password..."], password)
        typeSecure(app.secureTextFields["Enter your new password..."], next)
        typeSecure(app.secureTextFields["Confirm your new password..."], next)
        dismissKeyboard()
        app.buttons["Change Password"].firstMatch.tap()
        try retainPendingPassword(next)
        app.alerts.buttons["Confirm"].tap()
        let reachedStart = app.buttons["Sign in"].firstMatch.waitForExistence(timeout: 40)
        let authenticatedSettingsRemain = app.navigationBars["Change Password"].exists
        // Preserve the backend-proven disposable secret before later UI assertions.
        _ = try requireAcceptedLogin(inbox.address, password: next, role: caregiver ? "caregiver" : "client")
        try requireExplicitCredentialRefusal(inbox.address, password: previousPasswordForChange)
        password = next
        try saveDisposableAccount(inbox, password: password, caregiver: caregiver)
        XCTAssertTrue(reachedStart, "Confirmed password change must sign out")
        XCTAssertFalse(authenticatedSettingsRemain)
        XCTAssertFalse(textContaining("Password changed successfully.").exists)
        app.terminate()
        app.launchArguments = ["--qa-request-counts"]
        app.launch()
        let welcome = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(welcome.waitForExistence(timeout: 60))
        XCTAssertEqual(app.staticTexts["qa-token-presence"].label, "accessPresent=false;refreshPresent=false")
        XCTAssertFalse(app.staticTexts["qa-request-counts"].label.contains("POST /api/auth/login="))
        XCTAssertFalse(app.staticTexts["qa-request-counts"].label.contains("GET /api/auth/info="))
        welcome.tap()
        let newEmail = app.textFields["Enter your email address..."]
        XCTAssertTrue(newEmail.waitForExistence(timeout: 15))
        newEmail.tap(); newEmail.typeText(inbox.address)
        typeSecure(app.secureTextFields["Enter your password..."], next)
        dismissKeyboard(); app.buttons["Sign In"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60), "Explicit new-password sign-in must succeed")
        XCTAssertTrue(app.staticTexts["qa-request-counts"].label.contains("POST /api/auth/login=1"))
        openProfileTab()

        // Explicit server refusal is different: invalid access AND refresh must clear
        // the session, return to Welcome and remain signed out on the next launch.
        app.terminate()
        app.launchArguments = ["--qa-break-both"]
        app.launch()
        XCTAssertTrue(app.buttons["Sign in"].firstMatch.waitForExistence(timeout: 60), "server-refused access/refresh must end the session")
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["Sign in"].firstMatch.waitForExistence(timeout: 60), "rejected saved credentials restored on the following launch")

        // Forgot Password: code and new password on Set Up Password.
        app.buttons["Sign in"].firstMatch.tap()
        app.buttons["Forgot Password"].tap()
        let resetEmail = app.textFields["Enter your email address..."]
        XCTAssertTrue(resetEmail.waitForExistence(timeout: 10)); resetEmail.tap(); resetEmail.typeText(inbox.address)
        app.buttons["Reset Password"].tap()
        app.alerts.buttons["Confirm"].tap()
        XCTAssertTrue(app.staticTexts["Set Up Password"].waitForExistence(timeout: 30), "Set Up Password screen")
        let boxes = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "One-time code")).firstMatch
        XCTAssertTrue(boxes.waitForExistence(timeout: 10), "code boxes")
        let emailed = try XCTUnwrap(try MailTM.waitForCode(inbox, skipping: 1), "no reset email arrived")
        let wrong = emailed == "00000" ? "11111" : "00000"
        let reset = Self.newPassword()
        boxes.tap(); app.typeText(wrong)
        typeSecure(app.secureTextFields["Enter your password..."], reset)
        typeSecure(app.secureTextFields["Confirm your password..."], reset)
        dismissKeyboard()
        app.buttons["Continue"].firstMatch.tap()
        XCTAssertTrue(textContaining("invalid").waitForExistence(timeout: 20), "a wrong code must be refused under the code boxes")
        XCTAssertTrue(boxes.exists, "a wrong code must stay on Set Up Password")
        boxes.tap()
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + emailed)
        dismissKeyboard()
        try retainPendingPassword(reset)
        app.buttons["Continue"].firstMatch.tap()
        let signIn = app.buttons["Sign In"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 30), "not back on Sign In after the reset")
        _ = try requireAcceptedLogin(inbox.address, password: reset, role: caregiver ? "caregiver" : "client")
        try requireExplicitCredentialRefusal(inbox.address, password: password)
        password = reset
        try saveDisposableAccount(inbox, password: password, caregiver: caregiver)

        // Sign in with the reset password, then delete the account.
        let emailField = app.textFields["Enter your email address..."]
        emailField.tap(); emailField.typeText(inbox.address)
        let pw = app.secureTextFields["Enter your password..."]
        pw.tap(); pw.typeText(password)
        signIn.tap()
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 40), "reset password does not sign in")
        if app.buttons["Not Now"].waitForExistence(timeout: 6) { app.buttons["Not Now"].tap() }
        token = try CarezaarAPI.login(inbox.address, password)
        XCTAssertFalse(token.isEmpty)
        // Delete only this method's newly created disposable account. The root's
        // retained cross-role QA pair must never be consumed by lifecycle cleanup.
        let environment = ProcessInfo.processInfo.environment
        XCTAssertTrue(inbox.address != environment["QA_EMAIL"], "Refusing to delete the retained client QA account")
        XCTAssertTrue(inbox.address != environment["QA_CLIENT_EMAIL"], "Refusing to delete the retained client fixture in a caregiver run")
        XCTAssertTrue(inbox.address != environment["QA_CG_EMAIL"], "Refusing to delete the retained caregiver QA account")
        // Delete Account lives under Help Center (client request, October 2026).
        openProfileRow("Help Center")
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Delete Account")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "Delete Account in Help Center"); entry.tap()
        XCTAssertTrue(app.navigationBars["Delete Account"].waitForExistence(timeout: 15))
        let delete = app.buttons["Delete Account"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 20))
        XCTAssertFalse(delete.isEnabled)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "aware")).firstMatch.tap()
        XCTAssertFalse(delete.isEnabled, "a reason is required")
        app.buttons["Select a reason"].tap()
        let reason = app.buttons[caregiver ? "I found a job" : "I found care elsewhere"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5)); reason.tap()
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        XCTAssertTrue(app.buttons["Sign in"].firstMatch.waitForExistence(timeout: 40), "not signed out after delete")
        try requireExplicitCredentialRefusal(inbox.address, password: password)
    }

    /// Root explicitly attests ownership of the interrupted lifecycle fixture.
    /// This never consumes the retained client/caregiver pair.
    func testDeleteCompletedDisposableLifecycleAccount() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QA_OWNED_LIFECYCLE_DELETION"] == "1",
              let file = environment["QA_ACCOUNT_FILE"] else {
            throw XCTSkip("Requires explicit root-owned interrupted lifecycle fixture")
        }
        let url = URL(fileURLWithPath: file)
        var record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let email = try XCTUnwrap(record["email"] as? String)
        let password = try XCTUnwrap(record["password"] as? String)
        let role = try XCTUnwrap(record["role"] as? String)
        try requirePasswordProof(["client", "caregiver"].contains(role) && record["deleted"] as? Bool != true,
                                 "Refusing an unknown role or already-deleted lifecycle fixture")
        try requirePasswordProof(email != environment["QA_EMAIL"] && email != environment["QA_CG_EMAIL"]
                                 && email != environment["QA_CLIENT_EMAIL"],
                                 "Refusing retained role fixtures")
        _ = try requireAcceptedLogin(email, password: password, role: role)
        app.launchEnvironment["QA_EMAIL"] = email
        app.launchEnvironment["QA_PASSWORD"] = password
        app.launchArguments = ["--qa-signout", "--qa-login-env", "--qa-push", "HelpCenter",
                               "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Delete Account")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 60), "Help Center deletion entry missing")
        entry.tap()
        XCTAssertTrue(app.navigationBars["Delete Account"].waitForExistence(timeout: 15))
        let delete = app.buttons["Delete Account"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 20))
        XCTAssertFalse(delete.isEnabled)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "aware")).firstMatch.tap()
        XCTAssertFalse(delete.isEnabled, "A role-specific reason is required")
        app.buttons["Select a reason"].tap()
        let reason = app.buttons[role == "caregiver" ? "I found a job" : "I found care elsewhere"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5)); reason.tap()
        XCTAssertTrue(delete.isEnabled); delete.tap()
        XCTAssertTrue(app.buttons["Sign in"].firstMatch.waitForExistence(timeout: 40), "Deletion must sign out")
        try requireExplicitCredentialRefusal(email, password: password)
        record["deleted"] = true
        try JSONSerialization.data(withJSONObject: record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }

    /// Bottom-bar Profile tab, retried until Profile is showing (a "Save password?"
    /// sheet after a real sign-in can swallow the first tap).
    private func openProfileTab() {
        let profileScreen = textContaining("Manage your personal information")
        for _ in 0..<5 where !profileScreen.exists {
            if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }
            app.buttons.matching(identifier: "Profile").allElementsBoundByIndex
                .filter { $0.isHittable }.max { $0.frame.minY < $1.frame.minY }?.tap()
            _ = profileScreen.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(profileScreen.exists, "Profile tab")
    }

    private func openProfileRow(_ title: String) {
        openProfileTab()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(title) row")
        scrollTo(row); row.tap()
    }

    private func openProfileEdit() {
        openProfileTab()
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15)); edit.tap()
        // The form's fields exist beneath the loading overlay. Existence alone
        // does not mean the server profile has loaded or the form can be edited.
        let photoAction = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Upload Photo", "Remove Photo")).firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                photoAction.exists && photoAction.isHittable && !self.app.staticTexts["Please wait..."].exists
            }, object: nil
        )], timeout: 60), .completed, "Profile edit must finish loading before interaction")
    }

    private func saveProfile() {
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap()
        // The Profile tab stays in the hierarchy under the form, so wait for the form to close.
        XCTAssertTrue(save.waitForNonExistence(timeout: 60), "profile save did not return")
        XCTAssertTrue(textContaining("Manage your personal information").waitForExistence(timeout: 10), "profile save did not return")
    }

    @discardableResult
    private func signUp(caregiver: Bool, password requestedPassword: String? = nil) throws -> MailTM.Inbox {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QA_SIMULATOR_LOCATION_READY"] == "1",
              let accountFile = environment["QA_ACCOUNT_FILE"], !accountFile.isEmpty,
              let lat = environment["QA_EXPECTED_SIM_LAT"].flatMap(Double.init),
              let lng = environment["QA_EXPECTED_SIM_LNG"].flatMap(Double.init),
              lat.isFinite, lng.isFinite, (-90...90).contains(lat), (-180...180).contains(lng),
              !(lat == 0 && lng == 0) else {
            throw XCTSkip("Root must configure simulator GPS/location permission and provide a private QA_ACCOUNT_FILE before creating a disposable signup account.")
        }
        expectedSyntheticLocation = (lat, lng)
        let inbox = try NativeLifecycleFixture.inbox(accountFile, caregiver: caregiver, environment: environment)
        nativeSignupAccountFile = accountFile
        var nativeRecord = try NativeLifecycleFixture.read(accountFile)
        let password = try XCTUnwrap(requestedPassword ?? nativeRecord["password"] as? String)
        try requirePasswordProof(!password.isEmpty, "Native disposable password is missing")
        nativeRecord["password"] = password
        try NativeLifecycleFixture.save(nativeRecord, accountFile)
        let contents = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0")
        XCTAssertEqual(contents.status, 200)
        let labels = try XCTUnwrap(contents.body["result"] as? [[String: Any]])
        let slug = "\(caregiver ? "caregiver" : "client")_matches_all_matches"
        let row = try XCTUnwrap(labels.first { $0["slug"] as? String == slug })
        signupAllMatchesLabel = try XCTUnwrap((row["translations"] as? [[String: Any]])?.first {
            ($0["language_id"] as? NSNumber)?.intValue == 1 || ($0["language_id"] as? String) == "1"
        }?["name"] as? String)
        print("Signup started for disposable \(caregiver ? "caregiver" : "client") role; credentials omitted.")
        app.launchArguments = ["--qa-signout", "--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", caregiver ? "I’m a caregiver" : "I need care")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 40))
        entry.tap()

        let email = app.textFields["Enter your email address..."]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        // Email and password only: no Country at this step (client request, October 2026).
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Country")).firstMatch.exists,
                       "Country is still asked on Create Account")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "United States")).firstMatch.exists,
                       "US-only wording on Create Account")
        email.tap(); email.typeText(inbox.address)
        typeSecure(app.secureTextFields["Enter your password..."], password)
        typeSecure(app.secureTextFields["Confirm Password"], password)
        // Parity v3 C2: the consent tick-box replaces "I accept the license agreement".
        app.buttons["signup-consent-checkbox"].tap()
        let next = app.buttons["Continue"].firstMatch
        XCTAssertTrue(next.isEnabled, "Continue is always active (parity v3 C1)")
        next.tap()
        let confirm = app.buttons["Confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Are you sure? dialog")
        try NativeLifecycleFixture.stageRegistration(accountFile, inbox: inbox)
        confirm.tap()

        // Disposable credentials, to a file outside the project, as soon as the account
        // exists, so a run that fails later can still clean it up.
        try saveDisposableAccount(inbox, password: password, caregiver: caregiver)

        // OTP from the real email.
        XCTAssertTrue(app.staticTexts["OTP Confirmation"].waitForExistence(timeout: 40), "OTP screen")
        XCTAssertTrue(app.staticTexts["qa-request-counts"].exists)
        XCTAssertEqual(nativeSignupRequestCount("POST /api/auth/register"), 1, "Exactly one native registration request required")
        XCTAssertEqual(nativeSignupRequestCount("POST /api/users/otp/send"), 1, "Exactly one native signup OTP send required")
        let code = try NativeLifecycleFixture.waitForSignupCode(accountFile, inbox: inbox)
        let otpBoxes = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "One-time code")).firstMatch
        XCTAssertTrue(otpBoxes.waitForExistence(timeout: 10), "Native OTP boxes did not appear")
        otpBoxes.tap()
        app.typeText(code)
        let otpContinue = app.buttons["Continue"].firstMatch
        XCTAssertTrue(otpContinue.isEnabled)
        otpContinue.tap()

        try completeSignupProfileAndPreferences(caregiver: caregiver)
        // Preserve the actual native onboarding transport cardinality before
        // the independent owned-identity proof obtains its separate API token.
        XCTAssertEqual(nativeSignupRequestCount("POST /api/auth/register"), 1)
        XCTAssertEqual(nativeSignupRequestCount("POST /api/users/otp/send"), 1)
        XCTAssertEqual(nativeSignupRequestCount("POST /api/users/profile"), 1,
                       "Native signup must submit its profile exactly once")
        XCTAssertEqual(nativeSignupRequestCount(caregiver ? "POST /api/caregivers" : "POST /api/clients"), 1,
                       "Native signup must create its selected role entity exactly once")
        XCTAssertEqual(nativeSignupRequestCount(caregiver ? "POST /api/clients" : "POST /api/caregivers"), 0,
                       "Native signup must not create the opposite role entity")
        try verifyNativeSavedProfileAndOrdinaryRelaunch(accountFile: accountFile, email: inbox.address,
                                                      password: password, caregiver: caregiver)
        return inbox
    }

    /// Recovery of the exact first native fixture after a test-only date-format
    /// assertion failure. This method cannot register, resend, or submit a profile.
    func testResumeOwnedNativeSignupSavedProfileAndOrdinaryRelaunchWithoutRegistration() throws {
        let environment = ProcessInfo.processInfo.environment
        let file = try XCTUnwrap(environment["QA_ACCOUNT_FILE"])
        let record = try NativeLifecycleFixture.read(file)
        let provenance = try XCTUnwrap(record["native_provenance"] as? [String: Any])
        let email = try XCTUnwrap(record["email"] as? String)
        let marker = try XCTUnwrap(provenance["marker"] as? String)
        let id = try XCTUnwrap(record["user_id"] as? String)
        try requirePasswordProof(record["role"] as? String == "client"
            && provenance["role"] as? String == "client"
            && provenance["size"] as? String == "modern"
            && provenance["stage"] as? String == "mainIdentityVerified"
            && provenance["app_registration_attempts"] as? Int == 1
            && provenance["provider_create_attempts"] as? Int == 1
            && email.hasPrefix("carezaar-native-\(marker)@") && !id.isEmpty,
            "Recovery requires the exact existing first Modern/client signup checkpoint")
        let retained = ["QA_EMAIL", "QA_CLIENT_EMAIL", "QA_CG_EMAIL"].compactMap { environment[$0]?.lowercased() }
        try requirePasswordProof(!retained.contains(email.lowercased()), "Retained fixture refused")
        expectedSyntheticLocation = (37.7749, -122.4194)
        let contents = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0")
        XCTAssertEqual(contents.status, 200)
        let rows = try XCTUnwrap(contents.body["result"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["slug"] as? String == "client_matches_all_matches" })
        signupAllMatchesLabel = try XCTUnwrap((row["translations"] as? [[String: Any]])?.first {
            ($0["language_id"] as? NSNumber)?.intValue == 1 || ($0["language_id"] as? String) == "1"
        }?["name"] as? String)
        try verifyNativeSavedProfileAndOrdinaryRelaunch(accountFile: file, email: email,
            password: try XCTUnwrap(record["password"] as? String), caregiver: false, expectedID: id)
    }

    private func verifyNativeSavedProfileAndOrdinaryRelaunch(accountFile: String, email: String,
        password: String, caregiver: Bool, expectedID: String? = nil) throws {
        let environment = ProcessInfo.processInfo.environment
        let role = caregiver ? "caregiver" : "client"
        let token = try requireAcceptedLogin(email, password: password, role: role)
        let identity = try CarezaarAPI.callWithHTTPStatus("GET", "auth/info", token: token)
        let user = CarezaarAPI.result(identity.body)
        let id = try XCTUnwrap(user["id"].map { String(describing: $0) })
        try requirePasswordProof(!id.isEmpty && id != environment["QA_CLIENT_USER_ID"] && id != environment["QA_CG_ID"],
                                 "Native signup must not authenticate a retained fixture identity")
        var nativeRecord = try NativeLifecycleFixture.read(accountFile)
        if let expectedID {
            try requirePasswordProof(id == expectedID, "Read-only signup recovery authenticated a different immutable identity")
        }
        nativeRecord["user_id"] = id
        var provenance = nativeRecord["native_provenance"] as? [String: Any] ?? [:]
        provenance["stage"] = "mainIdentityVerified"
        nativeRecord["native_provenance"] = provenance
        try NativeLifecycleFixture.save(nativeRecord, accountFile)
        let profileResponse = try CarezaarAPI.callWithHTTPStatus("GET", caregiver ? "caregivers/profile" : "clients/profile", token: token)
        XCTAssertEqual(profileResponse.status, 200)
        let profile = CarezaarAPI.result(profileResponse.body)
        let profileUser = try XCTUnwrap(profile["user"] as? [String: Any])
        XCTAssertTrue(profileUser["id"].map { String(describing: $0) } == id, "Owned saved-profile identity mismatch")
        XCTAssertTrue(profileUser["first_name"] as? String == "Ios", "Native entered first name was not persisted")
        XCTAssertTrue(profileUser["last_name"] as? String == (caregiver ? "Caregiver" : "Client"), "Native entered last name was not persisted")
        // The live profile returns MM/dd/yyyy, also consumed by ProfileFormView.prefill.
        // Keep the explicit selected year/day contract rather than assuming ISO wire text.
        let birthFormatter = DateFormatter()
        birthFormatter.locale = Locale(identifier: "en_US_POSIX")
        birthFormatter.calendar = Calendar(identifier: .gregorian)
        birthFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        birthFormatter.dateFormat = "MM/dd/yyyy"
        birthFormatter.isLenient = false
        let rawBirthDate = try XCTUnwrap(profileUser["date_of_birth"] as? String)
        let savedBirthDate = try XCTUnwrap(birthFormatter.date(from: rawBirthDate), "Saved birth date must use the documented profile format")
        XCTAssertEqual(birthFormatter.string(from: savedBirthDate), rawBirthDate, "Saved birth date must round-trip exactly")
        let birthComponents = birthFormatter.calendar.dateComponents([.year, .day], from: savedBirthDate)
        XCTAssertTrue(birthComponents.year == 1990 && birthComponents.day == 12,
                      "Native explicitly selected adult birth year/day was not persisted")
        func number(_ value: Any?) -> Double? {
            (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        }
        XCTAssertEqual(try XCTUnwrap(number(profile["salary_min"])), 20)
        XCTAssertEqual(try XCTUnwrap(number(profile["salary_max"])), 40)
        let expected = try XCTUnwrap(expectedSyntheticLocation)
        XCTAssertEqual(try XCTUnwrap(number(profile["lat"])), expected.lat, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(number(profile["lng"])), expected.lng, accuracy: 0.00001)
        try NativeLifecycleFixture.stage("savedPayLocationVerified", file: accountFile)
        app.terminate()
        app.launchArguments = ["--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launch()
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60), "New signup saved session must restore on ordinary launch")
        XCTAssertTrue(app.staticTexts["My Matches"].waitForExistence(timeout: 30))
        requireNativeSignupMainLoaded(caregiver: caregiver)
        let restoredCounts = app.staticTexts["qa-request-counts"].label
        XCTAssertFalse(restoredCounts.contains("POST /api/auth/login="), "Ordinary new-account restore must not perform a hidden login")
        XCTAssertTrue(restoredCounts.contains("GET /api/auth/info="))
        XCTAssertEqual(app.staticTexts["qa-token-presence"].label, "accessPresent=true;refreshPresent=true")
        let proof = XCTAttachment(string: "role=\(role);exactIdentityVerified=true;savedPayLocationVerified=true;ordinaryRelaunchVerified=true;hiddenLogin=false\n" + restoredCounts)
        proof.name = "native-owned-signup-saved-profile-and-relaunch-anonymous"
        proof.lifetime = .keepAlways; add(proof)
        try NativeLifecycleFixture.stage("signupComplete", file: accountFile)
    }

    private func completeSignupProfileAndPreferences(caregiver: Bool) throws {

        // Tell us about yourself.
        let first = app.textFields["Enter your first name"]
        XCTAssertTrue(first.waitForExistence(timeout: 30), "profile step")
        if first.value as? String != "Ios" { first.tap(); first.typeText("Ios") }
        let last = app.textFields["Enter your last name"]
        let lastName = caregiver ? "Caregiver" : "Client"
        if last.value as? String != lastName { last.tap(); last.typeText(lastName) }
        dismissKeyboard()
        if app.buttons["Select your gender"].exists {
            app.buttons["Select your gender"].tap()
            XCTAssertTrue(app.buttons["Female"].waitForExistence(timeout: 5)); app.buttons["Female"].tap()
        }
        selectAdultDateOfBirth()
        dismissKeyboard()
        let profileContinue = app.buttons["Continue"].firstMatch
        XCTAssertTrue(profileContinue.isEnabled, "profile Continue disabled")
        if let file = nativeSignupAccountFile { try NativeLifecycleFixture.stage("profileSubmitIntent", file: file) }
        profileContinue.tap()

        // Wizard intro (v2 "Find Your Ideal Caregiver").
        let start = app.buttons["Get Started"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 40), "wizard intro")
        if let file = nativeSignupAccountFile { try NativeLifecycleFixture.stage("profileSubmittedWizardIntro", file: file) }
        start.tap()

        // Step 1: care type.
        tapChip("Senior Care", exact: false)
        advance()
        // Step 2: needs.
        for chip in ["Bathing", "Compassionate", "English", "Less than 1 year", "CNA", "TB Test"] { tapChip(chip) }
        advance()
        // Step 3: location, schedule, pay.
        // Parity v3 F1/F3: the phone location is not filled in by itself, and
        // continuing without one names what is missing.
        let hint = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Tap to select location")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 20), "Location must start empty (no automatic phone location)")
        app.buttons["Continue"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Please select a location to continue."].waitForExistence(timeout: 5),
                      "Continuing without a location must say what is missing")
        scrollTo(hint); hint.tap()
        // The map opens on the whole country; the phone location is used only after My Location.
        let myLocation = app.buttons["My location"]
        XCTAssertTrue(myLocation.waitForExistence(timeout: 15), "map picker")
        myLocation.tap()
        let locationPrompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.matching(NSPredicate(
            format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "Carezaar", "location")).firstMatch
        if locationPrompt.waitForExistence(timeout: 5) {
            let allow = locationPrompt.buttons.matching(NSPredicate(format: "label IN %@",
                ["Allow While Using App", "Allow While Using the App"])).firstMatch
            XCTAssertTrue(allow.exists && allow.isHittable, "Actual location prompt must offer While Using")
            allow.tap()
            XCTAssertTrue(locationPrompt.waitForNonExistence(timeout: 10))
        }
        let confirmMap = app.buttons["Confirm"].firstMatch
        XCTAssertTrue(confirmMap.waitForExistence(timeout: 30), "Simulator phone location did not resolve after My Location; root must inspect permission/GPS setup")
        confirmMap.tap()
        let location = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*-?[0-9]+\\.[0-9]{6} , -?[0-9]+\\.[0-9]{6}.*")).firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 10), "Confirmed point must fill the location row")
        if let expected = expectedSyntheticLocation {
            let regex = try NSRegularExpression(pattern: "(-?[0-9]+\\.[0-9]{6}) , (-?[0-9]+\\.[0-9]{6})")
            let label = location.label
            let match = try XCTUnwrap(regex.firstMatch(in: label, range: NSRange(label.startIndex..<label.endIndex, in: label)))
            let latRange = try XCTUnwrap(Range(match.range(at: 1), in: label))
            let lngRange = try XCTUnwrap(Range(match.range(at: 2), in: label))
            XCTAssertEqual(try XCTUnwrap(Double(label[latRange])), expected.lat, accuracy: 0.00001,
                           "Actual native selected latitude differs from the explicitly seeded synthetic fix")
            XCTAssertEqual(try XCTUnwrap(Double(label[lngRange])), expected.lng, accuracy: 0.00001,
                           "Actual native selected longitude differs from the explicitly seeded synthetic fix")
        }
        for chip in ["Up to 5 miles", "Morning: 6 am - 12 pm", "Monday", "One Time"] + (caregiver ? [] : ["Female"]) { tapChip(chip) }
        let minimum = app.textFields["Minimum"]; scrollTo(minimum)
        minimum.tap(); minimum.typeText("20")
        dismissKeyboard()
        let maximum = app.textFields["Maximum"]; scrollTo(maximum)
        maximum.tap(); maximum.typeText("40")
        dismissKeyboard()
        advance()
        // Review, then Save creates the client entity and signs in.
        XCTAssertTrue(textContaining("Review").waitForExistence(timeout: 10), "review step")
        XCTAssertTrue(textContaining("Senior Care").exists, "review shows the care type")
        if let file = nativeSignupAccountFile { try NativeLifecycleFixture.stage("roleEntitySaveIntent", file: file) }
        app.buttons["Save"].firstMatch.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 20) { allow.tap() }
        XCTAssertTrue(app.buttons["Messages"].waitForExistence(timeout: 60), "did not reach Main after Save")
        if let file = nativeSignupAccountFile { try NativeLifecycleFixture.stage("roleEntitySavedMain", file: file) }
        XCTAssertTrue(app.staticTexts["My Matches"].waitForExistence(timeout: 30), "Signup did not open the actual Matches screen")
        XCTAssertTrue(app.buttons.matching(identifier: "Matches").allElementsBoundByIndex.contains { $0.isSelected }, "Matches tab is not selected after signup")

        // The list reflects the backend: cards, or the empty state for a remote location.
        requireNativeSignupMainLoaded(caregiver: caregiver)
    }

    private func requireNativeSignupMainLoaded(caregiver: Bool) {
        let prefix = "GET /api/\(caregiver ? "caregivers" : "clients")/matches="
        let emptyLabel = (signupAllMatchesLabel ?? "All Matches") + " (0)"
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "mile(s) away")).firstMatch
        let retry = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Try again")).firstMatch
        let busy = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let lines = self.app.staticTexts["qa-request-counts"].label.split(separator: "\n")
            let attempts = lines.first { $0.hasPrefix(prefix) }.flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
            let empty = self.app.staticTexts.matching(NSPredicate(format: "label == %@", emptyLabel))
            let actualEmpty = empty.count >= 2 && empty.allElementsBoundByIndex.contains { $0.isHittable }
            return attempts >= 1 && (card.exists || actualEmpty) && !retry.exists && !busy.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 40), .completed,
                       "Native signup Main needs a completed role list with cards or real empty content, not its header alone")
    }

    private func nativeSignupRequestCount(_ path: String) -> Int {
        let prefix = path + "="
        let line = app.staticTexts["qa-request-counts"].label.split(separator: "\n").first { $0.hasPrefix(prefix) }
        return line.flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
    }

    private func selectAdultDateOfBirth() {
        let picker = app.datePickers.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Native Date of birth picker is missing")
        if !app.buttons["DatePicker.Show"].exists { picker.tap() }
        let monthYear = app.buttons["DatePicker.Show"]
        XCTAssertTrue(monthYear.waitForExistence(timeout: 10), "Calendar month/year selector is missing; inspect native calendar accessibility before retrying")
        monthYear.tap()
        let year = app.pickerWheels.matching(NSPredicate(format: "value MATCHES %@", "[0-9]{4}")).firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 10), "Native calendar year wheel is missing")
        year.adjust(toPickerWheelValue: "1990")
        XCTAssertEqual(year.value as? String, "1990", "Calendar did not select the explicit adult birth year")
        let hideYear = app.buttons["DatePicker.Hide"]
        if hideYear.exists { hideYear.tap() } else { monthYear.tap() }
        let day = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", " 12")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 10), "Calendar day 12 is missing after selecting 1990")
        day.tap()
        let dismiss = app.otherElements["PopoverDismissRegion"]
        if dismiss.exists { dismiss.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.42)).tap() }
        XCTAssertTrue(app.buttons["DatePicker.PreviousMonth"].waitForNonExistence(timeout: 10), "Calendar did not close")
        let displayedDate = picker.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Date Picker")).firstMatch
        let selectedAdultYear = NSPredicate { _, _ in
            displayedDate.exists && (displayedDate.value as? String)?.contains("1990") == true
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selectedAdultYear, object: nil)], timeout: 10), .completed,
                       "Date of birth did not retain the selected adult year")
    }

    private func saveDisposableAccount(_ inbox: MailTM.Inbox, password: String, caregiver: Bool) throws {
        guard let file = ProcessInfo.processInfo.environment["QA_ACCOUNT_FILE"] else { return }
        let url = URL(fileURLWithPath: file)
        var record = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        if record["native_provenance"] != nil {
            try requirePasswordProof(record["email"] as? String == inbox.address
                && record["role"] as? String == (caregiver ? "caregiver" : "client"),
                "Cannot overwrite another native disposable fixture")
        }
        record["email"] = inbox.address; record["password"] = password
        record["role"] = caregiver ? "caregiver" : "client"; record["inbox_token"] = inbox.token
        if record["pending_password"] as? String == password { record.removeValue(forKey: "pending_password") }
        try JSONSerialization.data(withJSONObject: record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }

    private func textContaining(_ fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func scrollTo(_ element: XCUIElement, max: Int = 10) {
        var n = 0
        // Clear of the pinned bottom bar, which sits over the scroll content.
        let limit = app.frame.height - 210
        while !(element.exists && element.isHittable && element.frame.maxY < limit) && n < max {
            app.swipeUp(velocity: .slow); n += 1
        }
    }

    private func tapChip(_ label: String, exact: Bool = true) {
        let chip = app.buttons.matching(NSPredicate(format: exact ? "label == %@" : "label BEGINSWITH %@", label)).firstMatch
        scrollTo(chip)
        XCTAssertTrue(chip.exists, "missing chip \(label)")
        for _ in 0..<3 where !chip.isSelected {
            usleep(400_000)          // let any scroll momentum settle
            chip.tap()
        }
    }

    private func advance() {
        let button = app.buttons["Continue"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        sleep(1)
        // No scrolling back up: the next step must open at its own top.
        let stepLabel = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "STEP")).firstMatch
        XCTAssertTrue(stepLabel.waitForExistence(timeout: 5) && stepLabel.isHittable, "the new step did not open at its top")
    }

}

extension XCUIElement {
    var hasFocusCompat: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
