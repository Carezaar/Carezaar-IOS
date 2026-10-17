import SwiftUI
import CoreText

@main
struct CarezaarApp: App {
    init() {
        if let url = SourceStore.assetURL("Vazirmatn.ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        #if DEBUG
        QALaunch.prepare()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // `--design-catalog` opens the Figma scene renderer used for visual QA
            // instead of the product. Debug only: Release strips its scenes.
            if ProcessInfo.processInfo.arguments.contains("--design-catalog") {
                DesignCatalogRoot()
            } else {
                CarezaarRoot()
            }
            #else
            CarezaarRoot()
            #endif
        }
    }
}

/// The startup graph is independent of whether reference data can be used yet.
/// Reference readiness still gates every Welcome continuation.
enum StartupDestination: Equatable {
    case splash, welcome, main
    static func resolve(state: SessionManager.State, referencesReady: Bool, savedSessionRejected: Bool) -> Self {
        if state == .signedOut && savedSessionRejected { return .welcome }
        if !referencesReady || state == .loading { return .splash }
        return state.user == nil ? .welcome : .main
    }
}

/// The product root. Swaps between the unauthenticated and authenticated graphs on
/// session state, the way the Android `Splash` route and `AppNavHost` do.
struct CarezaarRoot: View {
    @StateObject private var session = SessionManager()
    @StateObject private var recovery = SessionRecoveryCoordinator.shared
    @StateObject private var router = AppRouter()
    @StateObject private var baseData = BaseDataStore()
    @StateObject private var signUp = SignUpFlow()
    @StateObject private var language = AppLanguage.shared
    @StateObject private var feedback = Feedback()
    @StateObject private var poller = NotificationPoller()
    @Environment(\.scenePhase) private var scenePhase

    /// `--qa-route <identifier>` opens a single screen at launch so every route can
    /// be captured for review without driving the UI. Debug builds only.
    private var qaRoute: Route? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let value = args.drop(while: { $0 != "--qa-route" }).dropFirst().first else { return nil }
        return Route.allUnauthenticated.first { $0.identifier == value }
        #else
        return nil
        #endif
    }

    /// True when the selected language is marked `is_rtl` by the backend.
    private var isRightToLeft: Bool {
        baseData.languages.first { $0.id == language.id }?.isRtl ?? false
    }

    var body: some View {
        Group {
            if let qaRoute {
                NavigationStack { destination(qaRoute) }
            } else {
                switch StartupDestination.resolve(state: session.state, referencesReady: baseData.isReady, savedSessionRejected: session.savedSessionRejected) {
                case .splash:
                    SplashView()
                case .welcome:
                    NavigationStack(path: $router.path) {
                        IntroView().navigationDestination(for: Route.self) { destination($0) }
                    }
                case .main:
                    // Every signed-in user goes to Main; there is no verification step
                    // (Background Check removed at the client's request, October 2026).
                    NavigationStack(path: $router.path) {
                        MainView().navigationDestination(for: Route.self) { destination($0) }
                    }
                }
            }
        }
        // Inside the environment objects below: the overlay reads Feedback and Localization.
        .feedbackOverlay()
        .alert(baseData.localization.t("general_session_renewal_title", "Connection Problem"),
               isPresented: Binding(get: { recovery.isPresented }, set: { _ in })) {
            Button(baseData.localization.t("general_retry", "Retry")) { Task { await recovery.retry() } }
        } message: {
            Text(baseData.localization.t("general_session_renewal_message",
                "We could not reach the server to renew your sign-in. Please check your internet connection and try again."))
        }

        #if DEBUG
        .overlay(alignment: .topTrailing) { QARequestCountsView() }
        #endif
        // System controls (sheet toolbar buttons, alerts' tinted actions) use the text
        // shade of the brand blue, which meets WCAG AA as small text.
        .tint(Theme.Palette.primaryText)
        .environmentObject(session)
        .environmentObject(router)
        .environmentObject(baseData)
        .environmentObject(signUp)
        .environmentObject(language)
        .environmentObject(baseData.localization)
        .environmentObject(feedback)
        .environmentObject(poller)
        .preferredColorScheme(.light)
        // Android's 30 s notification poll runs while signed in.
        .onChange(of: session.state.user?.id, initial: true) { previous, id in
            recovery.configure(signedIn: id != nil)
            if id == nil {
                poller.stop()
            } else if previous != nil, previous != id {
                poller.stop()
                let loc = baseData.localization
                poller.start { slug, fallback in loc.t(slug, fallback) }
            }
            // Initial polling starts in MainView.onAppear, never while saved
            // session or reference loading still holds the app on Splash.
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                poller.pause()
            } else if phase == .active,
                      StartupDestination.resolve(state: session.state, referencesReady: baseData.isReady,
                                                 savedSessionRejected: session.savedSessionRejected) == .main {
                let loc = baseData.localization
                poller.start { slug, fallback in loc.t(slug, fallback) }
            }
        }
        .onChange(of: poller.openNotificationsRequested) { _, requested in
            guard requested else { return }
            poller.openNotificationsRequested = false
            if session.state.user != nil { router.push(.notifications) }
        }
        // Arabic and Farsi are RTL in `base/languages`; the whole app mirrors.
        .environment(\.layoutDirection, isRightToLeft ? .rightToLeft : .leftToRight)
        #if DEBUG
        .task { await QALaunch.run(session: session, router: router) }
        #endif
        // A1: ask for notification permission at startup, as Android does, and
        // proceed regardless of the answer.
        .onAppear { poller.requestPermissionAtLaunch() }
        .onAppear {
            baseData.localization.languageId = language.id
            let loc = baseData.localization
            Feedback.translate = { slug, fallback in loc.t(slug, fallback) }
        }
        .onChange(of: language.id) { _, id in baseData.localization.languageId = id }
        .onAppear {
            session.willSwitchGraph = { [router] in
                router.popToRoot()
                router.selectedTab = .matches
            }
        }
    }

    /// Single place that maps a `Route` to a screen, mirroring `AppNavHost`.
    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .splash: SplashView()
        case .intro: IntroView()
        case .signIn: SignInView()
        case .signUpCredentials(let role): SignUpCredentialsView(role: role)
        case .signUpProfile: ProfileFormView(mode: .signup)
        case .signUpFormClient: PreferencesWizard(role: .client, mode: .signup)
        case .signUpFormCaregiver: PreferencesWizard(role: .caregiver, mode: .signup)
        case .forgotPassword: ForgotPasswordView()
        case .otp: OTPView()
        case .setupPassword: SetupPasswordView()
        case .main: MainView()
        case .matches: ManageMatchesView()
        case .chats: MessagesTab()
        case .chat(let chatId): ChatView(chatId: chatId)
        case .notifications: NotificationsView()
        case .profile: ProfileTab()
        case .favorites: FavoritesView()
        case .caregiverDetails(let id): PartnerDetailsView(kind: .caregiver(id: id))
        case .clientDetails(let id): PartnerDetailsView(kind: .client(id: id))
        case .caregiverSkills: PreferencesWizard(role: .caregiver, mode: .edit)
        case .clientPreferences: PreferencesWizard(role: .client, mode: .edit)
        case .changeLanguage: ChangeLanguageView()
        case .changePassword: ChangePasswordView()
        case .contactSupport: ContactSupportView()
        case .faq: FAQView()
        case .reportAnIssue: ReportAnIssueView()
        case .deleteAccount: DeleteAccountView()
        case .matched(let partner): MatchedView(partnerRef: partner)
        case .profileEdit: ProfileFormView(mode: .edit)
        case .manageMatches: ManageMatchesView()
        case .helpCenter: HelpCenterView()
        }
    }
}

// MARK: - Design catalog (visual QA harness, not the product)

/// Renders the Figma-derived scene definitions for design review; reachable via
/// `--design-catalog` or a shake.
struct DesignCatalogRoot: View {
    @State private var history: [String] = []
    @State private var selected = ProcessInfo.processInfo.arguments
        .drop(while: { $0 != "--screen" }).dropFirst().first ?? "v2-16-14997"
    @State private var catalogVisible = ProcessInfo.processInfo.arguments.contains("--catalog")
    private let screens: [ScreenRecord] = (try? SourceStore.load("catalog")) ?? []

    var body: some View {
        SourceScreen(key: selected) { key in
            if key == "back" { selected = history.popLast() ?? "v2-16-14997" }
            else { history.append(selected); selected = key }
        }
        .id(selected)
        .statusBarHidden()
        .preferredColorScheme(.light)
        .accessibilityAction(named: "Open screen catalog") { catalogVisible = true }
        .onShake { catalogVisible = true }
        .sheet(isPresented: $catalogVisible) {
            NavigationStack {
                List {
                    ForEach(screens.map(\.page).reduce(into: [String]()) {
                        if !$0.contains($1) { $0.append($1) }
                    }, id: \.self) { page in
                        Section(page == "v2" ? "Current designs" : page == "v1" ? "Legacy designs" : page) {
                            ForEach(screens.filter { $0.page == page }) { screen in
                                Button {
                                    history.append(selected); selected = screen.key; catalogVisible = false
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(screen.name)
                                        Text(screen.node).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Screen catalog")
                .toolbar { Button("Close") { catalogVisible = false } }
            }
        }
    }
}

// Simulator shake (Control-Command-Z) exposes the review catalog.
private extension View {
    func onShake(perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in action() }
    }
}
private extension Notification.Name {
    static let deviceDidShake = Notification.Name("Carezaar.deviceDidShake")
}
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
