import Foundation
import CryptoKit
import Darwin

/// PROPOSED test-only phase boundary. Never creates/accepts/rejects/unmatches an edge through API.
/// All graph mutations are native UI intents; only the explicit C incoming-message seam can POST a message.
final class NativeOwnedGraphPhaseJournal {
    enum Stopped: Error { case invariant(String) }
    enum Phase: String, CaseIterable {
        case A, B, C, D, E
        case Dblank = "D-blank"
        var requester: String { self == .D || self == .Dblank || self == .E ? "client" : "caregiver" }
        var recipient: String { requester == "client" ? "caregiver" : "client" }
        var terminal: String { self == .A || self == .D || self == .Dblank ? "reject" : self == .B ? "withdraw" : "unmatch" }
        var activeFlow: Bool { self == .C || self == .E }
        var blankIntroduction: Bool { self == .Dblank }
        var uiOrder: [String] {
            if self == .C { return ["caregiver", "client", "caregiver", "client", "caregiver"] }
            if self == .B { return [requester, recipient, requester, recipient] }
            return [requester, recipient, requester]
        }
        var unmatcher: String { self == .C ? "client" : "caregiver" }
    }
    struct Account {
        let role: String, email: String, password: String, id: String, file: URL, original: Data
        var name = ""
        var token = ""
    }
    let phase: Phase
    let continuesExistingA: Bool
    let continuesExistingC: Bool
    let terminalReadOnlyE: Bool
    let terminalReadOnlyC: Bool
    private var uiOrder: [String] { terminalReadOnlyE ? ["client"] : terminalReadOnlyC ? ["caregiver"] : continuesExistingC ? ["caregiver", "client", "caregiver"] : continuesExistingA ? ["client", "caregiver"] : phase.uiOrder }
    private(set) var client: Account
    private(set) var caregiver: Account
    let directory: URL
    let introduction: String
    let marker: String
    private let file: URL
    private var document: [String: Any]
    private var proofGETAttempts: [String: Int] = [:]
    private var pendingRequestsWitnessRoles: Set<String> = []
    private var officialLogins: Set<String> = []
    private var uiLoginIndex = 0
    private var intents: Set<String> = []
    private var baselineHistory: [String: [Int: Data]] = [:]
    private(set) var edgeID: Int?
    private(set) var retainedInHistory = false
    private(set) var chatID: Int?
    private var baselineChatID: Int?
    private var baselineMessages: [Int: Data] = [:]
    private(set) var messageTexts: [Int: String] = [:]
    private var nativeMessageIntents: [String] = []
    private var incomingIntents: [String] = []
    private var chatCreateIntent = false
    private(set) var resumesBoundChat = false
    static func require(_ ok: Bool, _ code: String) throws { if !ok { throw Stopped.invariant(code) } }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    init(environment env: [String: String]) throws {
        guard env["QA_NATIVE_GRAPH_PHASE_BATCH"] == "1", let rawPhase = env["QA_NATIVE_GRAPH_PHASE"],
              let phase = Phase(rawValue: rawPhase), let cf = env["QA_NATIVE_GRAPH_CLIENT_FILE"],
              let gf = env["QA_NATIVE_GRAPH_CAREGIVER_FILE"], let folder = env["QA_NATIVE_GRAPH_JOURNAL_DIR"] else {
            throw Stopped.invariant("explicit-reviewed-phase-and-native-fixtures-required")
        }
        self.phase = phase
        continuesExistingA = env["QA_NATIVE_GRAPH_A_CONTINUE_EXISTING"] == "1"
        continuesExistingC = env["QA_NATIVE_GRAPH_C_CONTINUE_EXISTING"] == "1"
        terminalReadOnlyC = env["QA_NATIVE_GRAPH_C_TERMINAL_READONLY"] == "1"
        terminalReadOnlyE = env["QA_NATIVE_GRAPH_E_TERMINAL_READONLY"] == "1"
        try Self.require(!terminalReadOnlyE || (phase == .E && !continuesExistingA && !continuesExistingC), "terminal-E-only-no-fresh-phase")
        try Self.require(!terminalReadOnlyC || continuesExistingC, "terminal-C-must-inherit-exact-original-C")
        try Self.require(!continuesExistingC || (phase == .C && !continuesExistingA), "only-exact-existing-active-C-continuation")
        try Self.require(!continuesExistingA || phase == .A, "only-existing-A-continuation-permitted")
        func account(_ path: String, role: String) throws -> (Account, String) {
            let record = try NativeLifecycleFixture.read(path)
            guard let p = record["native_provenance"] as? [String: Any], let run = p["run_id"] as? String,
                  let marker = p["marker"] as? String, let email = record["email"] as? String,
                  let password = record["password"] as? String, let id = record["user_id"] as? String else {
                throw Stopped.invariant("complete-native-account-record-required")
            }
            try Self.require(p["purpose"] as? String == "carezaar-native-final-qa"
                && p["role"] as? String == role && record["role"] as? String == role
                && ["modern", "small"].contains(p["size"] as? String ?? "") && p["stage"] as? String == "signupComplete"
                && p["provider_create_attempts"] as? Int == 1 && p["app_registration_attempts"] as? Int == 1
                && p["provider_ownership_verified"] as? Bool == true && !run.isEmpty && !id.isEmpty && !password.isEmpty
                && email.hasPrefix("carezaar-native-\(marker)@") && record["deleted"] as? Bool != true,
                "exact-completed-native-purpose-provenance-required")
            if role == "caregiver" {
                let repair = record["native_dob_repair"] as? [String: Any]
                let historicallyRepaired = repair?["stage"] as? String == "complete"
                    && repair?["profilePostAttempts"] as? Int == 1
                // New Small signup already verifies the selected DOB from the saved
                // role profile before recording these completion witnesses. It has
                // no historical repair and must not invent that provenance.
                let verifiedFreshSmallSignup = p["size"] as? String == "small"
                    && (p["savedPayLocationVerified_at"] as? String)?.isEmpty == false
                    && (p["signupComplete_at"] as? String)?.isEmpty == false
                    && record["native_dob_repair"] == nil
                try Self.require(historicallyRepaired || verifiedFreshSmallSignup,
                                 "completed-caregiver-saved-date-proof-required")
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
        let allowed = URL(fileURLWithPath: "/tmp/carezaar-final-native-graph-phases-20261019").resolvingSymlinksInPath().path + "/"
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        try Self.require(raw.standardizedFileURL.path == directory.path || raw.path.replacingOccurrences(of: "/tmp/", with: "/private/tmp/") == directory.path, "unexplained-journal-path-alias")
        try Self.require(directory.path.hasPrefix(allowed) && attributes[.type] as? FileAttributeType == .typeDirectory
            && (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
            && (try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty, "fresh-private-journal-folder-required-no-replay")
        file = directory.appendingPathComponent("journal.json")
        var inherited: [String: Any]?
        var inheritedHistories: [String: [Int: Data]] = [:]
        var inheritedSourceSHA: String?
        if terminalReadOnlyE {
            guard let sourcePath = env["QA_NATIVE_GRAPH_E_SOURCE_FILE"], let digest = env["QA_NATIVE_GRAPH_E_SOURCE_SHA256"],
                  let rawHashes = env["QA_NATIVE_GRAPH_E_HISTORY_SHA256"], let hashData = rawHashes.data(using: .utf8),
                  let hashes = try JSONSerialization.jsonObject(with: hashData) as? [String: String] else { throw Stopped.invariant("explicit-ended-E-authority") }
            let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
            try Self.require(source.path.hasPrefix(allowed) && source.lastPathComponent == "journal.json", "owned-ended-E-source-root")
            let bytes = try Data(contentsOf: source)
            try Self.require(Self.sha(bytes) == digest, "ended-E-source-immutable")
            guard let original = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let edge = original["edgeID"] as? Int,
                  let oldMarker = original["marker"] as? String, let oldIntro = original["introduction"] as? String else { throw Stopped.invariant("bound-ended-E-fields") }
            try Self.require(original["scenario"] as? String == "E" && original["requester"] as? String == "client"
                && original["requestAttempts"] as? Int == 1 && original["acceptAttempts"] as? Int == 1 && original["unmatchAttempts"] as? Int == 1
                && edge > 0 && original["clientID"] as? String == client.id && original["caregiverID"] as? String == caregiver.id
                && original["nativeRunID"] as? String == c.1 && original["clientFixtureSHA256"] as? String == Self.sha(client.original)
                && original["caregiverFixtureSHA256"] as? String == Self.sha(caregiver.original)
                && oldMarker.hasPrefix("Synthetic native phase E ") && oldIntro.hasPrefix(oldMarker), "exact-owned-ended-E-only")
            for action in ["reject", "withdraw", "chatCreate", "nativeMessage", "peerIncomingAPI"] { try Self.require(original[action + "Attempts"] == nil, "ended-E-has-no-other-actions") }
            for role in ["client", "caregiver"] {
                let data = try Data(contentsOf: source.deletingLastPathComponent().appendingPathComponent("before-\(role)-history.json"))
                try Self.require(Self.sha(data) == hashes[role], "ended-E-before-history-hash")
                guard let rows = try JSONSerialization.jsonObject(with: data) as? [String: String] else { throw Stopped.invariant("ended-E-history-map") }
                var normalized: [Int: Data] = [:]
                for (key, value) in rows {
                    guard let id = Int(key), normalized[id] == nil, let bytes = value.data(using: .utf8) else { throw Stopped.invariant("unique-ended-E-history") }
                    normalized[id] = bytes
                }
                inheritedHistories[role] = normalized
            }
            inherited = original; inheritedSourceSHA = digest; marker = oldMarker; introduction = oldIntro
        } else if continuesExistingC {
            guard let sourcePath = env["QA_NATIVE_GRAPH_C_SOURCE_FILE"], let expectedSHA = env["QA_NATIVE_GRAPH_C_SOURCE_SHA256"],
                  let rawHashes = env["QA_NATIVE_GRAPH_C_HISTORY_SHA256"], let hashData = rawHashes.data(using: .utf8),
                  let historyHashes = try JSONSerialization.jsonObject(with: hashData) as? [String: String] else {
                throw Stopped.invariant("explicit-frozen-failed-C-source-required")
            }
            let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
            try Self.require(source.path.hasPrefix(allowed) && source.lastPathComponent == "journal.json", "owned-existing-C-source-root")
            let bytes = try Data(contentsOf: source)
            try Self.require(Self.sha(bytes) == expectedSHA, "failed-C-journal-immutable")
            guard let original = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let edge = original["edgeID"] as? Int, let oldMarker = original["marker"] as? String,
                  let oldIntro = original["introduction"] as? String else { throw Stopped.invariant("bound-C-source-fields") }
            try Self.require(original["scenario"] as? String == "C" && original["requester"] as? String == "caregiver"
                && original["requestAttempts"] as? Int == 1 && original["acceptAttempts"] as? Int == 1
                && original["chatCreateAttempts"] as? Int == 1 && original["chatID"] == nil
                && edge > 0 && original["clientID"] as? String == client.id && original["caregiverID"] as? String == caregiver.id
                && original["nativeRunID"] as? String == c.1
                && original["clientFixtureSHA256"] as? String == Self.sha(client.original)
                && original["caregiverFixtureSHA256"] as? String == Self.sha(caregiver.original)
                && oldMarker.hasPrefix("Synthetic native phase C ") && oldIntro.hasPrefix(oldMarker)
                && oldIntro.count < 1000, "exact-original-C-active-edge-and-unknown-empty-chat")
            for action in ["reject", "withdraw", "unmatch", "nativeMessage", "peerIncomingAPI"] {
                try Self.require(original[action + "Attempts"] == nil, "failed-C-no-terminal-or-message-intents")
            }
            for role in ["client", "caregiver"] {
                let path = source.deletingLastPathComponent().appendingPathComponent("before-\(role)-history.json")
                let data = try Data(contentsOf: path)
                try Self.require(Self.sha(data) == historyHashes[role], "original-C-history-SHA")
                guard let rows = try JSONSerialization.jsonObject(with: data) as? [String: String] else { throw Stopped.invariant("original-C-history-map") }
                var normalized: [Int: Data] = [:]
                for (key, value) in rows {
                    guard let id = Int(key), normalized[id] == nil, let valueBytes = value.data(using: .utf8) else { throw Stopped.invariant("unique-C-history-ids") }
                    normalized[id] = valueBytes
                }
                inheritedHistories[role] = normalized
            }
            inherited = original; inheritedSourceSHA = expectedSHA; marker = oldMarker; introduction = oldIntro
        } else if continuesExistingA {
            guard let sourcePath = env["QA_NATIVE_GRAPH_A_SOURCE_FILE"], let expectedSHA = env["QA_NATIVE_GRAPH_A_SOURCE_SHA256"],
                  let historyHashesJSON = env["QA_NATIVE_GRAPH_A_HISTORY_SHA256"], let hashData = historyHashesJSON.data(using: .utf8),
                  let historyHashes = try JSONSerialization.jsonObject(with: hashData) as? [String: String] else {
                throw Stopped.invariant("explicit-frozen-exact-A-source-required")
            }
            let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
            try Self.require(source.path.hasPrefix(allowed) && source.lastPathComponent == "journal.json", "existing-owned-A-source-root-required")
            let sourceBytes = try Data(contentsOf: source)
            try Self.require(Self.sha(sourceBytes) == expectedSHA, "original-A-journal-must-remain-immutable")
            guard let original = try JSONSerialization.jsonObject(with: sourceBytes) as? [String: Any],
                  let sourceEdge = original["edgeID"] as? Int, let originalMarker = original["marker"] as? String,
                  let originalIntro = original["introduction"] as? String else { throw Stopped.invariant("complete-bound-source-A-required") }
            try Self.require(original["scenario"] as? String == "A" && original["requester"] as? String == "caregiver"
                && original["phase"] as? String == "exact-created-edge-bound" && original["requestAttempts"] as? Int == 1
                && sourceEdge > 0 && original["clientID"] as? String == client.id && original["caregiverID"] as? String == caregiver.id
                && original["nativeRunID"] as? String == c.1 && original["clientFixtureSHA256"] as? String == Self.sha(client.original)
                && original["caregiverFixtureSHA256"] as? String == Self.sha(caregiver.original)
                && originalMarker.hasPrefix("Synthetic native phase A ") && originalIntro.hasPrefix(originalMarker)
                && !originalIntro.isEmpty && originalIntro.count < 1000, "exact-owned-created-A-edge-and-introduction-only")
            for action in ["reject", "withdraw", "accept", "unmatch", "nativeMessage", "peerIncomingAPI"] {
                try Self.require(original[action + "Attempts"] == nil, "source-A-must-have-zero-terminal-and-message-intents")
            }
            try Self.require(original["chatID"] == nil, "source-A-must-not-have-chat")
            for role in ["client", "caregiver"] {
                let path = source.deletingLastPathComponent().appendingPathComponent("before-\(role)-history.json")
                let data = try Data(contentsOf: path)
                try Self.require(Self.sha(data) == historyHashes[role], "exact-original-before-history-SHA-required")
                guard let rows = try JSONSerialization.jsonObject(with: data) as? [String: String] else { throw Stopped.invariant("source-history-map-required") }
                var normalized: [Int: Data] = [:]
                for (key, value) in rows {
                    guard let id = Int(key), normalized[id] == nil, let bytes = value.data(using: .utf8) else { throw Stopped.invariant("unique-original-history-IDs-required") }
                    normalized[id] = bytes
                }
                inheritedHistories[role] = normalized
            }
            inherited = original; inheritedSourceSHA = expectedSHA
            marker = originalMarker; introduction = originalIntro
        } else {
            marker = "Synthetic native phase \(phase.rawValue) " + UUID().uuidString
            introduction = phase.blankIntroduction ? "" : marker + " "
                + String(repeating: "Complete owned introduction context. ", count: 6)
                + "\nSecond complete synthetic line for the exact owned recipient."
        }
        document = ["phase": "reserved", "scenario": phase.rawValue, "requester": phase.requester,
                    "clientID": client.id, "caregiverID": caregiver.id, "nativeRunID": c.1,
                    "marker": marker, "introduction": introduction, "blankIntroduction": phase.blankIntroduction,
                    "clientFixtureSHA256": Self.sha(client.original), "caregiverFixtureSHA256": Self.sha(caregiver.original),
                    "events": [[String: Any]](), "officialProofBudgetPerRole": 1, "uiLoginOrder": terminalReadOnlyE ? ["client"] : terminalReadOnlyC ? ["caregiver"] : continuesExistingC ? ["caregiver", "client", "caregiver"] : continuesExistingA ? ["client", "caregiver"] : phase.uiOrder,
                    "automaticMutationRetry": false, "automaticFailureCleanup": false]
        if let inherited {
            guard let inheritedEdge = inherited["edgeID"] as? Int, let sourceSHA = inheritedSourceSHA else { throw Stopped.invariant("verified-inherited-A-fields-required") }
            edgeID = inheritedEdge; intents = (continuesExistingC || terminalReadOnlyE) ? ["request", "accept"] : ["request"]; baselineHistory = inheritedHistories
            document["edgeID"] = inheritedEdge; document["inheritedRequestAttempts"] = 1; document["newRequestAttempts"] = 0
            document["sourceJournalSHA256"] = sourceSHA
            if terminalReadOnlyE { document["terminalReadOnlyE"] = true; document["inheritedAcceptAttempts"] = 1; document["inheritedUnmatchAttempts"] = 1 }
            if continuesExistingC {
                document["inheritedAcceptAttempts"] = 1; document["inheritedChatCreateAttempts"] = 1
                document["originalEmptyChatIDUnknown"] = true; document["newAcceptAttempts"] = 0
            }
            for role in ["client", "caregiver"] {
                let rows = inheritedHistories[role]!
                try privateSnapshot("before-\(role)-history.json", rows.reduce(into: [String: String]()) { $0[String($1.key)] = String(decoding: $1.value, as: UTF8.self) })
            }
        }
        try persist()
    }
    func verifyInheritedPendingAndHistory() throws {
        guard continuesExistingA, let edge = edgeID else { throw Stopped.invariant("exact-existing-A-only") }
        _ = try requirePair("pending", edge: edge); _ = try ownedEdge(edge)
        for role in ["client", "caregiver"] { try Self.require(try history(role) == baselineHistory[role], "pending-A-must-preserve-original-before-history") }
        try event("exact-inherited-A-pending-and-baseline-verified", ["newRequestAttempts": 0])
    }
    func verifyInheritedActiveCAndHistory() throws {
        guard continuesExistingC, let edge = edgeID else { throw Stopped.invariant("exact-existing-C-only") }
        _ = try requirePair("active", edge: edge); _ = try ownedEdge(edge)
        for role in ["client", "caregiver"] { try Self.require(try history(role) == baselineHistory[role], "active-C-original-history-preserved") }
        try event("exact-inherited-C-active-and-history-verified", ["newRequests": 0, "newAccepts": 0, "originalEmptyChatIDUnknown": true])
    }
    func adoptEndedCForReadOnlyCompletion(environment env: [String: String]) throws {
        guard terminalReadOnlyC, let path = env["QA_NATIVE_GRAPH_C_TERMINAL_SOURCE_FILE"],
              let digest = env["QA_NATIVE_GRAPH_C_TERMINAL_SOURCE_SHA256"] else { throw Stopped.invariant("exact-ended-C-source-required") }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try Self.require(url.path.hasPrefix(directory.deletingLastPathComponent().path + "/") && url.lastPathComponent == "journal.json", "owned-ended-C-source-root")
        let bytes = try Data(contentsOf: url)
        try Self.require(Self.sha(bytes) == digest, "ended-C-source-immutable")
        guard let prior = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let id = prior["chatID"] as? Int,
              let events = prior["events"] as? [[String: Any]], let nativeTexts = prior["nativeMessageIntentTexts"] as? [String],
              let peerTexts = prior["peerIncomingIntentTexts"] as? [String] else { throw Stopped.invariant("ended-C-complete-chat-witness-required") }
        try Self.require(id > 0 && prior["edgeID"] as? Int == edgeID && prior["marker"] as? String == marker
            && prior["introduction"] as? String == introduction && prior["clientID"] as? String == client.id
            && prior["caregiverID"] as? String == caregiver.id && prior["sourceJournalSHA256"] as? String == document["sourceJournalSHA256"] as? String
            && prior["chatWorkflowComplete"] as? Bool == true && prior["unmatchAttempts"] as? Int == 1
            && prior["nativeMessageAttempts"] as? Int == 3 && prior["peerIncomingAPIAttempts"] as? Int == 2
            && nativeTexts.count == 3 && peerTexts.count == 2, "exact-ended-C-workflow-no-replay-authority")
        chatID = id; baselineChatID = id; resumesBoundChat = true
        document["chatID"] = id; document["terminalSourceSHA256"] = digest; document["terminalReadOnlyC"] = true
        _ = try requirePair("none")
        let clientChat = try ownedChat("client"), caregiverChat = try ownedChat("caregiver")
        guard let rows = clientChat["messages"] as? [[String: Any]] else { throw Stopped.invariant("ended-chat-messages-required") }
        let nativeAck = events.filter { $0["phase"] as? String == "native-message-acknowledged" }.compactMap { $0["details"] as? [String: Any] }
        let peerAck = events.filter { $0["phase"] as? String == "peer-incoming-acknowledged" }.compactMap { $0["details"] as? [String: Any] }
        try Self.require(nativeAck.count == 3 && peerAck.count == 2 && rows.count == 5, "exact-five-acknowledged-messages-required")
        for (acks, texts, fromCaregiver) in [(nativeAck, nativeTexts, false), (peerAck, peerTexts, true)] {
            for (index, ack) in acks.enumerated() {
                guard let messageID = ack["messageID"] as? Int else { throw Stopped.invariant("acknowledged-message-ID") }
                let matches = rows.filter { $0["id"] as? Int == messageID }
                try Self.require(matches.count == 1 && matches[0]["message"] as? String == texts[index], "exact-acknowledged-message-text-and-ID")
                let expectedSender = fromCaregiver || ack["role"] as? String == "caregiver"
                try Self.require(matches[0]["is_from_caregiver"] as? Bool == expectedSender, "exact-acknowledged-message-sender")
                if let parent = ack["parentID"] as? Int {
                    try Self.require((matches[0]["parent"] as? [String: Any])?["id"] as? Int == parent, "exact-acknowledged-reply-parent")
                }
                baselineMessages[messageID] = try immutableMessage(matches[0]); messageTexts[messageID] = texts[index]
            }
        }
        try verifyMessageHistory(caregiverChat)
        try privateSnapshot("terminal-chat-client-baseline.json", clientChat)
        try privateSnapshot("terminal-chat-caregiver-baseline.json", caregiverChat)
        try event("exact-ended-C-readonly-bound", ["newGraphWrites": 0, "newMessages": 0, "messageCount": rows.count])
    }
    func verifyEndedReadOnlyCompletion() throws {
        try Self.require((terminalReadOnlyC || terminalReadOnlyE) && intents == ["request", "accept"] && officialLogins == ["client", "caregiver"]
            && uiLoginIndex == 1 && nativeMessageIntents.isEmpty && incomingIntents.isEmpty && !chatCreateIntent,
            "ended-C-readonly-exact-login-and-zero-mutation-contract")
        guard let edge = edgeID else { throw Stopped.invariant("ended-edge-required") }
        _ = try requirePair("none")
        for role in ["client", "caregiver"] {
            let before = baselineHistory[role]!, after = try history(role)
            try Self.require(Set(before.keys).isSubset(of: after.keys) && Set(after.keys).subtracting(before.keys) == [edge], "only-bound-ended-history-extension")
            for (id, bytes) in before { try Self.require(after[id] == bytes, "preexisting-history-immutable") }
            guard let bytes = after[edge], let row = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Stopped.invariant("ended-history-row-required") }
            try Self.require((row["finished_at"] as? String)?.isEmpty == false && matchesIntroduction(row["introduction"]), "ended-history-time-and-intro")
            try privateSnapshot("after-\(role)-history.json", after.reduce(into: [String: String]()) { $0[String($1.key)] = String(decoding: $1.value, as: UTF8.self) })
            if terminalReadOnlyC { try verifyMessageHistory(ownedChat(role)) }
        }
        try verifyProvenanceUnchanged(); try privateSnapshot("final-reciprocal-profiles.json", profiles())
        try event("terminal-readonly-\(phase.rawValue)-complete", ["bothNONE": true, "bothHistoryUI": true, "bothClosedChats": terminalReadOnlyC, "newGraphWrites": 0, "newMessages": 0])
    }
    func adoptExactBoundChatFromStoppedContinuation(environment env: [String: String]) throws {
        guard continuesExistingC, !resumesBoundChat, chatID == nil,
              let path = env["QA_NATIVE_GRAPH_C_BOUND_SOURCE_FILE"], let expectedSHA = env["QA_NATIVE_GRAPH_C_BOUND_SOURCE_SHA256"] else { throw Stopped.invariant("explicit-bound-C-source-required") }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try Self.require(url.path.hasPrefix(directory.deletingLastPathComponent().path + "/") && url.lastPathComponent == "journal.json", "owned-bound-C-source-root")
        let bytes = try Data(contentsOf: url)
        try Self.require(Self.sha(bytes) == expectedSHA, "stopped-bound-C-source-immutable")
        guard let prior = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let id = prior["chatID"] as? Int,
              let events = prior["events"] as? [[String: Any]] else { throw Stopped.invariant("positive-observed-bound-C-chat-required") }
        try Self.require(id > 0 && prior["edgeID"] as? Int == edgeID && prior["marker"] as? String == marker
            && prior["introduction"] as? String == introduction && prior["clientID"] as? String == client.id
            && prior["caregiverID"] as? String == caregiver.id && prior["sourceJournalSHA256"] as? String == document["sourceJournalSHA256"] as? String
            && prior["inheritedRequestAttempts"] as? Int == 1 && prior["inheritedAcceptAttempts"] as? Int == 1
            && prior["newRequestAttempts"] as? Int == 0 && prior["newAcceptAttempts"] as? Int == 0
            && prior["chatCreateAttempts"] as? Int == 1 && prior["nativeMessageAttempts"] == nil
            && prior["peerIncomingAPIAttempts"] == nil && prior["unmatchAttempts"] == nil
            && !events.contains(where: { $0["phase"] as? String == "native-login-intent" }), "exact-stopped-C-before-first-send")
        chatID = id; baselineChatID = id; resumesBoundChat = true
        document["chatID"] = id; document["boundChatSourceSHA256"] = expectedSHA
        document["newChatCreateAttempts"] = 0; document["inheritedCurrentChatOpeningAttempts"] = 1
        let clientChat = try ownedChat("client"), caregiverChat = try ownedChat("caregiver")
        try privateSnapshot("bound-existing-chat-client-readback.json", clientChat)
        try privateSnapshot("bound-existing-chat-caregiver-readback.json", caregiverChat)
        try Self.require((clientChat["messages"] as? [[String: Any]])?.isEmpty == true
            && (caregiverChat["messages"] as? [[String: Any]])?.isEmpty == true, "bound-C-still-empty-before-any-send")
        try privateSnapshot("chat-baseline.json", clientChat)
        try event("exact-bound-C-chat-resumed-without-create", ["newRequest": 0, "newAccept": 0, "newChatCreate": 0,
            "bothAuthenticatedPeerReadbacks": true, "bothMessagesEmpty": true, "sourceDraftNotSent": true])
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
        // Persist status/shape before asserting; successful login tokens are never written.
        let responseBytes = try JSONSerialization.data(withJSONObject: response.body, options: [.sortedKeys])
        try privateSnapshot("official-\(role)-login-response-metadata.json", ["status": response.status,
            "bodySHA256": Self.sha(responseBytes), "topLevelKeys": response.body.keys.sorted(),
            "resultShape": response.body["result"] is [String: Any] ? "object" : "other"])
        try event("official-login-response-observed", ["role": role, "status": response.status])
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
    private func get(_ path: String, token: String? = nil) throws -> (status: Int, body: [String: Any]) {
        if ProcessInfo.processInfo.environment["QA_NATIVE_GRAPH_REMAINING_CORE_REQUESTS"] == "1" {
            try Self.require(proofGETAttempts.values.reduce(0, +) < 500, "remaining-core-test-journal500-stop-before-dispatch")
        }
        if ProcessInfo.processInfo.environment["QA_NATIVE_GRAPH_FULL_D_REQUESTS"] == "1" {
            try Self.require(proofGETAttempts.values.reduce(0, +) < 154, "full-D-journal-GET-cap154-before-dispatch")
        }
        if ProcessInfo.processInfo.environment["QA_NATIVE_GRAPH_SCOPED_SMALL_NEW_CG_CLIENT_REJECT"] == "1" {
            try Self.require(proofGETAttempts.values.reduce(0, +) < 114, "Small-derived-journal-GET-cap114-no-extra-calls")
        }
        proofGETAttempts[path, default: 0] += 1
        let chatReads = proofGETAttempts.filter { $0.key.hasPrefix("users/chats/") }.values.reduce(0, +)
        try Self.require(chatReads <= 128, "finite-test-process-chat-read-bound")
        document["testProcessGETAttempts"] = proofGETAttempts
        try event("owned-GET-intent")
        return try CarezaarAPI.callWithHTTPStatus("GET", path, token: token)
    }
    func read(_ path: String, token: String? = nil) throws -> [String: Any] {
        let response = try get(path, token: token)
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
    func history(_ role: String) throws -> [Int: Data] {
        var result: [Int: Data] = [:]
        for page in 1...20 {
            let response = try get("users/matches?type=histories&page=\(page)&perPage=10", token: account(role).token)
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

    func uiLoginIntent(_ role: String) throws {
        try Self.require(uiLoginIndex < uiOrder.count && uiOrder[uiLoginIndex] == role, "native-login-order-or-budget-exceeded")
        uiLoginIndex += 1
        try event("native-login-intent", ["role": role, "ordinal": uiLoginIndex, "attempts": 1])
    }
    @discardableResult func requirePair(_ status: String, edge: Int? = nil) throws -> [String: [String: Any]] {
        try Self.require(["none", "pending", "active"].contains(status), "invalid-pair-state")
        let values = try profiles()
        for role in ["client", "caregiver"] {
            let row = values[role]!
            let wanted = status == "pending" ? (role == phase.requester ? "sent" : "received") : status
            try Self.require(row["match_status"] as? String == wanted && row["is_match"] as? Bool == (status == "active"), "reciprocal-role-aware-state-mismatch")
            if let edge { try Self.require(row["match_id"] as? Int == edge, "reciprocal-exact-edge-mismatch") }
            else { try Self.require(row["match_id"] == nil || row["match_id"] is NSNull, "existing-edge-refused-no-reset") }
        }
        return values
    }
    func matchesIntroduction(_ value: Any?) -> Bool {
        if phase.blankIntroduction { return value == nil || value is NSNull || (value as? String) == "" }
        return value as? String == introduction
    }
    func ownedEdge(_ id: Int) throws -> [String: Any] {
        let row = try read("users/matches/\(id)", token: client.token)
        func nested(_ role: String) -> String { stringID(((row[role] as? [String: Any])?["user"] as? [String: Any])?["id"]) }
        try Self.require(row["id"] as? Int == id && nested("client") == client.id && nested("caregiver") == caregiver.id
            && matchesIntroduction(row["introduction"]), "exact-edge-participants-and-full-introduction-required")
        return row
    }
    /// One finite Requests read per exact verified owner, after the necessary native request is bound.
    /// Saves the complete decoded HTTP body and status, not original raw HTTP bytes/headers.
    func captureBothPendingRequestsWitness(_ id: Int) throws {
        try Self.require(edgeID == id && intents == ["request"] && pendingRequestsWitnessRoles.isEmpty, "bound-native-request-before-one-Requests-witness-pair")
        for role in [phase.requester, phase.recipient] {
            try Self.require(!pendingRequestsWitnessRoles.contains(role), "one-Requests-witness-per-owner-no-retry")
            pendingRequestsWitnessRoles.insert(role)
            let path = "users/matches?type=requests&page=1&perPage=10"
            try event("pending-Requests-wire-read-intent", ["role": role, "page": 1, "perPage": 10])
            let response = try get(path, token: account(role).token)
            let canonical = try JSONSerialization.data(withJSONObject: response.body, options: [.sortedKeys])
            try privateSnapshot("pending-Requests-\(role)-decoded-wire.json", ["status": response.status,
                "decodedBody": response.body, "canonicalDecodedBodySHA256": Self.sha(canonical),
                "canonicalDecodedBodyBase64": canonical.base64EncodedString(),
                "bodyRepresentation": "complete decoded JSON; not raw HTTP bytes", "queryType": "requests"])
            try Self.require(response.status == 200, "exact-owner-Requests-status200-required")
            guard let rows = response.body["result"] as? [[String: Any]] else { throw Stopped.invariant("Requests-result-array-required") }
            let exact = rows.filter { $0["id"] as? Int == id }
            try event("pending-Requests-decoded-row-count", ["role": role, "status": response.status,
                "rowCount": rows.count, "exactEdgeCount": exact.count])
            try Self.require(rows.count <= 10 && exact.count == 1, "exact-bound-edge-on-both-owner-Requests-firstpage-required")
            let row = exact[0]
            func nested(_ side: String) -> String { stringID(((row[side] as? [String: Any])?["user"] as? [String: Any])?["id"]) }
            try Self.require(nested("client") == client.id && nested("caregiver") == caregiver.id
                && matchesIntroduction(row["introduction"]) && (row["finished_at"] == nil || row["finished_at"] is NSNull)
                && row["is_client_accepted"] as? Bool == (phase.requester == "client")
                && row["is_caregiver_accepted"] as? Bool == (phase.requester == "caregiver")
                && row["is_active"] as? Bool == false, "Requests-row-exact-participants-fullintro-pending-flags")
            try event("pending-Requests-exact-owned-decoded-wire-verified", ["role": role, "status": 200,
                "exactEdgeCount": 1, "fullIntroductionEqual": true, "pendingFlagsExact": true])
        }
    }
    func requestIntent(_ role: String) throws {
        try Self.require(!terminalReadOnlyE && !continuesExistingA && !continuesExistingC && role == phase.requester && !intents.contains("request") && edgeID == nil, "one-owned-requester-only-no-replay")
        _ = try requirePair("none")
        try Self.require(baselineHistory.count == 2, "history-baseline-required-before-create")
        intents.insert("request"); document["requestAttempts"] = 1
        try event("native-request-confirm-intent", ["role": role, "attempts": 1])
    }
    func bindCreatedPendingEdge() throws -> Int {
        try Self.require(intents.contains("request") && edgeID == nil, "one-create-intent-before-binding")
        let values = try profiles()
        guard let edge = values["client"]?["match_id"] as? Int, edge > 0 else { throw Stopped.invariant("created-edge-missing-no-replay") }
        try Self.require(baselineHistory.values.allSatisfy { $0[edge] == nil }, "historical-edge-reuse-refused")
        _ = try requirePair("pending", edge: edge); _ = try ownedEdge(edge)
        edgeID = edge; document["edgeID"] = edge
        try event("exact-created-edge-bound", ["blankServerIntroduction": phase.blankIntroduction])
        return edge
    }
    func mutationIntent(_ action: String, role: String) throws {
        try Self.require(!terminalReadOnlyC && !terminalReadOnlyE, "terminal-readonly-no-graph-mutation")
        guard let edge = edgeID else { throw Stopped.invariant("bound-created-edge-required") }
        try Self.require(!intents.contains(action), "one-mutation-intent-no-replay")
        if action == "accept" {
            try Self.require(phase.activeFlow && role == phase.recipient, "accept-only-owned-recipient")
            _ = try requirePair("pending", edge: edge)
        } else if action == "unmatch" {
            try Self.require(phase.activeFlow && role == phase.unmatcher && intents.contains("accept"), "unmatch-only-contracted-active-role")
            _ = try requirePair("active", edge: edge)
        } else {
            try Self.require(action == phase.terminal && (role == (action == "withdraw" ? phase.requester : phase.recipient)), "terminal-action-role-contract")
            _ = try requirePair("pending", edge: edge)
        }
        _ = try ownedEdge(edge)
        intents.insert(action); document[action + "Attempts"] = 1
        try event("native-" + action + "-confirm-intent", ["role": role, "attempts": 1])
    }
    func snapshotHistory() throws {
        for role in ["client", "caregiver"] {
            let rows = try history(role); baselineHistory[role] = rows
            try privateSnapshot("before-\(role)-history.json", rows.reduce(into: [String: String]()) { $0[String($1.key)] = String(decoding: $1.value, as: UTF8.self) })
        }
        try event("both-normalized-history-baselines-captured")
    }
    func verifyHistoryAndCompletion() throws {
        guard let edge = edgeID else { throw Stopped.invariant("bound-edge-required-at-completion") }
        let expected: Set<String> = phase.activeFlow ? ["request", "accept", "unmatch"] : ["request", phase.terminal]
        try Self.require(intents == expected && officialLogins == ["client", "caregiver"] && uiLoginIndex == uiOrder.count,
                         "finite-contract-intents-and-logins-must-complete-exactly")
        _ = try requirePair("none")
        var retained: [Bool] = []
        for role in ["client", "caregiver"] {
            let before = baselineHistory[role]!, after = try history(role)
            try Self.require(Set(before.keys).isSubset(of: after.keys) && Set(after.keys).subtracting(before.keys).isSubset(of: [edge]), "only-owned-new-edge-may-extend-history")
            for (id, bytes) in before { try Self.require(after[id] == bytes, "preexisting-normalized-history-row-changed") }
            if let bytes = after[edge] {
                guard let row = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Stopped.invariant("finished-history-object-required") }
                try Self.require(matchesIntroduction(row["introduction"]), "finished-introduction-must-be-preserved")
                func nested(_ side: String) -> String { stringID(((row[side] as? [String: Any])?["user"] as? [String: Any])?["id"]) }
                try Self.require(nested("client") == client.id && nested("caregiver") == caregiver.id, "finished-row-exact-owned-pair")
                if phase.activeFlow {
                    try Self.require((row["finished_at"] as? String)?.isEmpty == false,
                                     "unmatch-must-retain-actually-finished-history")
                }
            }
            if phase.activeFlow { try Self.require(after[edge] != nil, "finished-unmatch-history-required-both-roles") }
            retained.append(after[edge] != nil)
            try privateSnapshot("after-\(role)-history.json", after.reduce(into: [String: String]()) { $0[String($1.key)] = String(decoding: $1.value, as: UTF8.self) })
        }
        try Self.require(Set(retained).count == 1, "reciprocal-history-presence-must-agree")
        retainedInHistory = retained[0]
        if phase == .C { try Self.require(document["chatWorkflowComplete"] as? Bool == true, "C-chat-workflow-must-complete-before-phase-completion") }
        try verifyProvenanceUnchanged()
        try privateSnapshot("final-reciprocal-profiles.json", profiles())
        try event("phase-complete", ["bothNONE": true, "preexistingHistoryUnchanged": true, "ownedEdgeInHistory": retainedInHistory])
    }

    private func nestedID(_ row: [String: Any], _ role: String) -> String {
        stringID(((row[role] as? [String: Any])?["user"] as? [String: Any])?["id"])
    }
    func ownedChatRows(_ role: String) throws -> [[String: Any]] {
        var owned: [[String: Any]] = [], seen = Set<Int>()
        for page in 1...20 {
            let response = try get("users/chats?page=\(page)&perPage=10", token: account(role).token)
            try Self.require(response.status == 200, "owned-chat-list-read-not200")
            guard let rows = response.body["result"] as? [[String: Any]] else { throw Stopped.invariant("chat-list-array-required") }
            if rows.isEmpty { try Self.require(owned.count <= 1, "ambiguous-owned-pair-conversations-refused"); return owned }
            for row in rows {
                guard let id = row["id"] as? Int, seen.insert(id).inserted else { throw Stopped.invariant("duplicate-chat-page-refused") }
                let own = nestedID(row, role), peerID = nestedID(row, role == "client" ? "caregiver" : "client")
                if peerID == peer(role).id && (own.isEmpty || own == account(role).id) { owned.append(row) }
            }
        }
        throw Stopped.invariant("finite-chat-page-bound-exceeded")
    }
    func ownedChat(_ role: String) throws -> [String: Any] {
        guard phase == .C, let id = chatID else { throw Stopped.invariant("C-bound-chat-required") }
        let row = try read("users/chats/\(id)", token: account(role).token)
        let ownID = nestedID(row, role), otherID = nestedID(row, role == "client" ? "caregiver" : "client")
        try Self.require(row["id"] as? Int == id && otherID == peer(role).id
            && (ownID.isEmpty || ownID == account(role).id), "authenticated-chat-owner-exact-peer-and-bound-id-required")
        return row
    }
    private func immutableMessage(_ row: [String: Any]) throws -> Data {
        guard let id = row["id"] as? Int, let body = row["message"] as? String,
              let sender = row["is_from_caregiver"] as? Bool else { throw Stopped.invariant("message-immutable-fields-required") }
        // Read receipts may legitimately change; preserve identity/text/parent/sender/created time.
        return try JSONSerialization.data(withJSONObject: ["id": id, "message": body, "is_from_caregiver": sender,
            "created_at": row["created_at"] ?? NSNull(), "parent_id": (row["parent"] as? [String: Any])?["id"] ?? NSNull()], options: [.sortedKeys])
    }
    func prepareChatCreate() throws {
        try Self.require(phase == .C && !resumesBoundChat && !chatCreateIntent && chatID == nil, "one-C-chat-create-intent")
        _ = try requirePair("active", edge: edgeID)
        let existing = try ownedChatRows("client")
        baselineChatID = existing.first?["id"] as? Int
        chatCreateIntent = true; document["chatCreateAttempts"] = 1
        try event("native-chat-create-intent", ["role": "client", "attempts": 1, "preexistingOwnedConversation": baselineChatID != nil])
    }
    func bindChatAfterNativeCreate(observedID id: Int) throws -> Int {
        try Self.require(chatCreateIntent && chatID == nil && id > 0, "one-native-create-and-observed-detail-route-before-bind")
        if let baselineChatID { try Self.require(id == baselineChatID, "existing-owned-conversation-must-be-reused") }
        // Empty conversations need not occur in Messages yet. Bind only the actual native detail route,
        // then verify both authenticated perspectives independently before any message is permitted.
        chatID = id; document["chatID"] = id
        let chat = try ownedChat("client"), reciprocal = try ownedChat("caregiver")
        try privateSnapshot("native-created-chat-client-readback.json", chat)
        try privateSnapshot("native-created-chat-caregiver-readback.json", reciprocal)
        guard let peerMessages = reciprocal["messages"] as? [[String: Any]], let clientMessages = chat["messages"] as? [[String: Any]] else { throw Stopped.invariant("both-chat-message-arrays") }
        if continuesExistingC { try Self.require(clientMessages.isEmpty && peerMessages.isEmpty, "inherited-C-unknown-empty-chat-must-remain-empty-before-first-send") }
        let clientImmutable = try clientMessages.map(immutableMessage), peerImmutable = try peerMessages.map(immutableMessage)
        try Self.require(clientImmutable == peerImmutable, "reciprocal-bound-chat-history-must-agree")
        guard let messages = chat["messages"] as? [[String: Any]] else { throw Stopped.invariant("actual-chat-messages-required") }
        for row in messages {
            guard let id = row["id"] as? Int, baselineMessages[id] == nil else { throw Stopped.invariant("unique-baseline-message-ids-required") }
            baselineMessages[id] = try immutableMessage(row)
        }
        try privateSnapshot("chat-baseline.json", chat)
        try event("exact-native-created-chat-bound", ["baselineMessages": messages.count, "observedNativeDetailRoute": true,
            "bothAuthenticatedPeerReadbacks": true, "originalEmptyChatIDUnknown": continuesExistingC])
        return id
    }
    func nativeMessageIntent(role: String, text: String, parent: Int? = nil) throws {
        try Self.require(phase == .C && chatID != nil && text.hasPrefix(marker) && text.count <= 700
            && !nativeMessageIntents.contains(text), "one-unique-marked-native-message-only")
        _ = try requirePair("active", edge: edgeID)
        try verifyMessageHistory(ownedChat(role))
        let clientCount = nativeMessageIntents.filter { $0.contains(" client-seed-") }.count
        if role == "client" {
            try Self.require(clientCount < 8 && parent == nil && text.contains(" client-seed-"), "native-client-seed-cap8-no-replies")
        } else {
            try Self.require(role == "caregiver" && clientCount >= 2
                && !nativeMessageIntents.contains(where: { $0.contains(" caregiver-reply") })
                && parent != nil && messageTexts[parent!] != nil && text.contains(" caregiver-reply"), "one-native-caregiver-bound-reply")
        }
        nativeMessageIntents.append(text); document["nativeMessageAttempts"] = nativeMessageIntents.count
        document["nativeMessageIntentTexts"] = nativeMessageIntents
        try event("native-message-send-intent", ["role": role, "ordinal": nativeMessageIntents.count, "hasParent": parent != nil, "parentID": parent.map { $0 as Any } ?? NSNull()])
    }
    @discardableResult func verifyNativeMessage(role: String, text: String, parent: Int? = nil) throws -> Int {
        let chat = try ownedChat(role)
        guard let rows = chat["messages"] as? [[String: Any]] else { throw Stopped.invariant("chat-message-array-required") }
        let exact = rows.filter { $0["message"] as? String == text }
        try Self.require(exact.count == 1, "one-stored-native-message-no-duplicate-or-replay")
        let row = exact[0]
        guard let id = row["id"] as? Int, let created = row["created_at"] as? String, !created.isEmpty else { throw Stopped.invariant("stored-message-id-and-original-time-required") }
        try Self.require(row["is_from_caregiver"] as? Bool == (role == "caregiver"), "exact-native-message-sender-required")
        let actualParent = (row["parent"] as? [String: Any])?["id"] as? Int
        try Self.require(actualParent == parent, "actual-native-reply-parent-must-match")
        try Self.require(messageTexts[id] == nil, "new-message-id-not-already-bound")
        messageTexts[id] = text; baselineMessages[id] = try immutableMessage(row)
        try verifyMessageHistory(chat)
        try event("native-message-acknowledged", ["role": role, "ordinal": messageTexts.count, "messageID": id, "parentID": parent.map { $0 as Any } ?? NSNull(), "hasParent": parent != nil])
        return id
    }
    /// Explicit proposed peer message seam for single-simulator incoming polling.
    /// No API match staging and no automatic resend after any uncertain response.
    func postOnePeerIncoming(_ ordinal: Int) throws -> (String, String) {
        try Self.require(phase == .C && [1, 2].contains(ordinal) && incomingIntents.count == ordinal - 1
            && nativeMessageIntents.contains(where: { $0.contains(" caregiver-reply") }), "exact-two-finite-peer-incoming-budget")
        _ = try requirePair("active", edge: edgeID)
        let before = try ownedChat("caregiver")
        guard let rows = before["messages"] as? [[String: Any]], let id = chatID else { throw Stopped.invariant("owned-active-chat-before-peer-message") }
        try verifyMessageHistory(before)
        let text = marker + " peer-incoming-\(ordinal)"
        try Self.require(!rows.contains { $0["message"] as? String == text }, "peer-message-must-not-exist-before-intent")
        incomingIntents.append(text); document["peerIncomingAPIAttempts"] = incomingIntents.count
        document["peerIncomingIntentTexts"] = incomingIntents
        try event("single-peer-message-API-intent", ["role": "caregiver", "ordinal": ordinal, "attempts": 1])
        let response = try CarezaarAPI.callWithHTTPStatus("POST", "users/chats/\(id)", form: ["message": text], token: caregiver.token)
        try Self.require(response.status == 200, "peer-message-response-not200-no-resend")
        let chat = CarezaarAPI.result(response.body)
        try Self.require(chat["id"] as? Int == id && nestedID(chat, "client") == client.id
            && (nestedID(chat, "caregiver").isEmpty || nestedID(chat, "caregiver") == caregiver.id), "authenticated-caregiver-peer-message-response-exact-chat")
        guard let after = chat["messages"] as? [[String: Any]] else { throw Stopped.invariant("peer-message-response-array") }
        let added = after.filter { $0["message"] as? String == text }
        guard added.count == 1, let messageID = added[0]["id"] as? Int, let timestamp = added[0]["created_at"] as? String, !timestamp.isEmpty else { throw Stopped.invariant("one-stored-peer-message-with-time-no-resend") }
        try Self.require(added[0]["is_from_caregiver"] as? Bool == true && messageTexts[messageID] == nil, "peer-message-exact-sender-and-new-id")
        messageTexts[messageID] = text; baselineMessages[messageID] = try immutableMessage(added[0]); try verifyMessageHistory(chat)
        try event("peer-incoming-acknowledged", ["ordinal": ordinal, "attempts": 1, "messageID": messageID])
        return (text, timestamp)
    }
    func verifyMessageHistory(_ chat: [String: Any]) throws {
        guard let rows = chat["messages"] as? [[String: Any]] else { throw Stopped.invariant("chat-history-array-required") }
        var actual: [Int: Data] = [:]
        for row in rows {
            guard let id = row["id"] as? Int, actual[id] == nil else { throw Stopped.invariant("unique-chat-history-ids-required") }
            actual[id] = try immutableMessage(row)
        }
        try Self.require(Set(actual.keys) == Set(baselineMessages.keys), "no-unbound-or-deleted-message-allowed")
        for (id, bytes) in baselineMessages { try Self.require(actual[id] == bytes, "immutable-message-history-changed") }
    }
    func chatWorkflowComplete() throws {
        try Self.require(phase == .C && incomingIntents.count == 2
            && nativeMessageIntents.filter { $0.contains(" caregiver-reply") }.count == 1, "finite-C-message-flow-required")
        try verifyMessageHistory(ownedChat("client"))
        document["chatWorkflowComplete"] = true
        try event("chat-workflow-complete", ["nativeSends": nativeMessageIntents.count, "peerAPISends": 2,
            "dedicatedReadAckPOSTPUTPATCH": 0, "GETChatMayUpdateReadReceipts": true])
    }

    func verifyProvenanceUnchanged() throws {
        try Self.require(try Data(contentsOf: client.file) == client.original, "client-provenance-changed")
        try Self.require(try Data(contentsOf: caregiver.file) == caregiver.original, "caregiver-provenance-changed")
    }
    func stringID(_ value: Any?) -> String { value.map { String(describing: $0) } ?? "" }
}
