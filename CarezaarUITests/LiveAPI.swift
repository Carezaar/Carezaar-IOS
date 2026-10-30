import Foundation
import XCTest

/// Minimal clients for test setup: the disposable mail.tm inbox that receives the
/// signup OTP, and direct Carezaar API calls used to stage a partner's match request.
enum MailTM {
    struct Inbox { let address: String; let token: String }
    static let base = URL(string: "https://api.mail.tm")!

    static func json(_ request: URLRequest) throws -> Any {
        var result: Result<Data, Error> = .failure(URLError(.unknown))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            result = data.map { .success($0) } ?? .failure(error ?? URLError(.badServerResponse))
            done.signal()
        }.resume()
        done.wait()
        let data = try result.get()
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    static func post(_ path: String, _ body: [String: String]) throws -> [String: Any] {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try json(r) as? [String: Any] ?? [:]
    }

    static func createInbox() throws -> Inbox {
        let domains = try json(URLRequest(url: base.appendingPathComponent("domains"))) as? [String: Any]
        let list = domains?["hydra:member"] as? [[String: Any]] ?? []
        guard let domain = list.first?["domain"] as? String else { throw URLError(.cannotFindHost) }
        // A random tail: two simulators signing up in the same second must not collide.
        let address = "carezaarios\(Int(Date().timeIntervalSince1970))\(Int.random(in: 100...999))@\(domain)"
        let inboxPassword = UUID().uuidString + "!9Qa"
        for attempt in 1...4 {
            let account = try post("accounts", ["address": address, "password": inboxPassword])
            print("MAILTM account attempt \(attempt): created=\(account["id"] != nil)")
            Thread.sleep(forTimeInterval: 1.5)
            if let token = try post("token", ["address": address, "password": inboxPassword])["token"] as? String {
                return Inbox(address: address, token: token)
            }
            Thread.sleep(forTimeInterval: 2)
        }
        throw URLError(.userAuthenticationRequired)
    }

    /// Polls until the inbox holds more than `skipping` messages and returns the first
    /// 5-digit code in the newest one (a password reset arrives after the signup code).
    static func waitForCode(_ inbox: Inbox, skipping: Int = 0, timeout: TimeInterval = 150) throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var r = URLRequest(url: base.appendingPathComponent("messages"))
            r.setValue("Bearer \(inbox.token)", forHTTPHeaderField: "Authorization")
            let list = (try json(r) as? [String: Any])?["hydra:member"] as? [[String: Any]] ?? []
            let newest = list.max { ($0["createdAt"] as? String ?? "") < ($1["createdAt"] as? String ?? "") }
            if list.count > skipping, let id = newest?["id"] as? String {
                var m = URLRequest(url: base.appendingPathComponent("messages/\(id)"))
                m.setValue("Bearer \(inbox.token)", forHTTPHeaderField: "Authorization")
                let full = try json(m) as? [String: Any] ?? [:]
                let text = "\(full["text"] ?? "") \(full["html"] ?? "") \(full["subject"] ?? "")"
                if let range = text.range(of: "\\b\\d{5}\\b", options: .regularExpression) { return String(text[range]) }
            }
            Thread.sleep(forTimeInterval: 4)
        }
        return nil
    }
}

/// Test-only native-purpose provenance. Provider creation belongs to the explicit
/// host preparer; an interrupted registration never silently creates another inbox.
enum NativeLifecycleFixture {
    enum Failure: Error { case stopped(String) }
    static func read(_ file: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: file).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: "/tmp/carezaar-final-native-lifecycle-20261018").resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(root),
              (try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              let record = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let provenance = record["native_provenance"] as? [String: Any],
              provenance["purpose"] as? String == "carezaar-native-final-qa" else {
            throw Failure.stopped("private-native-provenance-required")
        }
        return record
    }
    static func save(_ record: [String: Any], _ file: String) throws {
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: file), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }
    private static func provider(_ path: String, token: String) throws -> [String: Any] {
        var request = URLRequest(url: MailTM.base.appendingPathComponent(path))
        request.timeoutInterval = 30
        request.setValue("application/ld+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var result: Result<[String: Any], Error> = .failure(Failure.stopped("provider-unavailable"))
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                result = .failure(Failure.stopped("provider-read-not-http200")); return
            }
            result = .success(object)
        }
        task.resume()
        guard done.wait(timeout: .now() + 35) == .success else {
            task.cancel(); throw Failure.stopped("provider-read-timeout")
        }
        return try result.get()
    }
    static func inbox(_ file: String, caregiver: Bool, environment: [String: String]) throws -> MailTM.Inbox {
        let record = try read(file)
        let provenance = record["native_provenance"] as? [String: Any] ?? [:]
        let role = caregiver ? "caregiver" : "client"
        guard provenance["role"] as? String == role, record["role"] as? String == role,
              provenance["stage"] as? String == "inboxReady",
              provenance["provider_create_attempts"] as? Int == 1,
              provenance["app_registration_attempts"] as? Int == 0,
              let marker = provenance["marker"] as? String,
              let address = record["email"] as? String, address.hasPrefix("carezaar-native-\(marker)@"),
              let token = record["inbox_token"] as? String,
              let id = provenance["provider_account_id"] as? String else {
            throw Failure.stopped("fresh-native-inbox-required-no-registration-replay")
        }
        let retained = ["QA_EMAIL", "QA_CLIENT_EMAIL", "QA_CG_EMAIL"].compactMap { environment[$0]?.lowercased() }
        guard !retained.contains(address.lowercased()) else { throw Failure.stopped("retained-fixture-refused") }
        let me = try provider("me", token: token)
        guard me["id"] as? String == id, me["address"] as? String == address else {
            throw Failure.stopped("provider-exact-ownership-mismatch")
        }
        return MailTM.Inbox(address: address, token: token)
    }
    static func stageRegistration(_ file: String, inbox: MailTM.Inbox) throws {
        var record = try read(file)
        var provenance = record["native_provenance"] as? [String: Any] ?? [:]
        guard provenance["stage"] as? String == "inboxReady", record["email"] as? String == inbox.address else {
            throw Failure.stopped("registration-already-staged-no-replay")
        }
        let response = try provider("messages", token: inbox.token)
        guard let rows = response["hydra:member"] as? [[String: Any]], rows.isEmpty else {
            throw Failure.stopped("fresh-inbox-has-unexpected-messages")
        }
        provenance["message_before_ids"] = [String]()
        provenance["otp_requested_at"] = ISO8601DateFormatter().string(from: Date())
        provenance["registration_intent_at"] = provenance["otp_requested_at"]
        provenance["app_registration_attempts"] = 1
        provenance["stage"] = "registrationIntent"
        record["native_provenance"] = provenance
        try save(record, file)
    }
    static func stage(_ name: String, file: String) throws {
        var record = try read(file)
        var provenance = record["native_provenance"] as? [String: Any] ?? [:]
        guard provenance["app_registration_attempts"] as? Int == 1, record["deleted"] as? Bool != true else {
            throw Failure.stopped("owned-registration-stage-required")
        }
        provenance["stage"] = name
        provenance[name + "_at"] = ISO8601DateFormatter().string(from: Date())
        record["native_provenance"] = provenance
        try save(record, file)
    }
    static func waitForSignupCode(_ file: String, inbox: MailTM.Inbox, timeout: TimeInterval = 150) throws -> String {
        var record = try read(file)
        var provenance = record["native_provenance"] as? [String: Any] ?? [:]
        let basic = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let accountID = provenance["provider_account_id"] as? String,
              let rawBoundary = provenance["otp_requested_at"] as? String,
              let boundary = basic.date(from: rawBoundary) else { throw Failure.stopped("missing-message-boundary") }
        let prior = Set(provenance["message_before_ids"] as? [String] ?? [])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try provider("messages", token: inbox.token)
            guard let rows = response["hydra:member"] as? [[String: Any]] else { throw Failure.stopped("malformed-message-list") }
            let candidates = rows.compactMap { $0["id"] as? String }.filter { !prior.contains($0) }
            guard candidates.count <= 1 else { throw Failure.stopped("multiple-new-messages-review-before-resend") }
            if let id = candidates.first {
                let full = try provider("messages/\(id)", token: inbox.token)
                let account = full["accountId"] as? String
                let recipients = (full["to"] as? [[String: Any]] ?? []).compactMap { $0["address"] as? String }
                let created = (full["createdAt"] as? String).flatMap { fractional.date(from: $0) ?? basic.date(from: $0) }
                guard full["id"] as? String == id,
                      account == accountID || account == "/accounts/\(accountID)",
                      recipients.contains(inbox.address), let created,
                      created >= boundary.addingTimeInterval(-2) else {
                    throw Failure.stopped("fresh-message-ownership-or-time-mismatch")
                }
                let content = "\(full["text"] ?? "") \(full["html"] ?? "") \(full["subject"] ?? "")"
                let regex = try NSRegularExpression(pattern: "\\b\\d{5}\\b")
                let range = NSRange(content.startIndex..<content.endIndex, in: content)
                let codes = Set(regex.matches(in: content, range: range).compactMap { Range($0.range, in: content).map { String(content[$0]) } })
                guard codes.count == 1, let code = codes.first else { throw Failure.stopped("message-code-ambiguous") }
                record["private_otp_values"] = (record["private_otp_values"] as? [String] ?? []) + [code]
                provenance["consumed_message_id"] = id; provenance["stage"] = "otpReceived"
                record["native_provenance"] = provenance; try save(record, file)
                return code
            }
            Thread.sleep(forTimeInterval: 3)
        }
        throw Failure.stopped("fresh-owned-otp-timeout-no-automatic-resend")
    }
}

enum CarezaarAPI {
    static let base = URL(string: "https://new.carezaar.com/api/")!

    /// Status-preserving proof requests. Unlike setup helpers, malformed JSON or
    /// transport failure throws rather than looking like an empty auth result.
    static func callWithHTTPStatus(_ method: String, _ path: String, form: [String: String] = [:], token: String? = nil) throws -> (status: Int, body: [String: Any]) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.timeoutInterval = 30
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if !form.isEmpty {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
                .joined(separator: "&").data(using: .utf8)
        }
        var result: Result<(Int, Data), Error> = .failure(URLError(.unknown))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error { result = .failure(error); return }
            guard let http = response as? HTTPURLResponse, let data else {
                result = .failure(URLError(.badServerResponse)); return
            }
            result = .success((http.statusCode, data))
        }.resume()
        done.wait()
        let (status, data) = try result.get()
        // The real owned withdraw endpoint returns HTTP 204 with no JSON body.
        // Preserve that status; other empty or malformed responses still fail.
        if status == 204 && data.isEmpty { return (status, [:]) }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return (status, body)
    }

    static func call(_ method: String, _ path: String, form: [String: String] = [:], token: String? = nil) throws -> [String: Any] {
        // Relative resolution keeps a query string intact (appendingPathComponent escapes "?").
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if !form.isEmpty {
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
                .joined(separator: "&").data(using: .utf8)
        }
        return try MailTM.json(r) as? [String: Any] ?? [:]
    }

    static func login(_ email: String, _ password: String) throws -> String {
        let r = try call("POST", "auth/login", form: ["email": email, "password": password, "version_app": "1.0.0",
                                                      "os": "iOS", "version_os": "26"])
        return (r["result"] as? [String: Any])?["access_token"] as? String ?? ""
    }
}

extension CarezaarAPI {
    static func result(_ response: [String: Any]) -> [String: Any] { response["result"] as? [String: Any] ?? [:] }

    /// The opening of a managed FAQ answer as the app shows it (HTML removed), read from
    /// the live English FAQ. The FAQ is edited in the admin panel, so tests must not
    /// hard-code its wording.
    static func faqAnswerOpening(question: String, length: Int = 24) throws -> String {
        let languages = try call("GET", "base/languages?ts_cache=0")["result"] as? [[String: Any]] ?? []
        let english = languages.first { ($0["code"] as? String) == "en" }?["id"] as? Int
        let faqs = try call("GET", "base/faqs?ts_cache=0")["result"] as? [[String: Any]] ?? []
        for faq in faqs {
            for t in faq["translations"] as? [[String: Any]] ?? [] where (t["question"] as? String) == question {
                if let english, (t["language_id"] as? Int) != english { continue }
                let plain = ((t["answer"] as? String) ?? "")
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !plain.isEmpty { return String(plain.prefix(length)) }
            }
        }
        throw URLError(.resourceUnavailable)
    }

    static func me(_ token: String) throws -> [String: Any] { result(try call("GET", "auth/info", token: token)) }

    /// Ends any match or open request between a caregiver and a client, from the
    /// caregiver's side, so a test starts from a clean slate.
    static func clearRelation(caregiverToken: String, clientUserId: String) throws {
        throw XCTSkip("Quarantined unsafe legacy fixture: Legacy relationship cleanup can delete pre-existing connections without exact owned-pair provenance. Use the strict owned-pair MatchActionBoundaryUITests or MatchStateMatrixUITests instead.")
    }
}

extension XCUIElement {
    func waitForSelected(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if isSelected { return true }; usleep(200_000) }
        return isSelected
    }
}

extension XCUIApplication {
    /// The preference and skills editors open on their intro, as on Android; Get Started is its last button.
    func passWizardIntro(timeout: TimeInterval = 60) {
        let intro = descendants(matching: .any)["v2-65-19934"]
        guard intro.waitForExistence(timeout: timeout) else { return }
        let buttons = intro.buttons
        buttons.element(boundBy: buttons.count - 1).tap()
    }
}
