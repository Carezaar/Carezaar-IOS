#if DEBUG
import Foundation

/// Debug-only launch arguments for development and screen capture:
/// `--qa-signout` clears the stored session; `--qa-login <email> <password>` signs in;
/// `--qa-tab matches|messages|profile` selects a tab; `--qa-push A,B` pushes routes by
/// their Android identifiers (e.g. `Notifications`, `Chat/12`, `CaregiverDetails/<id>`).
/// Session handling: `--qa-break-access` makes the stored access token one the server
/// rejects before the session restores (as an expired one is, with 403);
/// `--qa-break-both` does the same to the refresh token; `--qa-break-access-later`
/// breaks the access token 8 s after launch, mid-session.
@MainActor
enum QALaunch {
    nonisolated static func prepare() {
        let args = ProcessInfo.processInfo.arguments
        _ = QANetworkFault.launched
        if args.contains("--qa-break-access") { breakTokens(refreshToo: false) }
        if args.contains("--qa-break-both") { breakTokens(refreshToo: true) }
    }

    nonisolated private static func breakTokens(refreshToo: Bool) {
        let store = TokenStore.shared
        guard let access = store.accessToken, let refresh = store.refreshToken else { return }
        // A token the server rejects with 403, the way it rejects an expired one.
        func broken(_ token: String) -> String {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 3 ? "\(parts[0]).\(parts[1])." : "invalid.token"
        }
        store.save(Session(accessToken: broken(access), refreshToken: refreshToo ? broken(refresh) : refresh))
    }

    static func run(session: SessionManager, router: AppRouter) async {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String, offset: Int = 1) -> String? {
            guard let i = args.firstIndex(of: flag), i + offset < args.count else { return nil }
            return args[i + offset]
        }
        if args.contains("--qa-signout") { TokenStore.shared.clear() }
        while session.state == .loading { try? await Task.sleep(for: .milliseconds(100)) }
        if let email = value("--qa-login"), let password = value("--qa-login", offset: 2), session.state.user == nil {
            do { try await session.signIn(email: email, password: password) }
            catch { print("QA login failed: \(error)") }
        }
        try? await Task.sleep(for: .milliseconds(300))
        if let tab = value("--qa-tab").flatMap(MainTab.init(rawValue:)) { router.selectedTab = tab }
        for id in value("--qa-push")?.split(separator: ",").map(String.init) ?? [] {
            if let route = route(id) { router.push(route) }
        }
        if args.contains("--qa-break-access-later") {
            try? await Task.sleep(for: .seconds(8))
            breakTokens(refreshToo: false)
        }
    }

    private static func route(_ id: String) -> Route? {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "SignIn": return .signIn
        case "ForgotPassword": return .forgotPassword
        case "Notifications": return .notifications
        case "Favorites": return .favorites
        case "ManageMatches": return .manageMatches
        case "HelpCenter": return .helpCenter
        case "FAQ": return .faq
        case "ReportAnIssue": return .reportAnIssue
        case "ChangeLanguage": return .changeLanguage
        case "ChangePassword": return .changePassword
        case "DeleteAccount": return .deleteAccount
        case "ProfileEdit": return .profileEdit
        case "ClientPreferences": return .clientPreferences
        case "CaregiverSkills": return .caregiverSkills
        case "SignUpCredentials": return .signUpCredentials(role: arg == "caregiver" ? .caregiver : .client)
        case "SignUpFormCaregiver": return .signUpFormCaregiver
        case "Chat": return Int(arg).map { .chat(chatId: $0) }
        case "Matched":
            // Matched/caregivers/{id} or Matched/clients/{id}, as on the web.
            let pieces = arg.split(separator: "/", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return nil }
            return pieces[0] == "caregivers" ? .matched(partner: .caregiver(id: pieces[1])) : .matched(partner: .client(id: pieces[1]))
        case "CaregiverDetails": return .caregiverDetails(caregiverId: arg)
        case "ClientDetails": return .clientDetails(clientId: arg)
        default: return nil
        }
    }
}

/// `--qa-offline <from> <to>`: between those seconds after launch every request goes
/// to a closed local port, so iOS fails it the way a dropped connection does.
enum QANetworkFault {
    static let launched = Date()
    private static let window: ClosedRange<Double>? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--qa-offline"), i + 2 < args.count,
              let from = Double(args[i + 1]), let to = Double(args[i + 2]), from <= to else { return nil }
        return from...to
    }()

    /// `--qa-corrupt-match-state`: profile responses arrive with a `match_status` but no
    /// `match_id`, a contradiction the app must refuse to act on.
    static func corruptMatchState(_ data: Data, path: String) -> Data {
        guard ProcessInfo.processInfo.arguments.contains("--qa-corrupt-match-state"),
              path.hasPrefix("clients/caregivers/") || path.hasPrefix("caregivers/clients/"),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var result = root["result"] as? [String: Any] else { return data }
        result["match_status"] = "sent"
        result["match_id"] = NSNull()
        root["result"] = result
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }

    /// `--qa-latency <s>`: every request waits this long first (a slow network).
    static let latency: Double? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--qa-latency"), i + 1 < args.count else { return nil }
        return Double(args[i + 1])
    }()

    static func apply(_ request: URLRequest) -> URLRequest {
        guard let window, window.contains(Date().timeIntervalSince(launched)),
              var parts = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return request }
        parts.host = "127.0.0.1"; parts.port = 9
        var dead = request
        dead.url = parts.url
        return dead
    }
}
#endif
