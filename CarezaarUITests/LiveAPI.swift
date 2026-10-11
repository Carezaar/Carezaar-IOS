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
