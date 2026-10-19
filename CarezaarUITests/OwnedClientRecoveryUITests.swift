import XCTest
import Foundation

/// Exact existing first-client recovery; no signUp, hidden login or proof API login.
final class OwnedClientRecoveryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var j: OwnedClientRecoveryJournal!
    private var snapshots: [[String: Any]] = []
    private var expected: [String:Int] = [:]
    private typealias G = OwnedClientRecoveryJournal
    override func setUp() { continueAfterFailure=false;app=XCUIApplication() }
    override func tearDown() {
        if (testRun?.failureCount ?? 1)>0 { try? j?.event("stopped-no-replay",["nativeLedger":(try? ledger()) ?? [:]]) }
        app?.terminate();super.tearDown() // Never attach credential/OTP screenshots or raw AX.
    }
    private func require(_ value:Bool,_ reason:String)throws {try G.require(value,reason)}
    private func wait(_ reason:String,seconds:TimeInterval=30,_ body:@escaping()->Bool)throws {
        let e=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in body()},object:nil)
        try require(XCTWaiter.wait(for:[e],timeout:seconds) == .completed,reason)
    }
    private func element(_ query:XCUIElementQuery)throws->XCUIElement {
        let e=query.element(boundBy:0);try require(e.waitForExistence(timeout:20)&&query.count==1,"unique-real-control-required");return e
    }
    private func button(_ text:String)throws->XCUIElement {try element(app.buttons.matching(NSPredicate(format:"label == %@",text)))}
    private func ready(_ e:XCUIElement)throws {
        try wait("real-control-ready") {e.exists&&e.isEnabled&&e.isHittable&&self.app.frame.intersects(e.frame)
            && self.app.descendants(matching:.any).matching(NSPredicate(format:"label BEGINSWITH %@","Please wait")).count==0}
    }
    private func tap(_ e:XCUIElement)throws {try ready(e);e.tap()}
    private func ledger()throws->[String:Int] {
        let e=app.staticTexts["qa-request-counts"];try require(e.exists,"real-request-ledger-required")
        var result:[String:Int]=[:]
        for line in e.label.split(separator:"\n") {
            guard let p=line.lastIndex(of:"="),let n=Int(line[line.index(after:p)...]),n>=0 else {throw G.Stop.invariant("malformed-ledger")}
            let key=String(line[..<p]);try require(result[key]==nil,"duplicate-ledger-route");result[key]=n
        };return result
    }
    private func writes()throws {
        let actual=try ledger().filter{!$0.key.hasPrefix("GET ")}
        try j.event("native-ledger",["actual":actual,"expected":expected])
        try require(actual==expected,"unexpected-or-repeated-native-write")
    }
    private func snapshot(_ name:String)throws {
        try writes();snapshots.append(["process":name,"counts":try ledger()]);try j.event("process-snapshot",snapshots.last!)
    }
    private func revealWelcomeSignIn()throws->XCUIElement {
        let welcome=try element(app.buttons.matching(NSPredicate(format:"label == %@","Sign in")))
        let scroll=try element(app.scrollViews.matching(identifier:"v2-16-14997"))
        var swipes=0
        for _ in 0..<8 {
            if welcome.isEnabled&&welcome.isHittable&&app.frame.contains(welcome.frame){break}
            scroll.swipeUp(velocity:.slow);swipes+=1
        }
        try ready(welcome);try require(app.frame.contains(welcome.frame),"complete-Welcome-Sign-in-control-required")
        try writes();try j.event("bounded-actual-Welcome-reveal",["swipes":swipes,"actualIntroScroll":true]);return welcome
    }
    private func alertAction(_ label:String)throws {
        let alert=try element(app.alerts)
        let rows=alert.buttons.matching(NSPredicate(format:"label == %@",label)).allElementsBoundByIndex
        try require(!rows.isEmpty,"real-alert-action-required")
        let frame=rows[0].frame
        try require(!frame.isEmpty&&app.frame.contains(frame)&&alert.frame.contains(frame)
            && rows.allSatisfy{$0.frame==frame&&$0.label==label},"one-alert-physical-action-required")
        let leaves=rows.filter{$0.descendants(matching:.button).count==0}
        try require(leaves.count==1&&leaves[0].isEnabled&&leaves[0].isHittable,"unique-alert-actionable-leaf")
        leaves[0].tap();try require(alert.waitForNonExistence(timeout:10),"alert-not-dismissed-no-retry")
    }
    private func dismissKeyboard()throws {
        if app.keyboards.count>0 {
            let ok=app.toolbars.buttons.matching(NSPredicate(format:"label == %@","OK"))
            if ok.count==1 {try tap(ok.element(boundBy:0))}
        }
    }
    private func typeSecret(_ label:String)throws {
        let field=try element(app.secureTextFields.matching(NSPredicate(format:"identifier == %@ OR label == %@ OR placeholderValue == %@",label,label,label)))
        for _ in 0..<8 where !field.isHittable { app.swipeUp(velocity:.slow) }
        try tap(field)
        // Same recognized new-password chooser as existing SignupTests, but stop
        // on ambiguous Close rather than touching an unrelated dismissal.
        let close=app.buttons.matching(NSPredicate(format:"label == %@","Close"))
        if close.element(boundBy:0).waitForExistence(timeout:2) {
            try require(close.count==1,"unique-password-chooser-Close-required")
            try tap(close.element(boundBy:0));try tap(field)
        }
        field.typeText(j.secret)
    }
    private func declinePasswordSaveIfPresent()throws {
        for owner in [app!,XCUIApplication(bundleIdentifier:"com.apple.springboard")] {
        let sheets=owner.sheets.matching(NSPredicate(format:"label == %@","Save Password?"))
        if !sheets.element(boundBy:0).waitForExistence(timeout:3){continue}
        try require(sheets.count==1,"one-password-save-sheet")
        let sheet=sheets.element(boundBy:0),rows=sheet.buttons.matching(NSPredicate(format:"label == %@","Not Now")).allElementsBoundByIndex
        let leaves=rows.filter{$0.descendants(matching:.button).count==0}
        try require(leaves.count==1,"unique-password-save-decline-leaf")
        let decline=leaves[0],frame=decline.frame
        try require(!frame.isEmpty&&sheet.frame.contains(frame)&&app.frame.contains(frame)&&decline.isEnabled&&decline.isHittable,"contained-password-save-decline")
        Thread.sleep(forTimeInterval:1.5)
        try require(decline.frame==frame&&decline.isHittable&&decline.isEnabled,"stable-password-save-decline")
        try j.event("password-save-decline-intent",["attempt":1]);decline.press(forDuration:0.1)
        try require(sheet.waitForNonExistence(timeout:10),"password-save-sheet-not-dismissed-no-retry")
        return
        }
    }
    private func nativeClientOwner()throws {
        try declinePasswordSaveIfPresent()
        try wait("owned-Main-unblocked-before-profile",seconds:60) {
            self.app.buttons.matching(NSPredicate(format:"label == %@","Profile")).allElementsBoundByIndex.filter{
                $0.exists&&$0.isHittable&&$0.frame.minY>self.app.frame.maxY-110}.count==1
                && self.app.descendants(matching:.any).matching(NSPredicate(format:"label BEGINSWITH %@","Please wait")).count==0
        }
        let profile=app.buttons.matching(NSPredicate(format:"label == %@","Profile")).allElementsBoundByIndex.filter{
            $0.exists&&$0.isHittable&&$0.frame.minY>self.app.frame.maxY-110}
        try require(profile.count==1,"one-native-bottom-Profile")
        if !profile[0].isSelected {try tap(profile[0])}
        let email=try element(app.descendants(matching:.any).matching(NSPredicate(format:"label == %@ AND value == %@","Email Address",j.email)))
        try wait("exact-native-owner-email"){email.value as? String==self.j.email&&email.isHittable&&self.app.frame.contains(email.frame)}
        let counts=try ledger()
        try require(counts["GET /api/clients/matches",default:0]>0&&counts["GET /api/caregivers/matches",default:0]==0,
            "actual-native-client-role-service-required")
        try j.event("native-client-owner-verified",["exactOwnerEmail":true,"actualClientMatchesGET":true,
            "immutableUserIDPreservedFromBoundOriginal":true,"freshBearerIDProofPerformed":false])
    }
    func testRecoverExactOwnedClientThroughFreshMailboxCodeAndOneVisibleNewSecretLogin()throws {
        let env=ProcessInfo.processInfo.environment
        guard env["QA_OWNED_CLIENT_RECOVERY"]=="1",let plan=env["QA_OWNED_CLIENT_RECOVERY_PLAN"] else {throw XCTSkip("Exact reviewed owned client recovery required")}
        j=try G(planFile:plan)
        // No --qa-signout/login-env/push/offline hooks. Existing failed saved
        // credentials may naturally clear to Welcome through normal session UX.
        app.launchArguments=["--qa-request-counts","-carezaar.languageId","1","-carezaar.languageCode","en"]
        app.launchEnvironment=[:];app.launch()
        try wait("natural-Main-or-Welcome",seconds:120){self.app.buttons["Messages"].exists||self.app.buttons["Sign in"].exists}
        let initial=try ledger().filter{!$0.key.hasPrefix("GET ")}
        try require(initial.isEmpty || initial == ["PUT /api/auth/refresh":1],"only-one-natural-saved-session-refresh-before-recovery")
        expected=initial;try j.event("natural-startup-observed",["nonGET":initial,"hiddenLogin":false])
        if app.buttons["Messages"].exists {
            try nativeClientOwner();try writes()
            let row=try element(app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Log Out")))
            for _ in 0..<10 where !row.isHittable {app.swipeUp(velocity:.slow)}
            try tap(row);try j.intent("optional-visible-logout",method:"DELETE",route:"auth/logout")
            try alertAction("Confirm");expected["DELETE /api/auth/logout"]=1
            try wait("actual-logout-to-Welcome",seconds:45){self.app.buttons["Sign in"].exists};try writes()
        }
        try tap(try revealWelcomeSignIn())
        let forgot=try button("Forgot Password");try tap(forgot)
        let email=try element(app.textFields.matching(NSPredicate(format:"identifier == %@ OR label == %@ OR placeholderValue == %@","Enter your email address...","Enter your email address...","Enter your email address...")))
        try tap(email);email.typeText(j.email);try dismissKeyboard()
        try require(email.value as? String==j.email,"exact-owned-recovery-email")
        // pending secret already durable before this provider boundary or any email.
        let boundary=try j.boundary()
        try tap(try button("Reset Password"))
        try j.intent("single-OTP-email-send",method:"POST",route:"users/otp/send")
        try alertAction("Confirm");expected["POST /api/users/otp/send"]=1
        try wait("real-Set-Up-Password",seconds:45){self.app.staticTexts["Set Up Password"].exists||self.app.navigationBars["Set Up Password"].exists};try writes()
        let code=try j.freshCode(boundary) // Persists OTP in pending private_otp_values BEFORE typing.
        let boxes=try element(app.descendants(matching:.any).matching(NSPredicate(format:"label BEGINSWITH %@","One-time code")))
        try tap(boxes);app.typeText(code)
        try wait("five-code-digits-in-real-control"){self.app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","One-time code, 5 of 5 digits")).count==1}
        try typeSecret("Enter your password...");try typeSecret("Confirm your password...");try dismissKeyboard()
        let save=try button("Continue")
        for _ in 0..<8 where !save.isHittable { app.swipeUp(velocity:.slow) }
        try ready(save)
        try j.intent("single-password-reset",method:"POST",route:"users/password/reset")
        try tap(save);expected["POST /api/users/password/reset"]=1
        try wait("reset-returned-real-Sign-In",seconds:45){self.app.buttons["Sign In"].exists};try writes()
        let signEmail=try element(app.textFields.matching(NSPredicate(format:"identifier == %@ OR label == %@ OR placeholderValue == %@","Enter your email address...","Enter your email address...","Enter your email address...")))
        let current=signEmail.value as? String ?? ""
        try require(current.isEmpty||current==signEmail.placeholderValue,"fresh-empty-Sign-In-email-required")
        try tap(signEmail);signEmail.typeText(j.email);try typeSecret("Enter your password...");try dismissKeyboard()
        try j.intent("single-visible-new-secret-login",method:"POST",route:"auth/login")
        try tap(try button("Sign In"));expected["POST /api/auth/login"]=1
        try wait("new-secret-visible-login-Main",seconds:90){self.app.buttons["Messages"].exists}
        try nativeClientOwner();try snapshot("recovery-and-new-login")
        app.terminate();expected=[:];app.launch()
        try wait("ordinary-new-session-relaunch",seconds:90){self.app.buttons["Messages"].exists}
        try require(app.staticTexts["qa-token-presence"].label=="accessPresent=true;refreshPresent=true","new-session-pair-durable")
        try nativeClientOwner();try snapshot("ordinary-saved-client-relaunch")
        try j.confirmVersion(nativeLedgers:snapshots)
    }
}
