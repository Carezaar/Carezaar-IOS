#if DEBUG
import Foundation
import SwiftUI

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
        // Clear before SessionManager is constructed and restoration can start.
        // Explicit invalid-session flags below then seed the requested scenario.
        if args.contains("--qa-signout") { TokenStore.shared.clear() }
        if args.contains("--qa-clear-reference-cache") {
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("carezaar-base.json")
            try? FileManager.default.removeItem(at: url)
        }
        if args.contains("--qa-seed-invalid-session") {
            TokenStore.shared.save(Session(accessToken: "invalid-qa-access", refreshToken: "invalid-qa-refresh"))
        }
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
        while session.state == .loading { try? await Task.sleep(for: .milliseconds(100)) }
        let environment = ProcessInfo.processInfo.environment
        let email = args.contains("--qa-login-env") ? environment["QA_EMAIL"] : value("--qa-login")
        let password = args.contains("--qa-login-env") ? environment["QA_PASSWORD"] : value("--qa-login", offset: 2)
        if let email, let password, session.state.user == nil {
            do { try await session.signIn(email: email, password: password) }
            catch { print("QA login failed; see standard in-app error handling.") }
        }
        try? await Task.sleep(for: .milliseconds(300))
        // A bounded Debug-only delay lets native tests observe departure during
        // a short failure window after startup loading has finished.
        if let raw = value("--qa-push-delay"), let delay = Double(raw), delay > 0, delay <= 30 {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
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
    /// Once-only loss after a genuine successful owned Request mutation. This
    /// never substitutes a mutation result or changes the request sent to the API.
    private static let ownedMatchAcknowledgementLoss: QAMatchAcknowledgementLoss? = {
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        guard let i = args.firstIndex(of: "--qa-lose-owned-match-ack"), i + 3 < args.count,
              let clientID = env["QA_CLIENT_USER_ID"], let caregiverID = env["QA_CG_ID"] else { return nil }
        return QAMatchAcknowledgementLoss(method: args[i + 1], path: args[i + 2],
                                         partnerID: args[i + 3], ownedIDs: [clientID, caregiverID])
    }()

    static func loseOwnedMatchAcknowledgement(_ request: URLRequest, statusCode: Int) -> Bool {
        ownedMatchAcknowledgementLoss?.shouldDrop(request, statusCode: statusCode) ?? false
    }

    private static let missingNotificationTarget: QANotificationMissingTarget? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--qa-notification-missing-target"), i + 2 < args.count,
              let id = Int(args[i + 1]) else { return nil }
        return QANotificationMissingTarget(id: id, kind: args[i + 2])
    }()

    static func notificationMissingTargetScenario(_ data: Data, path: String, method: HTTPMethod,
                                                  statusCode: Int, page: String?) -> (data: Data, attestation: String?) {
        guard let fault = missingNotificationTarget else { return (data, nil) }
        let transformed = fault.apply(data, path: path, method: method, statusCode: statusCode, page: page)
        return (transformed, transformed != data ? fault.attestation : nil)
    }

    private static let ownedProfileWithoutLocation: QAOwnedProfileWithoutLocation? = {
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        guard let i = args.firstIndex(of: "--qa-owned-profile-no-location"), i + 2 < args.count,
              let clientID = env["QA_CLIENT_USER_ID"], let caregiverID = env["QA_CG_ID"] else { return nil }
        return QAOwnedProfileWithoutLocation(method: args[i + 1], path: args[i + 2],
                                             clientID: clientID, caregiverID: caregiverID)
    }()

    static func ownedProfileLocationScenario(_ data: Data, path: String, method: HTTPMethod,
                                             statusCode: Int) -> (data: Data, attestation: String?) {
        guard let fault = ownedProfileWithoutLocation else { return (data, nil) }
        let transformed = fault.apply(data, path: path, method: method, statusCode: statusCode)
        return (transformed, transformed != data ? fault.attestation : nil)
    }

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

    private final class ProfileScenarioCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count
        }
    }
    // A fresh app process starts a fresh scenario; unrelated profile endpoints
    // cannot consume the counter. Locking also protects overlapping native reads.
    private static let profileScenarioCounter = ProfileScenarioCounter()

    /// Controlled Debug fixture only. Real successful GET responses retain their
    /// transport status and metadata. First profile is inactive; subsequent
    /// responses carry the legal envelope's null result (unavailable profile).
    static func profileResponseScenario(_ data: Data, path: String,
                                        method: HTTPMethod, statusCode: Int) -> Data {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--qa-profile-inactive-then-unavailable"),
              i + 1 < args.count, args[i + 1] == path, method == .get,
              (200..<300).contains(statusCode) else { return data }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3, !components[2].isEmpty,
              (components[0] == "clients" && components[1] == "caregivers")
                || (components[0] == "caregivers" && components[1] == "clients"),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var profile = root["result"] as? [String: Any] else { return data }
        if profileScenarioCounter.next() == 1 {
            profile["match_status"] = "none"
            profile["match_id"] = NSNull()
            root["result"] = profile
        } else {
            root["result"] = NSNull()
        }
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }

    /// Bounded failures before real renewal; no successful response is fabricated.
    private static let refreshFailures = QARefreshFailureCounter()
    static func refreshRequest(_ request: URLRequest) -> URLRequest {
        // `--qa-refresh-http-error`: renewal goes to an unknown path on the real
        // server, which answers with a genuine HTTP error (404). Nothing is fabricated.
        if ProcessInfo.processInfo.arguments.contains("--qa-refresh-http-error"),
           var parts = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
            parts.path = parts.path.replacingOccurrences(of: "auth/refresh", with: "auth/qa-renewal-http-error")
            var failed = request
            failed.url = parts.url
            return failed
        }
        guard refreshFailures.consume(),
              var parts = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return request }
        parts.host = "127.0.0.1"; parts.port = 9
        var failed = request
        failed.url = parts.url
        return failed
    }

    /// `--qa-latency <s>`: every request waits this long first (a slow network).
    static let latency: Double? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--qa-latency"), i + 1 < args.count else { return nil }
        return Double(args[i + 1])
    }()

    /// `--qa-fail-once <METHOD> <path>`: the first matching request goes to a closed
    /// local port (a connection failure); later ones reach the server normally.
    private static let failOnce = QAFailOnce()

    static func apply(_ request: URLRequest) -> URLRequest {
        if failOnce.consume(request), var parts = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
            parts.host = "127.0.0.1"; parts.port = 9
            var dead = request
            dead.url = parts.url
            return dead
        }
        guard let window, window.contains(Date().timeIntervalSince(launched)),
              var parts = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return request }
        parts.host = "127.0.0.1"; parts.port = 9
        var dead = request
        dead.url = parts.url
        return dead
    }
}
/// The controlled fault accepts only the retained pair's exact Request endpoint.
/// A nonmatching/failed response never consumes its single successful-response loss.
final class QAMatchAcknowledgementLoss: @unchecked Sendable {
    private let partnerID: String
    private let lock = NSLock()
    private var consumed = false

    init?(method: String, path: String, partnerID: String, ownedIDs: [String]) {
        guard method == "POST", path == "users/matches", ownedIDs.count == 2,
              ownedIDs.allSatisfy({ !$0.isEmpty }), Set(ownedIDs).count == 2,
              ownedIDs.contains(partnerID) else { return nil }
        self.partnerID = partnerID
    }

    func shouldDrop(_ request: URLRequest, statusCode: Int) -> Bool {
        guard (200..<300).contains(statusCode), request.httpMethod == "POST",
              request.url?.host == APIConfiguration.baseURL.host,
              request.url?.path == APIConfiguration.baseURL.appendingPathComponent("users/matches").path,
              let data = request.httpBody, let form = String(data: data, encoding: .utf8),
              let items = URLComponents(string: "?" + form)?.queryItems else { return false }
        let partners = items.filter { $0.name == "partner_id" }
        guard partners.count == 1, partners[0].value == partnerID else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }
}

/// Removes only the selected actual notification's navigation targets. The server
/// record, ownership, subject, seen state and every unrelated record are preserved.
struct QANotificationMissingTarget {
    private let id: Int
    private let kind: String
    var attestation: String { "id=\(id) kind=\(kind) partner=nil chat=nil" }
    init?(id: Int, kind: String) {
        guard id > 0, ["person", "chat"].contains(kind) else { return nil }
        self.id = id
        self.kind = kind
    }
    func apply(_ data: Data, path: String, method: HTTPMethod, statusCode: Int, page: String?) -> Data {
        guard path == "users/notifications", method == .get, statusCode == 200, page == "1",
              var envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var records = envelope["result"] as? [[String: Any]],
              let index = records.firstIndex(where: { ($0["id"] as? Int) == id }) else { return data }
        records[index]["partner"] = NSNull()
        records[index]["chat"] = NSNull()
        envelope["result"] = records
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? data
    }
}

/// A read-only owned-profile fixture. It never sends a profile write and cannot
/// strip another person's coordinates or an unrelated endpoint's response.
struct QAOwnedProfileWithoutLocation {
    private let path: String
    private let ownerID: String
    private let role: String
    var attestation: String { "path=\(path) owned=true latitude=nil longitude=nil" }
    init?(method: String, path: String, clientID: String, caregiverID: String) {
        guard method == "GET", ["clients/profile", "caregivers/profile"].contains(path),
              !clientID.isEmpty, !caregiverID.isEmpty, clientID != caregiverID else { return nil }
        self.path = path
        role = path == "clients/profile" ? "client" : "caregiver"
        ownerID = path == "clients/profile" ? clientID : caregiverID
    }
    func apply(_ data: Data, path: String, method: HTTPMethod, statusCode: Int) -> Data {
        guard path == self.path, method == .get, statusCode == 200,
              var envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var profile = envelope["result"] as? [String: Any],
              let user = profile["user"] as? [String: Any],
              user["id"] as? String == ownerID, user["role"] as? String == role else { return data }
        profile["lat"] = NSNull()
        profile["lng"] = NSNull()
        envelope["result"] = profile
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? data
    }
}

/// Opt-in Debug request counts expose no headers, bodies, credentials or response
/// data. UI regression tests use the actual transport rather than view appearances.
@MainActor
final class QARequestLedger: ObservableObject {
    static let shared = QARequestLedger()
    @Published private(set) var counts: [String: Int] = [:]
    @Published private(set) var notificationFallback = ""
    @Published private(set) var profileWithoutLocation = ""
    @Published private(set) var locationFixtures: [String] = []
    func record(_ request: URLRequest) {
        guard ProcessInfo.processInfo.arguments.contains("--qa-request-counts") else { return }
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        counts[key, default: 0] += 1
    }
    func recordLocationFixture(_ attestation: String) {
        guard ProcessInfo.processInfo.arguments.contains("--qa-request-counts") else { return }
        // Continuous MapKit callbacks must not evict the causal manual-pan event.
        if attestation.contains(" phase=manual-position "), let provider = attestation.split(separator: " ").first {
            locationFixtures.removeAll { $0.hasPrefix(String(provider) + " ") && $0.contains(" phase=manual-position ") }
        }
        locationFixtures.append(attestation)
        if locationFixtures.count > 20 { locationFixtures.removeFirst(locationFixtures.count - 20) }
    }
    func recordProfileWithoutLocation(_ attestation: String) {
        guard ProcessInfo.processInfo.arguments.contains("--qa-request-counts") else { return }
        profileWithoutLocation = attestation
    }
    func recordNotificationFallback(_ attestation: String) {
        guard ProcessInfo.processInfo.arguments.contains("--qa-request-counts") else { return }
        notificationFallback = attestation
    }
    func recordLostOwnedMatchAcknowledgement() {
        guard ProcessInfo.processInfo.arguments.contains("--qa-request-counts") else { return }
        counts["QA lost-owned-match-ack", default: 0] += 1
    }
    var summary: String { counts.keys.sorted().map { "\($0)=\(counts[$0]!)" }.joined(separator: "\n") }
}

struct QARequestCountsView: View {
    @ObservedObject private var ledger = QARequestLedger.shared
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--qa-request-counts") {
            // Keep the transport evidence readable through accessibility without
            // covering toolbar controls in XCTest's visibility calculation.
            VStack(spacing: 0) {
                Text("·")
                    .frame(width: 1, height: 1).clipped()
                    .accessibilityLabel(ledger.summary)
                    .accessibilityIdentifier("qa-request-counts")
                Text("·")
                    .frame(width: 1, height: 1).clipped()
                    .accessibilityLabel("accessPresent=\(TokenStore.shared.accessToken != nil);refreshPresent=\(TokenStore.shared.refreshToken != nil)")
                    .accessibilityIdentifier("qa-token-presence")
                if !ledger.locationFixtures.isEmpty {
                    Text("·")
                        .frame(width: 1, height: 1).clipped()
                        .accessibilityLabel(ledger.locationFixtures.joined(separator: "\n"))
                        .accessibilityIdentifier("qa-location-fixture")
                }
                if !ledger.profileWithoutLocation.isEmpty {
                    Text("·")
                        .frame(width: 1, height: 1).clipped()
                        .accessibilityLabel(ledger.profileWithoutLocation)
                        .accessibilityIdentifier("qa-profile-no-location")
                }
                if !ledger.notificationFallback.isEmpty {
                    Text("·")
                        .frame(width: 1, height: 1).clipped()
                        .accessibilityLabel(ledger.notificationFallback)
                        .accessibilityIdentifier("qa-notification-fallback")
                }
            }
            .font(.system(size: 7)).frame(width: 1, height: 2).clipped()
            .allowsHitTesting(false)
        }
    }
}
#endif

#if DEBUG
private final class QAFailOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var target: (method: String, path: String)? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--qa-fail-once"), i + 2 < args.count else { return nil }
        return (args[i + 1], args[i + 2])
    }()
    func consume(_ request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let target, request.httpMethod == target.method,
              request.url?.path == APIConfiguration.baseURL.appendingPathComponent(target.path).path else { return false }
        self.target = nil
        return true
    }
}

private final class QARefreshFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--qa-refresh-failures"), index + 1 < args.count else { return 0 }
        return max(0, Int(args[index + 1]) ?? 0)
    }()
    func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}
#endif
