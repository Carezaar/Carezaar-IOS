import Foundation
import CryptoKit
import Darwin

/// Test-only durable ownership/intent boundary. No provider calls or graph writes.
final class NativeOwnedGraphJournal {
    enum Stopped: Error { case invariant(String) }
    struct Account {
        let role: String, email: String, password: String, id: String, file: URL, original: Data
        var name = ""
        var token = ""
    }
    private(set) var client: Account
    private(set) var caregiver: Account
    let directory: URL
    let introduction: String
    private let file: URL
    private var document: [String: Any]
    private var officialLogins: Set<String> = []
    private var uiLoginIndex = 0
    private let continuationMode: Bool
    private let uiLoginOrder: [String]
    private var requestIntentRecorded = false
    private var withdrawIntentRecorded = false
    private(set) var edgeID: Int?
    private(set) var cancelledEdgeRetainedInHistory = false
    private var baselineHistory: [String: [Int: Data]] = [:]

    static func require(_ value: Bool, _ code: String) throws {
        guard value else { throw Stopped.invariant(code) }
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    init(environment env: [String: String]) throws {
        guard env["QA_NATIVE_GRAPH_CLIENT_CANCEL"] == "1", let cf = env["QA_NATIVE_GRAPH_CLIENT_FILE"],
              let gf = env["QA_NATIVE_GRAPH_CAREGIVER_FILE"], let folder = env["QA_NATIVE_GRAPH_JOURNAL_DIR"] else {
            throw Stopped.invariant("explicit-reviewed-native-graph-fixtures-required")
        }
        func account(_ path: String, role: String) throws -> (Account, String) {
            let record = try NativeLifecycleFixture.read(path)
            guard let p = record["native_provenance"] as? [String: Any], let run = p["run_id"] as? String,
                  let marker = p["marker"] as? String, let email = record["email"] as? String,
                  let password = record["password"] as? String, let id = record["user_id"] as? String else {
                throw Stopped.invariant("complete-native-account-record-required")
            }
            try Self.require(p["purpose"] as? String == "carezaar-native-final-qa"
                && p["role"] as? String == role && record["role"] as? String == role
                && p["size"] as? String == "modern" && p["stage"] as? String == "signupComplete"
                && p["provider_create_attempts"] as? Int == 1 && p["app_registration_attempts"] as? Int == 1
                && p["provider_ownership_verified"] as? Bool == true && !run.isEmpty && !id.isEmpty && !password.isEmpty
                && email.hasPrefix("carezaar-native-\(marker)@") && record["deleted"] as? Bool != true,
                "exact-completed-native-purpose-provenance-required")
            if role == "caregiver" {
                let repair = record["native_dob_repair"] as? [String: Any]
                try Self.require(repair?["stage"] as? String == "complete" && repair?["profilePostAttempts"] as? Int == 1,
                                 "completed-caregiver-date-repair-required")
            }
            let retained = ["QA_EMAIL", "QA_CLIENT_EMAIL", "QA_CG_EMAIL"].compactMap { env[$0]?.lowercased() }
            try Self.require(!retained.contains(email.lowercased()) && id != env["QA_CG_ID"] && id != env["QA_CLIENT_USER_ID"], "retained-fixture-refused")
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            return (Account(role: role, email: email, password: password, id: id, file: url, original: try Data(contentsOf: url)), run)
        }
        let c = try account(cf, role: "client"), g = try account(gf, role: "caregiver")
        try Self.require(c.1 == g.1 && c.0.id != g.0.id && c.0.email != g.0.email && c.0.file != g.0.file, "same-run-distinct-owned-pair-required")
        client = c.0; caregiver = g.0
        let raw = URL(fileURLWithPath: folder)
        directory = raw.resolvingSymlinksInPath()
        let allowed = URL(fileURLWithPath: "/tmp/carezaar-final-native-graph-20261019").resolvingSymlinksInPath().path + "/"
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        try Self.require(raw.standardizedFileURL.path == directory.path || raw.path.replacingOccurrences(of: "/tmp/", with: "/private/tmp/") == directory.path, "unexplained-journal-path-alias")
        try Self.require(directory.path.hasPrefix(allowed) && attributes[.type] as? FileAttributeType == .typeDirectory
            && (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
            && (try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty, "fresh-private-journal-folder-required-no-replay")
        file = directory.appendingPathComponent("journal.json")
        continuationMode = env["QA_NATIVE_GRAPH_WITHDRAW_CONTINUATION"] == "1"
        uiLoginOrder = continuationMode ? ["caregiver", "client"] : ["client", "caregiver", "client"]
        var inherited: [String: Any]?
        if continuationMode {
            guard let source = env["QA_NATIVE_GRAPH_CONTINUATION_SOURCE_FILE"],
                  let expectedSHA = env["QA_NATIVE_GRAPH_CONTINUATION_SOURCE_SHA256"],
                  let historyJSON = env["QA_NATIVE_GRAPH_CONTINUATION_HISTORY_HASHES"],
                  let historyData = historyJSON.data(using: .utf8),
                  let historyHashes = try JSONSerialization.jsonObject(with: historyData) as? [String: String] else {
                throw Stopped.invariant("explicit-frozen-bound-continuation-required")
            }
            let sourceURL = URL(fileURLWithPath: source).resolvingSymlinksInPath()
            let original = try Data(contentsOf: sourceURL)
            try Self.require(Self.sha(original) == expectedSHA && sourceURL.path.hasPrefix(allowed), "immutable-source-journal-required")
            guard let old = try JSONSerialization.jsonObject(with: original) as? [String: Any],
                  let edge = old["edgeID"] as? Int, let intro = old["introduction"] as? String else {
                throw Stopped.invariant("bound-original-edge-and-marker-required")
            }
            try Self.require(old["phase"] as? String == "test-stopped-no-automatic-cleanup"
                && old["requestAttempts"] as? Int == 1 && old["withdrawAttempts"] == nil && edge > 0
                && old["clientID"] as? String == client.id && old["caregiverID"] as? String == caregiver.id
                && old["nativeRunID"] as? String == c.1
                && old["clientFixtureSHA256"] as? String == Self.sha(client.original)
                && old["caregiverFixtureSHA256"] as? String == Self.sha(caregiver.original)
                && intro.hasPrefix("Synthetic native client Cancel ") && intro.count < 1000,
                "only-exact-existing-unwithdrawn-source-edge-allowed")
            for role in ["client", "caregiver"] {
                let historyURL = sourceURL.deletingLastPathComponent().appendingPathComponent("before-\(role)-history.json")
                let bytes = try Data(contentsOf: historyURL)
                try Self.require(Self.sha(bytes) == historyHashes[role], "original-history-snapshot-hash-required")
                guard let rows = try JSONSerialization.jsonObject(with: bytes) as? [String: String], rows.isEmpty else {
                    throw Stopped.invariant("original-untouched-purpose-history-required")
                }
                baselineHistory[role] = [:]
            }
            inherited = old
            introduction = intro
            edgeID = edge
            requestIntentRecorded = true // Inherited ownership only; new requestIntent is explicitly disabled.
        } else {
        introduction = "Synthetic native client Cancel " + UUID().uuidString + " "
            + String(repeating: "Complete synthetic context. ", count: 7)
            + "\nSecond complete synthetic line, retained exactly for the owned recipient."
        }
        document = ["phase": "reserved", "clientID": client.id, "caregiverID": caregiver.id, "nativeRunID": c.1,
                    "introduction": introduction, "clientFixtureSHA256": Self.sha(client.original),
                    "caregiverFixtureSHA256": Self.sha(caregiver.original), "events": [[String: Any]](),
                    "automaticMutationRetry": false, "automaticFailureCleanup": false]
        if let inherited, let edge = inherited["edgeID"] as? Int {
            document["edgeID"] = edge
            document["inheritedRequestAttempts"] = 1
            document["newRequestAttempts"] = 0
            document["sourceJournalSHA256"] = env["QA_NATIVE_GRAPH_CONTINUATION_SOURCE_SHA256"]!
        }
        try persist()
    }
    func verifyContinuationReady() throws -> Int {
        try Self.require(continuationMode && requestIntentRecorded && !withdrawIntentRecorded, "continuation-only-existing-edge-required")
        guard let edge = edgeID else { throw Stopped.invariant("existing-source-edge-required") }
        _ = try requirePair("pending", edge: edge); _ = try ownedEdge(edge)
        for role in ["client", "caregiver"] {
            try Self.require(try history(role) == baselineHistory[role], "preexisting-history-must-still-match-original")
        }
        try privateSnapshot("continuation-before-reciprocal-profiles.json", profiles())
        try event("exact-existing-edge-reconciled-no-create", ["newRequestAttempts": 0])
        return edge
    }
    func event(_ phase: String, _ details: [String: Any] = [:]) throws {
        var events = document["events"] as? [[String: Any]] ?? []
        events.append(["phase": phase, "at": ISO8601DateFormatter().string(from: Date()), "details": details])
        document["events"] = events; document["phase"] = phase; try persist()
    }
    private func persist() throws {
        let temporary = directory.appendingPathComponent("journal-\(UUID().uuidString).tmp")
        try privateFile(temporary, try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted]))
        try Self.require(rename(temporary.path, file.path) == 0, "atomic-journal-rename-failed")
        let descriptor = open(directory.path, O_RDONLY | O_NOFOLLOW)
        try Self.require(descriptor >= 0, "journal-folder-open-failed")
        defer { close(descriptor) }
        try Self.require(fsync(descriptor) == 0, "journal-folder-fsync-failed")
    }
    func privateSnapshot(_ name: String, _ value: Any) throws {
        try Self.require(!name.contains("/") && name.hasSuffix(".json"), "invalid-private-snapshot-name")
        try privateFile(directory.appendingPathComponent(name), try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
    private func privateFile(_ url: URL, _ data: Data) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try Self.require(descriptor >= 0, "exclusive-private-file-required")
        defer { close(descriptor) }
        try Self.require(fchmod(descriptor, 0o600) == 0, "private-file-mode-failed")
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                try Self.require(count > 0, "private-file-write-failed"); offset += count
            }
        }
        try Self.require(fsync(descriptor) == 0, "private-file-fsync-failed")
    }
    func account(_ role: String) -> Account { role == "client" ? client : caregiver }
    func peer(_ role: String) -> Account { role == "client" ? caregiver : client }
    func officialProof(_ role: String) throws {
        try Self.require(["client", "caregiver"].contains(role) && !officialLogins.contains(role), "official-login-budget-exceeded")
        officialLogins.insert(role); try event("official-login-intent", ["role": role, "attempts": 1])
        var account = account(role)
        let response = try CarezaarAPI.callWithHTTPStatus("POST", "auth/login", form: ["email": account.email,
            "password": account.password, "version_app": "1.0.0", "os": "iOS", "version_os": "26.5"])
        try Self.require(response.status == 200, "owned-proof-login-not-http200")
        guard let token = CarezaarAPI.result(response.body)["access_token"] as? String, !token.isEmpty else {
            throw Stopped.invariant("owned-proof-token-missing")
        }
        account.token = token
        let identity = try read("auth/info", token: token)
        try Self.require(stringID(identity["id"]) == account.id && identity["email"] as? String == account.email
            && identity["role"] as? String == role, "exact-owned-official-identity-mismatch")
        account.name = [identity["first_name"] as? String, identity["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
        try Self.require(!account.name.isEmpty, "owned-name-missing")
        if role == "client" { client = account } else { caregiver = account }
        try privateSnapshot("official-\(role)-identity.json", identity)
        try event("official-identity-verified", ["role": role])
    }
    func uiLoginIntent(_ role: String) throws {
        let expected = uiLoginOrder
        try Self.require(uiLoginIndex < expected.count && expected[uiLoginIndex] == role, "native-login-order-or-budget-exceeded")
        uiLoginIndex += 1; try event("native-login-intent", ["role": role, "ordinal": uiLoginIndex, "attempts": 1])
    }
    func read(_ path: String, token: String? = nil) throws -> [String: Any] {
        let response = try CarezaarAPI.callWithHTTPStatus("GET", path, token: token)
        try Self.require(response.status == 200, "independent-owned-read-not-http200")
        return CarezaarAPI.result(response.body)
    }
    func profilePath(_ role: String) -> String {
        "\(role == "client" ? "clients/caregivers" : "caregivers/clients")/\(peer(role).id)"
    }
    func profiles() throws -> [String: [String: Any]] {
        var profiles: [String: [String: Any]] = [:]
        for role in ["client", "caregiver"] {
            let p = try read(profilePath(role), token: account(role).token)
            try Self.require(stringID((p["user"] as? [String: Any])?["id"]) == peer(role).id, "reciprocal-peer-identity-mismatch")
            profiles[role] = p
        }
        return profiles
    }
    @discardableResult func requirePair(_ status: String, edge expected: Int? = nil) throws -> [String: [String: Any]] {
        let p = try profiles()
        for role in ["client", "caregiver"] {
            let row = p[role]!
            let wanted = status == "none" ? "none" : (role == "client" ? "sent" : "received")
            try Self.require(row["match_status"] as? String == wanted && row["is_match"] as? Bool == false, "reciprocal-pending-or-none-state-mismatch")
            if let expected { try Self.require(row["match_id"] as? Int == expected, "exact-reciprocal-edge-mismatch") }
            else { try Self.require(row["match_id"] == nil || row["match_id"] is NSNull, "existing-edge-refused-no-reset") }
        }
        return p
    }
    func requestIntent() throws {
        try Self.require(!continuationMode && !requestIntentRecorded && edgeID == nil, "request-intent-already-recorded-no-replay")
        _ = try requirePair("none")
        requestIntentRecorded = true; document["requestAttempts"] = 1
        try event("native-request-confirm-intent", ["attempts": 1])
    }
    func withdrawalIntent(_ edge: Int) throws {
        try Self.require(requestIntentRecorded && edgeID == edge && !withdrawIntentRecorded, "withdraw-intent-already-recorded-or-unowned")
        _ = try requirePair("pending", edge: edge); _ = try ownedEdge(edge)
        withdrawIntentRecorded = true; document["withdrawAttempts"] = 1
        try event("native-withdraw-confirm-intent", ["attempts": 1])
    }
    func bindCreatedPendingEdge() throws -> Int {
        try Self.require(requestIntentRecorded && edgeID == nil, "edge-bind-requires-one-unacknowledged-create")
        let p = try profiles()
        guard let id = p["client"]?["match_id"] as? Int, id > 0 else { throw Stopped.invariant("created-edge-id-missing-no-replay") }
        _ = try requirePair("pending", edge: id); _ = try ownedEdge(id)
        edgeID = id; document["edgeID"] = id; try event("exact-created-edge-bound")
        return id
    }
    func ownedEdge(_ id: Int) throws -> [String: Any] {
        let row = try read("users/matches/\(id)", token: client.token)
        func nested(_ role: String) -> String { stringID(((row[role] as? [String: Any])?["user"] as? [String: Any])?["id"]) }
        try Self.require(row["id"] as? Int == id && nested("client") == client.id && nested("caregiver") == caregiver.id
            && row["introduction"] as? String == introduction, "exact-marker-and-both-edge-identities-required")
        return row
    }
    func history(_ role: String) throws -> [Int: Data] {
        var result: [Int: Data] = [:]
        for page in 1...20 {
            let response = try CarezaarAPI.callWithHTTPStatus("GET", "users/matches?type=histories&page=\(page)&perPage=10", token: account(role).token)
            try Self.require(response.status == 200, "history-read-not-http200")
            guard let rows = response.body["result"] as? [[String: Any]] else { throw Stopped.invariant("history-array-required") }
            if rows.isEmpty { return result }
            for row in rows {
                guard let id = row["id"] as? Int, result[id] == nil else { throw Stopped.invariant("ambiguous-repeated-history-page") }
                try Self.require(stringID(((row[role] as? [String: Any])?["user"] as? [String: Any])?["id"]) == account(role).id, "foreign-history-owner")
                result[id] = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            }
        }
        throw Stopped.invariant("history-finite-bound-exceeded")
    }
    func snapshotHistory() throws {
        for role in ["client", "caregiver"] {
            let h = try history(role); baselineHistory[role] = h
            try Self.require(h.isEmpty, "first-native-graph-phase-requires-untouched-purpose-history")
            try privateSnapshot("before-\(role)-history.json", h.mapValues { String(data: $0, encoding: .utf8)! }.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value })
        }
    }
    func verifyHistoryAfterWithdrawal(_ edge: Int) throws {
        var retained: [Bool] = []
        for role in ["client", "caregiver"] {
            let after = try history(role), before = baselineHistory[role] ?? [:]
            let added = Set(after.keys).subtracting(before.keys)
            try Self.require(added.isSubset(of: [edge]) && Set(before.keys).isSubset(of: after.keys), "only-created-edge-may-extend-history")
            for (id, bytes) in before { try Self.require(after[id] == bytes, "preexisting-history-changed") }
            if let bytes = after[edge] {
                guard let row = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Stopped.invariant("history-row-object-required") }
                func nested(_ side: String) -> String { stringID(((row[side] as? [String: Any])?["user"] as? [String: Any])?["id"]) }
                try Self.require(row["id"] as? Int == edge && nested("client") == client.id && nested("caregiver") == caregiver.id
                    && row["introduction"] as? String == introduction, "retained-history-must-bind-exact-created-edge")
            }
            retained.append(after[edge] != nil)
            try privateSnapshot("after-\(role)-history.json", after.mapValues { String(data: $0, encoding: .utf8)! }.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value })
        }
        try Self.require(Set(retained).count == 1, "reciprocal-withdrawal-history-disagreement")
        cancelledEdgeRetainedInHistory = retained.first == true
        try event("withdrawal-history-observed", ["createdCancelledEdgeRetained": cancelledEdgeRetainedInHistory,
            "preexistingRowsUnchanged": true, "finishedUnmatchHistoryCovered": false])
    }
    func verifyProvenanceUnchanged() throws {
        try Self.require(try Data(contentsOf: client.file) == client.original, "client-provenance-changed")
        try Self.require(try Data(contentsOf: caregiver.file) == caregiver.original, "caregiver-provenance-changed")
    }
    func stringID(_ value: Any?) -> String { value.map { String(describing: $0) } ?? "" }
}
