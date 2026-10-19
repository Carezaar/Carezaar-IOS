import Foundation
import CryptoKit
import CoreFoundation
import Darwin

/// Test-only; never edits the original fixture or creates provider/auth sessions.
final class OwnedClientRecoveryJournal {
    enum Stop: Error { case invariant(String) }
    let root: URL, plan: [String: Any], original: [String: Any]
    let email: String, userID: String, secret: String, fixtureSHA: String
    private var ordinal = 0, reads = 0
    struct Boundary { let ids: Set<String>; let date: Date; let accountID: String; let iri: String }
    static func require(_ yes: Bool, _ why: String) throws { if !yes { throw Stop.invariant(why) } }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Stop.invariant("object-required") };return value
    }
    static func privateObject(_ url: URL) throws -> [String: Any] {
        let real = url.resolvingSymlinksInPath()
        try require(real.path == url.standardizedFileURL.path || url.path.replacingOccurrences(of: "/tmp/", with: "/private/tmp/") == real.path, "unexpected-private-alias")
        let attributes = try FileManager.default.attributesOfItem(atPath: real.path)
        try require(attributes[.type] as? FileAttributeType == .typeRegular
            && (attributes[.referenceCount] as? NSNumber)?.intValue == 1, "private-regular-single-link-file-required")
        let mode = attributes[.posixPermissions] as? NSNumber
        let parent = try FileManager.default.attributesOfItem(atPath: real.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o600 && parent?.intValue == 0o700, "private-modes-required")
        return try object(Data(contentsOf: real))
    }
    init(planFile: String) throws {
        plan = try Self.privateObject(URL(fileURLWithPath: planFile))
        guard let fixture = plan["originalFixture"] as? String, let expected = plan["originalSHA256"] as? String,
              let folder = plan["journalDirectory"] as? String, let pending = plan["pendingFile"] as? String,
              let expectedID = plan["expectedUserID"] as? String, let expectedEmail = plan["expectedEmail"] as? String else { throw Stop.invariant("reviewed-plan-fields-required") }
        try Self.require(plan["rootReviewed"] as? Bool == true && plan["role"] as? String == "client"
            && plan["ownedPairNONE"] as? Bool == true, "exact-client-recovery-authority-required")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: fixture));fixtureSHA = Self.sha(bytes)
        _ = try Self.privateObject(URL(fileURLWithPath: fixture))
        original = try NativeLifecycleFixture.read(fixture)
        guard let p = original["native_provenance"] as? [String: Any],
              let address = original["email"] as? String, let id = original["user_id"] as? String else { throw Stop.invariant("native-client-provenance-required") }
        try Self.require(fixtureSHA == expected && original["role"] as? String == "client"
            && p["role"] as? String == "client" && p["size"] as? String == "modern" && p["stage"] as? String == "signupComplete"
            && p["purpose"] as? String == "carezaar-native-final-qa" && p["provider_ownership_verified"] as? Bool == true
            && p["provider_create_attempts"] as? Int == 1 && p["app_registration_attempts"] as? Int == 1
            && original["deleted"] as? Bool != true && id == expectedID && address == expectedEmail, "exact-original-completed-client-required")
        email = address;userID = id
        let pendingURL = URL(fileURLWithPath: pending), record = try Self.privateObject(pendingURL)
        guard let candidate = record["pending_password"] as? String else { throw Stop.invariant("pending-secret-required") }
        try Self.require(Self.sha(try Data(contentsOf: pendingURL)) == plan["pendingSHA256"] as? String
            && record["originalSHA256"] as? String == expected && record["credentialVersion"] as? Int == 1
            && record["confirmed"] as? Bool == false && candidate.hasPrefix("Aa9!") && candidate.count >= 44,
            "strong-private-pending-version-before-email-required")
        secret = candidate;root = URL(fileURLWithPath: folder).resolvingSymlinksInPath()
        let mode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        try Self.require(mode?.intValue == 0o700 && (try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty,
            "fresh-private-journal-no-replay")
        try event("owned-client-recovery-bound", ["originalSHA256": fixtureSHA, "expectedUserID": userID,
            "role": "client", "pendingVersion": 1, "oldPasswordNotAttempted": true])
    }
    func write(_ name: String, _ value: Any) throws {
        try Self.require(!name.contains("/") && !name.contains(".."), "safe-private-filename")
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        let fd = open(root.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        try Self.require(fd >= 0, "exclusive-private-reservation-no-replay");defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count { let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                try Self.require(n > 0, "private-write-failed");offset += n }
        }
        try Self.require(fsync(fd) == 0, "private-file-fsync-failed")
        let parent = open(root.path, O_RDONLY | O_DIRECTORY);try Self.require(parent >= 0, "private-parent-open-failed")
        defer { close(parent) };try Self.require(fsync(parent) == 0, "private-parent-fsync-failed")
    }
    func event(_ kind: String, _ details: [String: Any] = [:]) throws {
        ordinal += 1;try write(String(format: "%04d-%@.json", ordinal, kind), ["kind": kind,
            "at": ISO8601DateFormatter().string(from: Date()), "details": details])
    }
    func intent(_ name: String, method: String, route: String) throws {
        try write(name + "-intent.json", ["method": method, "route": route, "attempt": 1,
            "originalSHA256": fixtureSHA, "pendingVersion": 1, "at": ISO8601DateFormatter().string(from: Date())])
    }
    private func provider(_ path: String) throws -> [String: Any] {
        try Self.require(reads < 53 && (path == "me" || path == "messages" || (path.hasPrefix("messages/")
            && path.split(separator: "/").count == 2 && !path.contains(".."))), "finite-owned-provider-GET-only")
        guard let token = original["inbox_token"] as? String, !token.isEmpty else { throw Stop.invariant("existing-inbox-token-required") }
        reads += 1;try event("provider-GET-intent", ["path": path, "ordinal": reads])
        var request = URLRequest(url: URL(string: "https://api.mail.tm/" + path)!);request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/ld+json", forHTTPHeaderField: "Accept")
        let done = DispatchSemaphore(value: 0);var result: Result<(Int, Data), Error> = .failure(Stop.invariant("provider-no-response"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: OwnedRecoveryNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) { data, response, error in
            defer { done.signal() };if let error { result = .failure(error);return }
            guard let data, let response = response as? HTTPURLResponse else { return };result = .success((response.statusCode,data))
        }
        task.resume();guard done.wait(timeout: .now() + 35) == .success else { task.cancel();throw Stop.invariant("provider-read-timeout-no-resend") }
        let (status,data) = try result.get();let body = try Self.object(data)
        try event("provider-GET-response", ["path": path, "status": status, "body": body])
        try Self.require(status == 200, "provider-not-http200-no-retry");return body
    }
    /// hydra:view is legal on one complete page; only a next link or inconsistent
    /// total/member data indicates that the captured ID boundary is incomplete.
    static func completeIDs(_ envelope: [String: Any]) throws -> Set<String> {
        guard let rows = envelope["hydra:member"] as? [[String: Any]], let total = envelope["hydra:totalItems"] as? NSNumber else { throw Stop.invariant("complete-mailbox-envelope-required") }
        let number = total.doubleValue
        try require(CFGetTypeID(total) != CFBooleanGetTypeID() && number.isFinite && number >= 0
            && number.rounded(.towardZero) == number && number == Double(rows.count) && number <= 30,
            "mailbox-total-member-mismatch-or-pagination")
        if let value = envelope["hydra:view"], !(value is NSNull) {
            guard let view = value as? [String: Any] else { throw Stop.invariant("malformed-hydra-view") }
            for key in ["hydra:next", "next"] {
                let value = view[key]
                try require(value == nil || value is NSNull || value as? String == "", "mailbox-next-page-refused")
            }
        }
        let ids = rows.compactMap { $0["id"] as? String }
        try require(ids.count == rows.count && Set(ids).count == rows.count && ids.allSatisfy { !$0.isEmpty && !$0.contains("/") && !$0.contains("..") }, "unique-complete-message-ids-required")
        return Set(ids)
    }
    func boundary() throws -> Boundary {
        guard let p = original["native_provenance"] as? [String: Any], let id = p["provider_account_id"] as? String,
              let iri = p["provider_account_iri"] as? String else { throw Stop.invariant("existing-provider-account-binding-required") }
        let me = try provider("me")
        try Self.require(iri == "/accounts/" + id && me["id"] as? String == id && [iri, "/me"].contains(me["@id"] as? String ?? "")
            && me["isDisabled"] as? Bool != true && me["address"] as? String == email && me["isDeleted"] as? Bool != true, "exact-existing-provider-owner-and-IRI-required")
        let ids = try Self.completeIDs(provider("messages"));let date = Date()
        try event("before-send-full-message-boundary", ["priorIDs": ids.sorted(), "accountID": id, "accountIRI": iri,
            "requestedAfter": ISO8601DateFormatter().string(from: date)])
        return Boundary(ids: ids,date: date,accountID: id,iri: iri)
    }
    func freshCode(_ boundary: Boundary) throws -> String {
        let basic = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let deadline = Date().addingTimeInterval(180)
        for index in 0..<50 {
            try Self.require(Date() < deadline, "owned-code-deadline-no-resend")
            let ids = try Self.completeIDs(provider("messages"))
            try Self.require(boundary.ids.isSubset(of: ids), "prior-mail-disappeared-boundary-uncertain")
            let fresh = ids.subtracting(boundary.ids);try Self.require(fresh.count <= 1, "multiple-new-messages-no-resend")
            if let id = fresh.first {
                try Self.require(Date() < deadline,"detail-read-must-start-within-code-window")
                let mail = try provider("messages/" + id)
                let recipients = (mail["to"] as? [[String: Any]] ?? []).compactMap { $0["address"] as? String }
                let account = mail["accountId"] as? String
                let created = (mail["createdAt"] as? String).flatMap { fractional.date(from:$0) ?? basic.date(from:$0) }
                try Self.require(mail["id"] as? String == id && mail["@id"] as? String == "/messages/" + id
                    && (account == boundary.accountID || account == boundary.iri) && recipients == [email]
                    && created.map { $0 >= boundary.date.addingTimeInterval(-2) && $0 <= Date().addingTimeInterval(5) } == true,
                    "fresh-exact-owned-message-and-time-required")
                let text = "\(mail["text"] ?? "") \(mail["html"] ?? "") \(mail["subject"] ?? "")"
                let regex = try NSRegularExpression(pattern: "\\b\\d{5}\\b")
                let codes = Set(regex.matches(in:text,range:NSRange(text.startIndex..<text.endIndex,in:text)).compactMap { Range($0.range,in:text).map { String(text[$0]) } })
                try Self.require(codes.count == 1, "exact-one-reset-code-required")
                try event("fresh-owned-code-bound", ["messageID": id, "exactOwnerRecipientIRI": true, "freshBoundaryVerified": true])
                let code = codes.first!
                let pendingURL = URL(fileURLWithPath: plan["pendingFile"] as! String)
                var pending = try Self.privateObject(pendingURL)
                pending["private_otp_values"] = (pending["private_otp_values"] as? [String] ?? []) + [code]
                let bytes = try JSONSerialization.data(withJSONObject: pending, options: [.sortedKeys,.prettyPrinted])
                let temporary = pendingURL.deletingLastPathComponent().appendingPathComponent("pending-otp-exclusive-private.tmp")
                let fd = open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,S_IRUSR|S_IWUSR)
                try Self.require(fd >= 0,"private-pending-otp-reservation-required")
                defer { close(fd) }
                try bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count { let n = Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                        try Self.require(n > 0,"pending-otp-write-failed");offset += n }
                }
                try Self.require(fsync(fd)==0 && rename(temporary.path,pendingURL.path)==0,"pending-otp-durable-replace-failed")
                let parent = open(pendingURL.deletingLastPathComponent().path,O_RDONLY|O_DIRECTORY)
                try Self.require(parent >= 0,"pending-parent-open-required");defer { close(parent) }
                try Self.require(fsync(parent)==0,"pending-otp-parent-fsync-failed")
                return code
            }
            if index < 49 { Thread.sleep(forTimeInterval: 3) }
        }
        throw Stop.invariant("owned-code-timeout-no-resend")
    }
    func confirmVersion(nativeLedgers: [[String: Any]]) throws {
        try Self.require(Self.sha(try Data(contentsOf: URL(fileURLWithPath: plan["originalFixture"] as! String))) == fixtureSHA,
            "original-fixture-must-remain-immutable")
        var version = original;version["password"] = secret;version.removeValue(forKey:"pending_password")
        let pending = try Self.privateObject(URL(fileURLWithPath:plan["pendingFile"] as! String))
        version["private_otp_values"] = pending["private_otp_values"]
        version["native_recovery"] = ["credentialVersion":1,"originalSHA256":fixtureSHA,"visibleNewSecretLogin":true,
            "nativeOwnerEmailExact":true,"nativeRoleClientFromMainGET":true,"immutableUserIDPreservedFromOriginal":true,
            "freshIndependentBearerIdentityProofPerformed":false]
        try write("client-credential-version-1-private.json",version)
        try write("recovery-complete-private.json",["complete":true,"originalSHA256":fixtureSHA,"credentialVersion":1,
            "providerGETs":reads,"providerWrites":0,"officialLoginPOSTs":0,"nativeLedgers":nativeLedgers,
            "visibleNewSecretLogin":true,"ordinaryRelaunch":true,"oldSecretNotAttempted":true])
    }
}

/// Reject rather than follow any provider redirect with the owned inbox bearer.
private final class OwnedRecoveryNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
