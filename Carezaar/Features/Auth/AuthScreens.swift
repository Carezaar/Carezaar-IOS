import SwiftUI
import PhotosUI
import WebKit

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
    @Environment(\.dynamicTypeSize) private var typeSize

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
            }
        ])
        // A live control needs native text geometry: the scene's fixed overlay
        // height and whole-frame scaling cannot accommodate Dynamic Type.
        .overlay(alignment: .topTrailing) {
            Menu {
                ForEach(baseData.languages) { item in
                    Button(item.name) { language.select(item); loc.languageId = item.id }
                }
            } label: {
                HStack(spacing: 8) {
                    AppIcon(name: "ic_intl", size: 22, tint: .black)
                    Text(baseData.languages.first { $0.id == language.id }?.name ?? "English")
                        .font(Theme.Typography.control(16)).foregroundStyle(.black)
                        .fixedSize(horizontal: false, vertical: true)
                    AppIcon(name: "ic_chevron_down", size: 16, tint: .black)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.white.opacity(0.88), in: Capsule())
            }
            .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 174)
            .accessibilityLabel("Language")
            .accessibilityValue(baseData.languages.first { $0.id == language.id }?.name ?? "English")
            .padding(.horizontal, 16).padding(.top, 16)
        }
        .disabled(!baseData.isReady)
        .safeAreaInset(edge: .bottom) {
            if !baseData.isReady {
                VStack(spacing: 12) {
                    Text(loc.t("general_network_title", "Cannot communicate with server."))
                        .font(Theme.Typography.body()).multilineTextAlignment(.center)
                    if baseData.failed {
                        PrimaryButton(title: loc.t("general_try_again", "Try Again")) {
                            Task { await baseData.bootstrap() }
                        }
                    } else { ProgressView() }
                }
                .padding(16).background(.white)
                .accessibilityIdentifier("welcome-reference-gate")
            }
        }
        .task { if !baseData.isReady { await baseData.bootstrap() } }
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
        guard baseData.isReady else { return }
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
        guard canSubmit else { return }
        Task {
            do {
                try await feedback.run(loc.t("loading_auth_login", "Signing in")) {
                    try await session.signIn(email: email, password: password)
                }
            } catch let incomplete as RegistrationIncompleteError {
                // B1: show the server's message and resume sign-up at the profile
                // step with the credentials just entered (the role comes from meta).
                feedback.toast(incomplete.message.isEmpty ? Feedback.message(APIError.unknown("")) : incomplete.message)
                signUp.resume(role: incomplete.role ?? .client, email: email.trimmingCharacters(in: .whitespaces), password: password)
                router.push(.signUpProfile)
            } catch {
                feedback.toast(Feedback.message(error))
            }
        }
    }
}

// MARK: - Create account

/// `SignUpCredentials/{role}` — v2 design 56:84378, which holds the full form and the
/// "Are you sure?" dialog. Kotlin sequence: register → hold credentials → otp/send → OTP.
///
/// Parity review v3: Continue is always active and checks every field at once,
/// showing each problem under its own field (C1); the consent sentence names the
/// Terms of Use and Privacy Policy, each opening an in-app viewer (C2); the dialog
/// uses the managed description (C3); and a created account whose code could not be
/// sent still opens the code screen (C4).
struct SignUpCredentialsView: View {
    let role: UserRole
    typealias Field = SignUpCredentialsValidation.Field

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var signUp: SignUpFlow
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var revealPassword = false
    @State private var revealConfirmation = false
    @State private var accepted = false
    @State private var confirming = false
    @State private var document: LegalDocument?
    @State private var errors: [Field: String] = [:]

    private let authService = AuthService()
    private let userService = UserService()

    /// The frame's rule chips (Frame 5) are drawn in fixed met/unmet states; live
    /// `RuleGlyphChips` replace them.
    private static let ruleChipRow = "56:84399"
    /// The frame's Continue button; it moves down to make room for the consent
    /// sentence and any errors below the confirmation field.
    private static let continueButton = "56:84406"
    private static let continueButtonY: CGFloat = 601

    // Scene geometry below the confirmation field (its box ends at 569).
    private var confirmErrorHeight: CGFloat { errors[.confirmation] == nil ? 0 : 24 }
    private var consentY: CGFloat { 572 + confirmErrorHeight }
    private static let consentHeight: CGFloat = 50
    private var agreementErrorHeight: CGFloat { errors[.agreement] == nil ? 0 : 24 }
    private var buttonY: CGFloat { consentY + Self.consentHeight + agreementErrorHeight + 6 }

    var body: some View {
        FigmaScreen(key: "v2-56-84378", binder: binder, overlays: [
            // Activate the existing scene eye beside the main password input.
            SceneOverlay(x: 344, y: 336, width: 40, height: 40) {
                Button { revealPassword.toggle() } label: { Color.clear }
                    .accessibilityLabel(revealPassword ? "Hide password" : "Show password")
                    .hiddenWhile(confirming)
            },
            SceneOverlay(x: 20, y: 264, width: 372, height: 38) {
                fieldError(.email).hiddenWhile(confirming)
            },
            SceneOverlay(x: 20, y: 386, width: 372, height: 22) {
                fieldError(.password).hiddenWhile(confirming)
            },
            // Overlays sit above the frame; keep the chips out of the confirmation dialog.
            // The client removed Country from this step (location is collected in the
            // preferences), so the frame's fields sit 104 pt higher than in Figma.
            SceneOverlay(x: 20, y: 410, width: 372, height: 32) { RuleGlyphChips(password: password).opacity(confirming ? 0 : 1).allowsHitTesting(!confirming) },
            // C3: the managed sentence as written (the frame's node is styled in
            // Title Case, which the managed text and Android do not use).
            SceneOverlay(x: 58, y: 388, width: 296, height: 40) {
                Text(loc.t("signup_credentials_confirm_dialog_description",
                           "Please review the details below. The email address will be used to continue."))
                    .font(.custom("Vazirmatn", fixedSize: 12)).foregroundStyle(.black)
                    .multilineTextAlignment(.center).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(confirming ? 1 : 0)
                    .accessibilityHidden(!confirming)
            },
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
            SceneOverlay(x: 20, y: 571, width: 372, height: 22) {
                fieldError(.confirmation).hiddenWhile(confirming)
            },
            SceneOverlay(x: 20, y: consentY, width: 372, height: Self.consentHeight) {
                consentRow.hiddenWhile(confirming)
            },
            SceneOverlay(x: 20, y: consentY + Self.consentHeight, width: 372, height: 22) {
                fieldError(.agreement).hiddenWhile(confirming)
            },
        ], scrollTopTrigger: confirming)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $document) { LegalDocumentView(document: $0) }
        .onChange(of: email) { _, _ in errors[.email] = nil }
        .onChange(of: password) { _, _ in errors[.password] = nil }
        .onChange(of: confirmation) { _, _ in errors[.confirmation] = nil }
        .onChange(of: accepted) { _, on in if on { errors[.agreement] = nil } }
    }

    /// One field's problem, directly under that field.
    @ViewBuilder private func fieldError(_ field: Field) -> some View {
        if let message = errors[field] {
            Text(message)
                .font(.custom("Vazirmatn", fixedSize: 12)).foregroundStyle(Theme.Palette.error)
                .lineLimit(2).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("signup-error-\(field)")
        }
    }

    // MARK: consent (C2)

    private var termsName: String { loc.t("signup_credentials_terms_of_use", "Terms of Use") }
    private var privacyName: String { loc.t("signup_credentials_privacy_policy", "Privacy Policy") }
    private var consentTemplate: String {
        loc.t("signup_credentials_consent", "I agree to the {TERMS_OF_USE} and acknowledge that I have read the {PRIVACY_POLICY}.")
    }
    private var consentPlain: String {
        consentTemplate.replacingOccurrences(of: "{TERMS_OF_USE}", with: termsName)
            .replacingOccurrences(of: "{PRIVACY_POLICY}", with: privacyName)
    }

    /// The managed sentence with the two document names underlined and tappable.
    private var consentText: AttributedString {
        var result = AttributedString()
        var rest = Substring(consentTemplate)
        let names: [(String, LegalDocument)] = [("{TERMS_OF_USE}", .termsOfUse), ("{PRIVACY_POLICY}", .privacyPolicy)]
        while !rest.isEmpty {
            let next = names.compactMap { token, doc in rest.range(of: token).map { ($0, doc) } }
                .min { $0.0.lowerBound < $1.0.lowerBound }
            guard let (range, doc) = next else { result += AttributedString(String(rest)); break }
            result += AttributedString(String(rest[..<range.lowerBound]))
            var link = AttributedString(doc == .termsOfUse ? termsName : privacyName)
            link.link = doc.linkURL
            link.underlineStyle = .single
            link.foregroundColor = Theme.Palette.primaryText
            result += link
            rest = rest[range.upperBound...]
        }
        return result
    }

    private var consentRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { accepted.toggle() } label: {
                AppIcon(name: accepted ? "ic_checkbox_on" : "ic_checkbox_off", size: 22,
                        tint: accepted ? Theme.Palette.primary : Theme.Palette.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(consentPlain)
            .accessibilityAddTraits(accepted ? [.isSelected] : [])
            .accessibilityIdentifier("signup-consent-checkbox")
            // The scene has fixed geometry (it does not grow with Dynamic Type), so the
            // sentence uses the frame's fixed type size; no scale factor, which would
            // also misplace the link rects.
            Text(consentText)
                .font(.custom("Vazirmatn", fixedSize: 14)).foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    if let doc = LegalDocument(linkURL: url) { document = doc }
                    return .handled
                })
                .accessibilityAction(named: termsName) { document = .termsOfUse }
                .accessibilityAction(named: privacyName) { document = .privacyPolicy }
                .accessibilityIdentifier("signup-consent-text")
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
            isPasswordRevealed: { node in node.inputType == "password" && revealPassword },
            handle: { node in
                let label = node.semanticLabel
                if node.isBackButton { router.pop(); return true }
                if node.isPrimaryButton, label.contains("edit") { confirming = false; return true }
                if node.isPrimaryButton, label.contains("confirm") { confirm(); return true }
                if node.isPrimaryButton { proceed(); return true }
                return false
            },
            isHidden: { node in
                ((node.name == "Dialog" || node.name == "Rectangle 2931") && !confirming)
                    || node.id == Self.ruleChipRow
                    // Two lines with the values in blue, drawn as an overlay.
                    || node.name == "Credentials"
                    // The dialog description is drawn as an overlay (C3).
                    || node.id == "56:84503"
                    // Field errors are drawn under each field as overlays.
                    || node.name == "Error"
                    || node.text == "Confirm your password..."
                    // No translation exists for this hint; the rule chips carry the same rules.
                    || (loc.languageId != 1 && node.text?.hasPrefix("Use 8 or more characters") == true)
            },
            yOffset: { node in
                node.id == Self.continueButton ? Double(buttonY - Self.continueButtonY) : nil
            }
        )
    }

    private func proceed() {
        let problems = SignUpCredentialsValidation.problems(
            email: email, password: password, confirmation: confirmation, accepted: accepted) { loc.t($0, $1) }
        errors = problems
        guard problems.isEmpty else {
            UIAccessibility.post(notification: .announcement,
                                 argument: Field.allCases.compactMap { problems[$0] }.joined(separator: ". "))
            return
        }
        // The dialog is part of the scrolling frame; with the keyboard up the frame is
        // scrolled to the field being typed in and the dialog would open out of view.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        confirming = true
    }

    private func confirm() {
        confirming = false
        let address = email.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await feedback.run(loc.t("loading_auth_register", "Registering")) {
                    _ = try await authService.register(role: role, email: address, password: password)
                }
            } catch {
                if case .validation(_, let fields) = error as? APIError,
                   fields["email"] != nil || fields["password"] != nil {
                    errors[.email] = fields["email"]?.first
                    errors[.password] = fields["password"]?.first
                } else {
                    feedback.toast(Feedback.message(error))
                }
                return
            }
            signUp.role = role
            signUp.email = address
            signUp.password = password
            signUp.isPasswordRecovery = false
            signUp.otpSendFailed = false
            do {
                try await feedback.run(loc.t("loading_user_otp_send", "Sending OTP code")) {
                    try await userService.sendOTP(email: address)
                }
            } catch {
                // C4: the account exists now; the code screen is where another code
                // can be requested, so open it anyway and say what went wrong.
                signUp.otpSendFailed = true
                feedback.toast(Feedback.message(error))
            }
            router.push(.otp)
        }
    }
}

/// The two documents named in the sign-up consent (C2).
enum LegalDocument: String, Identifiable {
    case termsOfUse, privacyPolicy
    var id: String { rawValue }

    var linkURL: URL { URL(string: "carezaar-legal://\(rawValue)")! }
    init?(linkURL: URL) {
        guard linkURL.scheme == "carezaar-legal", let doc = LegalDocument(rawValue: linkURL.host ?? "") else { return nil }
        self = doc
    }

    var titleSlug: (String, String) {
        switch self {
        case .termsOfUse: ("signup_credentials_terms_of_use", "Terms of Use")
        case .privacyPolicy: ("signup_credentials_privacy_policy", "Privacy Policy")
        }
    }

    /// The bundled PDF (nil only if it is missing from the build).
    var url: URL? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--qa-legal-url"), i + 1 < args.count { return URL(string: args[i + 1]) }
        #endif
        let name = self == .termsOfUse ? LegalDocumentConfiguration.termsOfUseFile : LegalDocumentConfiguration.privacyPolicyFile
        return Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "Assets/legal")
    }
}

/// In-app document viewer: scrollable and pinch-zoomable. Without a configured
/// document address it shows the managed "not available" text.
struct LegalDocumentView: View {
    let document: LegalDocument
    @EnvironmentObject private var loc: Localization
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let url = document.url, !failed {
                    LegalWebView(url: url, failed: $failed)
                } else {
                    VStack(spacing: Theme.Spacing.s) {
                        AppIcon(name: "ic_info_circle", size: 40, tint: Theme.Palette.textSecondary)
                            .accessibilityHidden(true)
                        Text(loc.t("general_error_not_found", "This item is no longer available."))
                            .font(Theme.Typography.body()).multilineTextAlignment(.center)
                            .accessibilityIdentifier("legal-document-unavailable")
                    }
                    .padding(Theme.Spacing.l)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(loc.t(document.titleSlug.0, document.titleSlug.1))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.t("general_ok", "OK")) { dismiss() }
                }
            }
        }
    }
}

/// WebKit renders HTML and PDF documents with native scrolling and pinch zoom.
private struct LegalWebView: UIViewRepresentable {
    let url: URL
    @Binding var failed: Bool

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.scrollView.minimumZoomScale = 1
        view.scrollView.maximumZoomScale = 5
        view.allowsBackForwardNavigationGestures = false
        view.accessibilityIdentifier = "legal-document"
        if url.isFileURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: url, timeoutInterval: APIConfiguration.requestTimeout))
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(failed: $failed) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let failed: Binding<Bool>
        init(failed: Binding<Bool>) { self.failed = failed }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed.wrappedValue = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed.wrappedValue = true }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let http = response.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failed.wrappedValue = true
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
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
        .onAppear {
            focused = true
            // C4: no code was sent, so Re-send is available at once.
            if signUp.otpSendFailed { secondsLeft = 0 }
        }
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
                signUp.otpSendFailed = false
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
            } catch {
                if let message = Feedback.otpInlineMessage(error) {
                    codeError = message
                    codeFocused = true
                } else if let api = error as? APIError, api.isServiceFault {
                    feedback.toast(Feedback.unavailable(loc.t("signup_forgot_password_title", "Forgot Password")))
                } else { feedback.toast(Feedback.message(error)) }
            }
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
