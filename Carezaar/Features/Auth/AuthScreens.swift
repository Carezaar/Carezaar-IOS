import SwiftUI
import PhotosUI

// MARK: - Intro

/// `Intro` — v2 design 16:14997. The frame's own language pill (node "Lanuage") is
/// replaced in place by a working picker.
struct IntroView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var signUp: SignUpFlow
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var language: AppLanguage
    @EnvironmentObject private var loc: Localization
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        FigmaScreen(key: "v2-16-14997", binder: binder, overlays: [
            // The frame's 59pt "Sign in" group cannot hold longer translations; this
            // is the same link as a real control across the row.
            SceneOverlay(x: 20, y: 846, width: 372, height: 32) {
                Button { router.push(.signIn) } label: {
                    HStack(spacing: 6) {
                        Text(loc.t("intro_sign_in", "Sign in"))
                        AppIcon(name: "ic_arrow_forward", size: 14, tint: Theme.Palette.primary)
                            .scaleEffect(x: direction == .rightToLeft ? -1 : 1, y: 1)
                    }
                    .font(Theme.Typography.control(14)).foregroundStyle(Theme.Palette.primaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            },
            SceneOverlay(x: 262, y: 16, width: 134, height: 36) {
                Menu {
                    ForEach(baseData.languages) { item in
                        Button(item.name) { language.select(item); loc.languageId = item.id }
                    }
                } label: {
                    HStack(spacing: 8) {
                        AppIcon(name: "ic_intl", size: 22, tint: .black)
                        Text(baseData.languages.first { $0.id == language.id }?.name ?? "English")
                            .font(Theme.Typography.control(16)).foregroundStyle(.black).lineLimit(1).minimumScaleFactor(0.7)
                        AppIcon(name: "ic_chevron_down", size: 16, tint: .black)
                    }
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.88), in: Capsule())
                }
                .accessibilityLabel("Language")
            }
        ])
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var binder: SceneBinder {
        SceneBinder(handle: { node in
            let label = node.semanticLabel
            if label.contains("sign in") { router.push(.signIn); return true }
            if label.contains("caregiver") { start(.caregiver); return true }
            if label.contains("need care") || node.actionTarget != nil { start(.client); return true }
            return false
        }, text: { node in
            // The server's English for this slug is empty, so the reverse lookup
            // from the scene copy can't find it; map it explicitly.
            guard !language.isEnglish, node.text?.hasPrefix("For myself") == true else { return nil }
            let translated = loc.t("intro_client_description", "")
            return translated.isEmpty ? nil : translated
        }, isHidden: { $0.name == "Lanuage" || $0.name == "Group 1" })
    }

    private func start(_ role: UserRole) {
        signUp.role = role
        signUp.isPasswordRecovery = false
        router.push(.signUpCredentials(role: role))
    }
}

// MARK: - Sign in

/// `SignIn` — v2 design 51:5170. "Forgot Password" and "Sign Up", which Android has
/// but the frame does not, sit in the frame's own gaps.
struct SignInView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var signUp: SignUpFlow
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @State private var email = ""
    @State private var password = ""

    private var canSubmit: Bool { !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty }

    var body: some View {
        FigmaScreen(key: "v2-51-5170", binder: binder, overlays: [
            SceneOverlay(x: 20, y: 409, width: 372, height: 30) {
                HStack {
                    Spacer()
                    Button(loc.t("signin_forgot_password", "Forgot Password")) {
                        signUp.isPasswordRecovery = true
                        router.push(.forgotPassword)
                    }
                    .font(Theme.Typography.control(15)).foregroundStyle(Theme.Palette.primaryText)
                }
            },
            SceneOverlay(x: 20, y: 510, width: 372, height: 50) {
                HStack(spacing: 6) {
                    Text(loc.t("signin_donot_have_account", "Don't have an account yet?"))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Button(loc.t("signin_sign_up", "Sign Up")) { router.popToRoot() }
                        .foregroundStyle(Theme.Palette.primaryText).fontWeight(.bold)
                }
                .font(Theme.Typography.control(15))
            },
        ])
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var binder: SceneBinder {
        SceneBinder(
            binding: { node in
                switch node.inputType {
                case "email": return $email
                case "password": return $password
                default: return nil
                }
            },
            handle: { node in
                if node.isBackButton { router.pop(); return true }
                if node.isPrimaryButton { submit(); return true }
                return false
            },
            isEnabled: { node in node.isPrimaryButton ? canSubmit : true },
            // The content table has no translation for this subtitle; English only.
            isHidden: { node in loc.languageId != 1 && node.text == "Sign in to continue to Carezaar." },
            opacity: { node in node.isPrimaryButton && !canSubmit ? 0.45 : nil }
        )
    }

    private func submit() {
        if let problem = FieldValidator.email(email) { feedback.toast(problem); return }
        Task {
            do {
                try await feedback.run(loc.t("loading_auth_login", "Signing in")) {
                    try await session.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
                }
            } catch {
                feedback.toast(Feedback.message(error))
            }
        }
    }
}

// MARK: - Create account

/// `SignUpCredentials/{role}` — v2 design 56:84378, which holds the full form and the
/// "Are you sure?" dialog. Kotlin sequence: register → hold credentials → otp/send → OTP.
struct SignUpCredentialsView: View {
    let role: UserRole

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var signUp: SignUpFlow
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var revealConfirmation = false
    @State private var accepted = false
    @State private var confirming = false
    @State private var showLicense = false
    @State private var error: String?

    private let authService = AuthService()
    private let userService = UserService()

    /// The frame's rule chips (Frame 5) are drawn in fixed met/unmet states; live
    /// `RuleGlyphChips` replace them.
    private static let ruleChipRow = "56:84399"
    private var valid: Bool {
        FieldValidator.email(email) == nil && PasswordValidator.isValid(password) && password == confirmation && accepted
    }

    var body: some View {
        FigmaScreen(key: "v2-56-84378", binder: binder, overlays: [
            // Overlays sit above the frame; keep the chips out of the confirmation dialog.
            // The client removed Country from this step (location is collected in the
            // preferences), so the frame's fields sit 104 pt higher than in Figma.
            SceneOverlay(x: 20, y: 410, width: 372, height: 32) { RuleGlyphChips(password: password).opacity(confirming ? 0 : 1).allowsHitTesting(!confirming) },
            SceneOverlay(x: 58, y: 460, width: 296, height: 24) {
                (Text("\(loc.t("signup_credentials_email", "Email")): ") + Text(email).foregroundColor(Theme.Palette.primaryText))
                    .font(Theme.Typography.body(12)).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                    .opacity(confirming ? 1 : 0)
            },
            SceneOverlay(x: 68, y: 513, width: 278, height: 56) {
                Group {
                    if revealConfirmation { TextField(loc.t("signup_credentials_confirm_password_placeholder", "Confirm your password..."), text: $confirmation) }
                    else { SecureField(loc.t("signup_credentials_confirm_password_placeholder", "Confirm your password..."), text: $confirmation) }
                }
                .textContentType(.newPassword).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.custom("Vazirmatn", size: 14))
                .accessibilityLabel(loc.t("signup_credentials_confirm_password", "Confirm Password"))
                .hiddenWhile(confirming)
            },
            SceneOverlay(x: 344, y: 521, width: 40, height: 40) {
                Button { revealConfirmation.toggle() } label: { Color.clear }
                    .accessibilityLabel(revealConfirmation ? "Hide password" : "Show password")
                    .hiddenWhile(confirming)
            },
            SceneOverlay(x: 20, y: 572, width: 372, height: 28) {
                HStack(spacing: 8) {
                    Button { accepted.toggle() } label: {
                        AppIcon(name: accepted ? "ic_checkbox_on" : "ic_checkbox_off", size: 22,
                                tint: accepted ? Theme.Palette.primary : Theme.Palette.textSecondary)
                    }
                    .accessibilityLabel(loc.t("signup_credentials_accept_label", "I accept the") + " " + loc.t("signup_credentials_accept_license", "license agreement"))
                    .accessibilityAddTraits(accepted ? [.isSelected] : [])
                    Text(loc.t("signup_credentials_accept_label", "I accept the")).font(Theme.Typography.body(15))
                    Button(loc.t("signup_credentials_accept_license", "license agreement")) { showLicense = true }
                        .font(Theme.Typography.control(15)).foregroundStyle(Theme.Palette.primaryText)
                    Spacer()
                }
                .hiddenWhile(confirming)
            },
        ], scrollTopTrigger: confirming)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showLicense) {
            NavigationStack {
                ScrollView { Text(loc.t("signup_credentials_accept_contents", "")).font(Theme.Typography.body()).padding() }
                    .navigationTitle({ let s = loc.t("signup_credentials_accept_license", "License agreement"); return s.prefix(1).uppercased() + s.dropFirst() }())
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        Button(loc.t("general_confirm", "Confirm")) { accepted = true; showLicense = false }
                    }
            }
        }
    }

    private var binder: SceneBinder {
        SceneBinder(
            binding: { node in
                switch node.inputType {
                case "email": return $email
                case "password": return $password
                default: return nil
                }
            },
            handle: { node in
                let label = node.semanticLabel
                if node.isBackButton { router.pop(); return true }
                if node.isPrimaryButton, label.contains("edit") { confirming = false; return true }
                if node.isPrimaryButton, label.contains("confirm") { confirm(); return true }
                if node.isPrimaryButton { proceed(); return true }
                return false
            },
            isEnabled: { node in
                node.isPrimaryButton && !node.semanticLabel.contains("edit") && !node.semanticLabel.contains("confirm") ? valid : true
            },
            text: { node in
                switch node.name {
                case "Error": return error
                default:
                    if node.text?.hasPrefix("Please review the details below") == true {
                        return loc.t("signup_credentials_confirm_dialog_email_description",
                                     "Please review your email address below. It will be used to continue.")
                    }
                    return nil
                }
            },
            isHidden: { node in
                ((node.name == "Dialog" || node.name == "Rectangle 2931") && !confirming)
                    || node.id == Self.ruleChipRow
                    // Two lines with the values in blue, drawn as an overlay.
                    || node.name == "Credentials"
                    || (node.name == "Error" && error == nil)
                    || node.text == "Confirm your password..."
                    // No translation exists for this hint; the rule chips carry the same rules.
                    || (loc.languageId != 1 && node.text?.hasPrefix("Use 8 or more characters") == true)
            },
            opacity: { node in
                if node.isPrimaryButton, !node.semanticLabel.contains("edit"), !node.semanticLabel.contains("confirm"), !valid { return 0.45 }
                return nil
            }
        )
    }

    private func proceed() {
        if let problem = FieldValidator.email(email) { error = problem; return }
        if !PasswordValidator.isValid(password) { error = loc.t("general_required", "This field is required."); return }
        if password != confirmation { error = loc.t("signup_credentials_password_match", "Passwords do not match."); return }
        error = nil
        // The dialog is part of the scrolling frame; with the keyboard up the frame is
        // scrolled to the field being typed in and the dialog would open out of view.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        confirming = true
    }

    private func confirm() {
        confirming = false
        Task {
            do {
                try await feedback.run(loc.t("loading_auth_register", "Registering")) {
                    _ = try await authService.register(role: role, email: email.trimmingCharacters(in: .whitespaces),
                                                       password: password)
                    signUp.role = role
                    signUp.email = email.trimmingCharacters(in: .whitespaces)
                    signUp.password = password
                    signUp.isPasswordRecovery = false
                    try await userService.sendOTP(email: signUp.email)
                }
                router.push(.otp)
            } catch {
                self.error = Feedback.message(error)
            }
        }
    }
}

// MARK: - OTP

/// `OTP` — five digit boxes over one hidden field, so iOS one-time-code autofill and
/// paste fill all five. Verifying during signup goes straight to the profile step,
/// without signing in, as Android does.
struct OTPView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var signUp: SignUpFlow
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @State private var code = ""
    @State private var secondsLeft = 120
    @FocusState private var focused: Bool

    private let userService = UserService()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Text(loc.t("signup_otp_message", "Kindly enter the 5-digit OTP that we sent to your email."))
                .font(Theme.Typography.title(17)).multilineTextAlignment(.center).padding(.top, Theme.Spacing.xl)
            OTPBoxes(code: $code, focused: $focused)
            PrimaryButton(title: loc.t("signup_otp_continue", "Continue"), isEnabled: code.count == FieldValidator.otpLength) { submit() }
            Text(loc.t("signup_otp_didnot_receive_otp", "Didn't receive the OTP?")).font(Theme.Typography.body(15))
            if secondsLeft > 0 {
                Text(loc.t("signup_otp_wait_to_resend", "Wait for mm:ss to re-send")
                        .replacingOccurrences(of: "mm:ss", with: String(format: "%02d:%02d", secondsLeft / 60, secondsLeft % 60)))
                    .font(Theme.Typography.control(15)).foregroundStyle(Theme.Palette.primaryText)
            } else {
                Button(loc.t("signup_otp_resend", "Re-send")) { resend() }
                    .font(Theme.Typography.control(15)).foregroundStyle(Theme.Palette.primaryText)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.m)
        .background(Theme.Palette.surface)
        .navigationTitle(loc.t("signup_otp_title", "OTP Confirmation"))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(ticker) { _ in if secondsLeft > 0 { secondsLeft -= 1 } }
        .onAppear { focused = true }
    }

    private func submit() {
        Task {
            do {
                try await feedback.run(loc.t("loading_user_otp_verify", "Verifying OTP code")) {
                    try await userService.verifyOTP(email: signUp.email, otp: code)
                }
                router.push(.signUpProfile)
            } catch { feedback.toast(Feedback.message(error)) }
        }
    }

    private func resend() {
        Task {
            do {
                try await feedback.run(loc.t("loading_user_otp_send", "Sending OTP code")) {
                    try await userService.sendOTP(email: signUp.email)
                }
                secondsLeft = 120
            } catch { feedback.toast(Feedback.message(error)) }
        }
    }
}

/// Five digit boxes over one hidden field, so iOS one-time-code autofill and paste
/// fill all five. Shared by OTP and Set Up Password.
struct OTPBoxes: View {
    @Binding var code: String
    var focused: FocusState<Bool>.Binding
    var invalid = false

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad).textContentType(.oneTimeCode).focused(focused)
                .frame(width: 1, height: 1).opacity(0.01)
                .onChange(of: code) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(FieldValidator.otpLength))
                    if digits != new { code = digits }
                }
            HStack(spacing: 12) {
                ForEach(0..<FieldValidator.otpLength, id: \.self) { i in
                    let chars = Array(code)
                    let active = i == chars.count && focused.wrappedValue
                    Text(i < chars.count ? String(chars[i]) : "")
                        .font(.system(size: 28, weight: .bold))
                        .frame(maxWidth: 56).frame(height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(invalid ? Theme.Palette.error : active ? Theme.Palette.primary : Color(hex: 0xC9CED6), lineWidth: 1.2))
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            .contentShape(Rectangle())
            .onTapGesture { focused.wrappedValue = true }
            .accessibilityElement()
            .accessibilityLabel("One-time code, \(code.count) of \(FieldValidator.otpLength) digits")
            .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: - Password recovery

struct ForgotPasswordView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var signUp: SignUpFlow
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @State private var email = ""
    @State private var confirming = false
    private let userService = UserService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text(loc.t("signup_forgot_password_message", "Enter your email for instruction."))
                    .font(Theme.Typography.title(17)).padding(.top, Theme.Spacing.l)
                LabeledField(label: loc.t("signup_forgot_password_email", "Email Address"),
                             placeholder: loc.t("signup_forgot_password_email_placeholder", "Enter your email address..."),
                             text: $email, keyboard: .emailAddress, contentType: .emailAddress)
                PrimaryButton(title: loc.t("signup_forgot_password_reset_password", "Reset Password"),
                              isEnabled: FieldValidator.email(email) == nil) { confirming = true }
            }
            .padding(.horizontal, Theme.Spacing.m)
        }
        .navigationTitle(loc.t("signup_forgot_password_title", "Forgot Password"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(loc.t("signup_forgot_password_dialog_title", "Are You Sure ?"), isPresented: $confirming) {
            Button(loc.t("signup_forgot_password_dialog_deny", "Edit"), role: .cancel) {}
            Button(loc.t("signup_forgot_password_dialog_confirm", "Confirm")) { send() }
        } message: {
            Text("\(loc.t("signup_forgot_password_dialog_description", "You have selected to reset password of below email:"))\n\(email)")
        }
    }

    private func send() {
        Task {
            do {
                try await feedback.run(loc.t("loading_user_otp_send", "Sending OTP code")) {
                    try await userService.sendOTP(email: email.trimmingCharacters(in: .whitespaces))
                }
                signUp.email = email.trimmingCharacters(in: .whitespaces)
                signUp.isPasswordRecovery = true
                // Android's Set Up Password screen carries the code entry itself.
                router.push(.setupPassword)
            } catch { feedback.toast(Feedback.message(error)) }
        }
    }
}

/// `SetupPassword` — Android's screen holds the emailed code (with its own re-send
/// timer) and the new password. `users/password/reset` checks the code itself; the
/// code is never sent to `otp/verify` first, because that uses it up and the reset
/// then answers "The OTP code is invalid!".
struct SetupPasswordView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var signUp: SignUpFlow
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @State private var code = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var codeError: String?
    @State private var secondsLeft = 120
    @FocusState private var codeFocused: Bool
    private let userService = UserService()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var valid: Bool {
        code.count == FieldValidator.otpLength && PasswordValidator.isValid(password) && password == confirmation
    }

    // Figma v2 frame 714:11663.
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                Text(loc.t("signup_setup_password_message", "Kindly enter the 5-digit OTP that we sent to your email."))
                    .font(Theme.Typography.title(17)).multilineTextAlignment(.center).padding(.top, Theme.Spacing.m)
                VStack(spacing: 6) {
                    OTPBoxes(code: $code, focused: $codeFocused, invalid: codeError != nil)
                    if let codeError {
                        Text(codeError).font(Theme.Typography.caption()).foregroundStyle(Theme.Palette.error)
                    }
                }
                .onChange(of: code) { _, _ in codeError = nil }
                LabeledField(label: loc.t("signup_setup_password_password", "Password") + " *",
                             placeholder: loc.t("signup_setup_password_password_placeholder", "Enter your password..."),
                             text: $password, contentType: .newPassword, isSecure: true)
                RuleGlyphChips(password: password).frame(height: 32)
                LabeledField(label: loc.t("signup_setup_password_confirm_password", "Confirm Password") + " *",
                             placeholder: loc.t("signup_setup_password_confirm_password_placeholder", "Confirm your password..."),
                             text: $confirmation, contentType: .newPassword, isSecure: true,
                             error: !confirmation.isEmpty && confirmation != password ? loc.t("signup_credentials_password_match", "Passwords do not match.") : nil)
                PrimaryButton(title: loc.t("signup_setup_password_continue", "Continue"), isEnabled: valid) { submit() }
                    .padding(.top, Theme.Spacing.xs)
                VStack(spacing: 6) {
                    Text(loc.t("signup_setup_password_didnot_receive_otp", "Didn't receive the OTP?")).font(Theme.Typography.body(15))
                    if secondsLeft > 0 {
                        Text(loc.t("signup_setup_password_wait_to_resend", "Wait for mm:ss to re-send")
                                .replacingOccurrences(of: "mm:ss", with: String(format: "%02d:%02d", secondsLeft / 60, secondsLeft % 60)))
                            .font(Theme.Typography.control(15)).foregroundStyle(Theme.Palette.primaryText)
                    } else {
                        Button(loc.t("signup_setup_password_resend", "Re-send")) { resend() }
                            .font(Theme.Typography.control(15)).foregroundStyle(Theme.Palette.primaryText)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.m).padding(.bottom, Theme.Spacing.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(loc.t("general_ok", "OK")) { codeFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    .font(Theme.Typography.control(16))
            }
        }
        .navigationTitle(loc.t("signup_setup_password_title", "Set Up Password"))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(ticker) { _ in if secondsLeft > 0 { secondsLeft -= 1 } }
        .onAppear { codeFocused = true }
    }

    private func submit() {
        Task {
            do {
                try await feedback.run(loc.t("loading_user_password_reset", "Resetting password")) {
                    try await userService.resetPassword(email: signUp.email, otp: code, newPassword: password)
                }
                signUp.reset()
                router.reset(to: .signIn)
            } catch let error as APIError where error.serverMessage.localizedCaseInsensitiveContains("otp") {
                // Wrong or expired code: the server's own message, under the boxes.
                codeError = error.serverMessage
                codeFocused = true
            } catch let error as APIError where error.isServiceFault {
                feedback.toast(Feedback.unavailable(loc.t("signup_forgot_password_title", "Forgot Password")))
            } catch { feedback.toast(Feedback.message(error)) }
        }
    }

    private func resend() {
        Task {
            do {
                try await feedback.run(loc.t("loading_user_otp_send", "Sending OTP code")) {
                    try await userService.sendOTP(email: signUp.email)
                }
                secondsLeft = 120
            } catch { feedback.toast(Feedback.message(error)) }
        }
    }
}

private extension View {
    /// Overlays sit above the frame; without Country the lower fields fall inside the
    /// confirmation dialog, where they would take its taps.
    func hiddenWhile(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).accessibilityHidden(hidden)
    }
}
