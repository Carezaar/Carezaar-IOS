import XCTest
import Foundation
import CryptoKit

// BEGIN PURE OWNER START POLICY
private enum NativeOwnerProfileStart: String {
    case transitionFromMatches, revalidateOwnedProfile
    static func decide(foreground: Bool, busy: Bool, interrupted: Bool, uniqueTabs: Bool,
                       matchesSelected: Bool, profileSelected: Bool, messagesSelected: Bool,
                       loadedMatches: Bool, exactVisibleOwnedEmail: Bool) -> Self? {
        guard foreground && !busy && !interrupted && uniqueTabs && !messagesSelected else { return nil }
        if matchesSelected && !profileSelected && loadedMatches { return .transitionFromMatches }
        if profileSelected && !matchesSelected && exactVisibleOwnedEmail { return .revalidateOwnedProfile }
        return nil
    }
}
// END PURE OWNER START POLICY

// BEGIN PURE ALERT ACTION POLICY
private struct NativeAlertActionObservation {
    let identifier: String
    let label: String
    let frame: CGRect
    let isLeaf: Bool
    let enabled: Bool
    let hittable: Bool
}
private enum NativeAlertActionPolicy {
    static func uniqueLeafIndex(_ rows: [NativeAlertActionObservation], identifier: String, label: String,
                                alertFrame: CGRect, appFrame: CGRect) -> Int? {
        guard let physicalFrame = rows.first?.frame, !physicalFrame.isNull, !physicalFrame.isInfinite,
              physicalFrame.minX.isFinite, physicalFrame.minY.isFinite, physicalFrame.width.isFinite, physicalFrame.height.isFinite,
              physicalFrame.width > 0, physicalFrame.height > 0,
              appFrame.contains(physicalFrame), alertFrame.contains(physicalFrame),
              rows.allSatisfy({ $0.identifier == identifier && $0.label == label && $0.frame == physicalFrame }) else { return nil }
        let leaves = rows.indices.filter { rows[$0].isLeaf }
        guard leaves.count == 1, let index = leaves.first, rows[index].enabled, rows[index].hittable else { return nil }
        return index
    }
}
// END PURE ALERT ACTION POLICY

// BEGIN PURE HISTORY PHYSICAL ROW POLICY
private enum NativeHistoryPhysicalRows {
    static func distinct(_ frames: [CGRect], expected: Int) -> Bool {
        guard (1...10).contains(expected), frames.count == expected else { return false }
        return frames.allSatisfy { !$0.isNull && !$0.isInfinite && $0.minX.isFinite && $0.minY.isFinite
            && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }
            && frames.enumerated().allSatisfy { index, frame in !frames.prefix(index).contains(frame) }
    }
}
// END PURE HISTORY PHYSICAL ROW POLICY

/// PROPOSED finite owned A/B/C/D-full/D-blank/E suite. No graph API staging or automatic cleanup.
final class NativeOwnedGraphPhasesUITests: XCTestCase {
    private typealias Guard = NativeOwnedGraphPhaseJournal
    private var app: XCUIApplication!
    private var journal: NativeOwnedGraphPhaseJournal?
    private var labels: [String: String] = [:]
    private var activeRole = ""
    private var expectedWrites: [String: Int] = [:]
    private var verifyBackOnFirstLogin = false
    private var backVerified = false
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() {
        if let journal, (testRun?.failureCount ?? 1) > 0 { try? journal.event("test-stopped-no-automatic-cleanup") }
        app?.terminate(); super.tearDown()
    }
    func testReadOnlyEndedENativeHistoryAndBothFinalStates() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_GRAPH_E_TERMINAL_READONLY"] == "1", env["QA_NATIVE_GRAPH_PHASE"] == "E" else {
            throw XCTSkip("Exact reviewed ended-E read-only completion required")
        }
        let j = try Guard(environment: env); journal = j; scopedSmallGETs = true
        for role in ["client", "caregiver"] { try j.officialProof(role) }
        _ = try j.requirePair("none")
        let response = try scopedSmallDirectGET("base/contents?ts_cache=0")
        try Guard.require(response.status == 200, "public-managed-English-copy-required")
        guard let rows = response.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("managed-copy-array-required") }
        for row in rows {
            if let slug = row["slug"] as? String, let translations = row["translations"] as? [[String: Any]],
               let value = translations.first(where: { ($0["language_id"] as? NSNumber)?.intValue == 1 })?["name"] as? String, !value.isEmpty { labels[slug] = value }
        }
        activeRole = "caregiver"
        try ordinaryMain(j); try openExactPeerFromActualMatches(j); try profileState("none", j: j)
        try assertCurrentNoneAndHistory(j)
        try signIn("client", journal: j)
        try openExactPeerFromActualMatches(j); try profileState("none", j: j)
        try assertCurrentNoneAndHistory(j)
        try recordProcessIfRunning(); try j.verifyEndedReadOnlyCompletion()
        let proof = XCTAttachment(string: "terminalEReadOnly=true;newGraphWrites=0;newChatCreates=0;newMessages=0;bothNativeNONE=true;bothNativeHistory=true;allSameLabelPhysicalRowsInspected=true;historicalFailurePreserved=true")
        proof.name = "ended-E-readonly-anonymous-completion"; proof.lifetime = .keepAlways; add(proof)
    }
    func testReadOnlyEndedCNativeHistoryAndClosedChatBothRoles() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_GRAPH_C_TERMINAL_READONLY"] == "1", env["QA_NATIVE_GRAPH_PHASE"] == "C" else {
            throw XCTSkip("Exact reviewed ended-C read-only completion required")
        }
        let j = try Guard(environment: env); journal = j; scopedSmallGETs = true
        for role in ["client", "caregiver"] { try j.officialProof(role) }
        try j.adoptEndedCForReadOnlyCompletion(environment: env)
        let response = try scopedSmallDirectGET("base/contents?ts_cache=0")
        try Guard.require(response.status == 200, "public-managed-English-copy-required")
        guard let rows = response.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("managed-copy-array-required") }
        for row in rows {
            if let slug = row["slug"] as? String, let translations = row["translations"] as? [[String: Any]],
               let value = translations.first(where: { ($0["language_id"] as? NSNumber)?.intValue == 1 })?["name"] as? String, !value.isEmpty { labels[slug] = value }
        }
        activeRole = "client"
        try ordinaryMain(j); try openExactPeerFromActualMatches(j); try profileState("none", j: j)
        try assertCurrentNoneAndHistory(j)
        try ordinaryMain(j); try closedOwnedConversation(j)
        try signIn("caregiver", journal: j)
        try openExactPeerFromActualMatches(j); try profileState("none", j: j)
        try assertCurrentNoneAndHistory(j)
        try ordinaryMain(j); try closedOwnedConversation(j)
        try recordProcessIfRunning(); try j.verifyEndedReadOnlyCompletion()
        let proof = XCTAttachment(string: "terminalCReadOnly=true;newGraphWrites=0;newChatCreates=0;newMessages=0;bothNativeNONE=true;bothNativeHistory=true;bothClosedChats=true;historicalFailuresPreserved=true")
        proof.name = "ended-C-readonly-anonymous-completion"; proof.lifetime = .keepAlways; add(proof)
    }
    func testResumeBoundExistingCChatAndClientUnmatch() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_GRAPH_C_CONTINUE_EXISTING"] == "1", env["QA_NATIVE_GRAPH_PHASE"] == "C",
              env["QA_NATIVE_GRAPH_REMAINING_CORE_REQUESTS"] == "1" else { throw XCTSkip("Exact reviewed existing-C continuation required") }
        let j = try Guard(environment: env); journal = j
        try Guard.require(j.continuesExistingC && !j.continuesExistingA, "existing-active-C-no-new-request")
        scopedSmallGETs = true
        for role in ["client", "caregiver"] { try j.officialProof(role) }
        try j.verifyInheritedActiveCAndHistory()
        try j.adoptExactBoundChatFromStoppedContinuation(environment: env)
        let response = try scopedSmallDirectGET("base/contents?ts_cache=0")
        try Guard.require(response.status == 200, "public-managed-English-copy-required")
        guard let rows = response.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("managed-copy-array-required") }
        for row in rows {
            if let slug = row["slug"] as? String, let translations = row["translations"] as? [[String: Any]],
               let value = translations.first(where: { ($0["language_id"] as? NSNumber)?.intValue == 1 })?["name"] as? String, !value.isEmpty { labels[slug] = value }
        }
        activeRole = "client"
        // Already saved client session only: no initial local clear, hidden login or request/Accept path.
        try ordinaryMain(j); try openExactPeerFromActualMatches(j); try profileState("active", j: j)
        try chatDeliveryReplyViewportAndClientUnmatch(j)
        try recordProcessIfRunning(); try j.verifyHistoryAndCompletion()
        let proof = XCTAttachment(string: "existingC=true;newRequest=0;newAccept=0;newChatCreate=0;knownBoundChat=true;originalEmptyChatIDUnknown=true;bothFinalNONE=true;originalHistoryPreserved=true")
        proof.name = "bound-existing-C-continuation-anonymous-completion"; proof.lifetime = .keepAlways; add(proof)
    }
    func testContinueExistingActiveCChatAndClientUnmatch() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_GRAPH_C_CONTINUE_EXISTING"] == "1", env["QA_NATIVE_GRAPH_PHASE"] == "C",
              env["QA_NATIVE_GRAPH_REMAINING_CORE_REQUESTS"] == "1" else { throw XCTSkip("Exact reviewed existing-C continuation required") }
        let j = try Guard(environment: env); journal = j
        try Guard.require(j.continuesExistingC && !j.continuesExistingA, "existing-active-C-no-new-request")
        scopedSmallGETs = true
        for role in ["client", "caregiver"] { try j.officialProof(role) }
        try j.verifyInheritedActiveCAndHistory()
        let response = try scopedSmallDirectGET("base/contents?ts_cache=0")
        try Guard.require(response.status == 200, "public-managed-English-copy-required")
        guard let rows = response.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("managed-copy-array-required") }
        for row in rows {
            if let slug = row["slug"] as? String, let translations = row["translations"] as? [[String: Any]],
               let value = translations.first(where: { ($0["language_id"] as? NSNumber)?.intValue == 1 })?["name"] as? String, !value.isEmpty { labels[slug] = value }
        }
        activeRole = "client"
        // Already saved client session only: no initial local clear, hidden login or request/Accept path.
        try ordinaryMain(j); try openExactPeerFromActualMatches(j); try profileState("active", j: j)
        try chatDeliveryReplyViewportAndClientUnmatch(j)
        try recordProcessIfRunning(); try j.verifyHistoryAndCompletion()
        let proof = XCTAttachment(string: "existingC=true;newRequest=0;newAccept=0;deliberateMessageReentry=1;originalEmptyChatIDUnknown=true;bothFinalNONE=true;originalHistoryPreserved=true")
        proof.name = "existing-C-continuation-anonymous-completion"; proof.lifetime = .keepAlways; add(proof)
    }
    func testCaregiverRequestClientRejectFullIntroduction() throws { try run(.A) }
    func testCaregiverRequestCaregiverCancelFullIntroduction() throws { try run(.B) }
    func testCaregiverRequestClientAcceptChatAndClientUnmatch() throws { try run(.C) }
    func testClientRequestCaregiverRejectFullIntroduction() throws { try run(.D) }
    func testClientBlankRequestCaregiverRejectWithoutIntroduction() throws { try run(.Dblank) }
    func testClientRequestCaregiverAcceptAndCaregiverUnmatch() throws { try run(.E) }
    func testContinueExactCaregiverRequestClientRejectAndBothFinalStates() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_GRAPH_PHASE_BATCH"] == "1", env["QA_NATIVE_GRAPH_A_CONTINUE_EXISTING"] == "1", env["QA_NATIVE_GRAPH_PHASE"] == "A" else {
            throw XCTSkip("Exact primary-reviewed already-created A continuation required")
        }
        let j = try Guard(environment: env); journal = j
        try Guard.require(j.continuesExistingA, "no-fresh-request-mode-in-continuation")
        for role in ["client", "caregiver"] { try j.officialProof(role) }
        try j.verifyInheritedPendingAndHistory()
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0")
        try Guard.require(response.status == 200, "public-managed-English-copy-required")
        guard let rows = response.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("managed-copy-array-required") }
        for row in rows {
            guard let slug = row["slug"] as? String, let translations = row["translations"] as? [[String: Any]],
                  let value = translations.first(where: { ($0["language_id"] as? NSNumber)?.intValue == 1 })?["name"] as? String, !value.isEmpty else { continue }
            labels[slug] = value
        }
        // Use the existing saved CG session. No local clear, credentials, proof shortcut or fallback login.
        activeRole = "caregiver"; try ordinaryMain(j)
        try openExactPeerFromActualMatches(j); try profileState("sent", j: j)
        try inspectPendingIntroduction(j, edge: try XCTUnwrap(j.edgeID), outgoing: true)
        try signIn("client", journal: j)
        try openExactPeerFromActualMatches(j); try profileState("received", j: j)
        try inspectPendingIntroduction(j, edge: try XCTUnwrap(j.edgeID), outgoing: false)
        try ordinaryMain(j); try openExactPeerFromActualMatches(j); try profileState("received", j: j)
        try confirmMutation("reject", j: j); try assertCurrentNoneAndHistory(j)
        try signIn("caregiver", journal: j)
        try openExactPeerFromActualMatches(j); try profileState("none", j: j)
        try assertCurrentNoneAndHistory(j); try recordProcessIfRunning(); try j.verifyHistoryAndCompletion()
        let proof = XCTAttachment(string: "existingAOnly=true;newRequestAttempts=0;inheritedRequestAttempts=1;rejectAttempts=1;nativeLoginOrder=client,caregiver;bothFinalNONE=true;historyPreserved=true;automaticRetryOrCleanup=false")
        proof.name = "exact-existing-A-continuation-anonymous"; proof.lifetime = .keepAlways; add(proof)
    }
    /// Separate scoped proof: incoming client introduction/Reject and both native peer profiles NONE.
    /// Does not certify the unchanged full-A outgoing caregiver preview or either History UI.
    func testScopedExistingClientRejectAndBothRolesNativeNone() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_GRAPH_PHASE_BATCH"] == "1", env["QA_NATIVE_GRAPH_A_CONTINUE_EXISTING"] == "1",
              env["QA_NATIVE_GRAPH_PHASE"] == "A", env["QA_NATIVE_GRAPH_SCOPED_CLIENT_REJECT"] == "1" else {
            throw XCTSkip("Exact primary-reviewed scoped client Reject/both native NONE control required")
        }
        let j = try Guard(environment: env); journal = j
        try Guard.require(j.continuesExistingA, "scoped-Reject-has-no-new-request-path")
        for role in ["client", "caregiver"] { try j.officialProof(role) }
        try j.verifyInheritedPendingAndHistory()
        let edge = try XCTUnwrap(j.edgeID)
        let response = try CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0")
        try Guard.require(response.status == 200, "public-managed-English-copy-required")
        guard let rows = response.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("managed-copy-array-required") }
        for row in rows {
            guard let slug = row["slug"] as? String, let translations = row["translations"] as? [[String: Any]],
                  let value = translations.first(where: { ($0["language_id"] as? NSNumber)?.intValue == 1 })?["name"] as? String,
                  !value.isEmpty else { continue }
            labels[slug] = value
        }
        // Exactly two actual owned UI logins; no dependency on the outgoing caregiver list.
        try signIn("client", journal: j)
        try openExactPeerFromActualMatches(j); try profileState("received", j: j)
        try inspectPendingIntroduction(j, edge: edge, outgoing: false)
        try ordinaryMain(j); try openExactPeerFromActualMatches(j); try profileState("received", j: j)
        // Existing helper: full managed body/intro, dismiss with zero DELETE, reopen, exactly one bound Reject.
        try confirmMutation("reject", j: j)
        try profileState("none", j: j)
        try j.event("scoped-client-Reject-native-peer-NONE", ["role": "client", "nativeProfileNONE": true])
        try signIn("caregiver", journal: j)
        try openExactPeerFromActualMatches(j); try profileState("none", j: j)
        try j.event("scoped-client-Reject-native-peer-NONE", ["role": "caregiver", "nativeProfileNONE": true])
        try recordProcessIfRunning()
        // Independent exact reciprocal API NONE plus preserved normalized original histories;
        // the exact new edge may be absent or the sole additional reciprocal history row.
        try j.verifyHistoryAndCompletion()
        try j.event("scoped-client-Reject-both-native-NONE-complete", ["newRequestAttempts": 0,
            "rejectAttempts": 1, "bothNativeProfileNONE": true, "fullAPassClaim": false,
            "outgoingCaregiverPreviewVerified": false, "historyUIVerified": false])
        let proof = XCTAttachment(string: "scope=scopedClientRejectAndBothNativeNONE;newRequestAttempts=0;inheritedRequestAttempts=1;rejectAttempts=1;nativeLoginOrder=client,caregiver;bothNativeProfileNONE=true;bothExactAPINONE=true;originalHistoryPreserved=true;outgoingCaregiverPreviewVerified=false;historyUIVerified=false;fullAPassClaim=false;automaticRetryOrCleanup=false")
        proof.name = "scoped-client-Reject-both-native-NONE-anonymous"; proof.lifetime = .keepAlways; add(proof)
    }
    /// New Small allocation only; preserves full-A outgoing/History requirements in the old tests.
    func testScopedSmallCaregiverRequestClientRejectAndBothNativeNone() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_GRAPH_PHASE_BATCH"] == "1", env["QA_NATIVE_GRAPH_PHASE"] == "A",
              env["QA_NATIVE_GRAPH_SCOPED_SMALL_NEW_CG_CLIENT_REJECT"] == "1" else {
            throw XCTSkip("Exact reviewed Small fresh CG request/client Reject control required")
        }
        let j = try Guard(environment: env); journal = j
        try Guard.require(!j.continuesExistingA, "fresh-Small-scope-must-not-replay-an-inherited-edge")
        scopedSmallGETs = true
        for role in ["client", "caregiver"] { try j.officialProof(role) }
        _ = try j.requirePair("none"); try j.snapshotHistory()
        try verifySmallPriorHistoryCheckpoint(j, environment: env)
        let response = try scopedSmallDirectGET("base/contents?ts_cache=0")
        try Guard.require(response.status == 200, "public-managed-English-copy-required")
        guard let rows = response.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("managed-copy-array-required") }
        for row in rows {
            guard let slug = row["slug"] as? String, let translations = row["translations"] as? [[String: Any]],
                  let value = translations.first(where: { ($0["language_id"] as? NSNumber)?.intValue == 1 })?["name"] as? String,
                  !value.isEmpty else { continue }
            labels[slug] = value
        }
        for role in ["client", "caregiver"] { try firstPagePeer(role, j: j) }
        try signIn("caregiver", journal: j)
        try openExactPeerFromActualMatches(j); try profileState("none", j: j)
        try requestForm(j, submit: false); _ = try j.requirePair("none"); try writes(expectedWrites)
        try requestForm(j, submit: true)
        let edge = try j.bindCreatedPendingEdge()
        try wait("native-requester-must-show-SENT") { self.app.buttons["match-withdraw"].exists }
        try profileState("sent", j: j)
        // This new canonical allocation does not claim the separate outgoing caregiver Manage preview.
        try signIn("client", journal: j)
        try openExactPeerFromActualMatches(j); try profileState("received", j: j)
        try inspectPendingIntroduction(j, edge: edge, outgoing: false)
        try ordinaryMain(j); try openExactPeerFromActualMatches(j); try profileState("received", j: j)
        try confirmMutation("reject", j: j); try profileState("none", j: j)
        try j.event("small-scoped-native-peer-NONE", ["role": "client", "nativeProfileNONE": true])
        try signIn("caregiver", journal: j)
        try openExactPeerFromActualMatches(j); try profileState("none", j: j)
        try j.event("small-scoped-native-peer-NONE", ["role": "caregiver", "nativeProfileNONE": true])
        try recordProcessIfRunning(); try j.verifyHistoryAndCompletion()
        try Guard.require(scopedSmallDirectGETAttempts == 7 && processIndex == 5, "exact-derived-direct-GET-and-launch-contract")
        try j.event("small-scoped-CG-request-client-Reject-both-native-NONE-complete", ["newRequestAttempts": 1,
            "rejectAttempts": 1, "bothNativeProfileNONE": true, "fullAPassClaim": false,
            "outgoingCaregiverPreviewVerified": false, "historyUIVerified": false,
            "directGETAttempts": scopedSmallDirectGETAttempts, "appProcesses": processIndex])
        let proof = XCTAttachment(string: "scope=SmallCGRequestClientRejectBothNativeNONE;request=1;Reject=1;UI=caregiver,client,caregiver;officialPerRole=1;outgoingCGPreview=false;historyUI=false;fullAPassClaim=false")
        proof.name = "small-scoped-CG-request-client-Reject-anonymous"; proof.lifetime = .keepAlways; add(proof)
    }
    private var remainingCoreGETs: Bool { ProcessInfo.processInfo.environment["QA_NATIVE_GRAPH_REMAINING_CORE_REQUESTS"] == "1" }
    private var remainingDirectGETCap: Int { journal?.phase == .C ? 13 : journal?.phase == .Dblank ? 9 : 10 }
    private var fullDRequestsGETs: Bool { ProcessInfo.processInfo.environment["QA_NATIVE_GRAPH_FULL_D_REQUESTS"] == "1" }
    private var scopedProcessCount: Int { remainingCoreGETs ? 26 : fullDRequestsGETs ? 10 : 5 }
    private var scopedDirectGETCap: Int { remainingCoreGETs ? remainingDirectGETCap : fullDRequestsGETs ? 9 : 7 }
    private var scopedNativeGETCap: Int { remainingCoreGETs ? 2400 : fullDRequestsGETs ? 404 : 249 }
    private var scopedSmallGETs = false
    private var scopedSmallDirectGETAttempts = 0
    private var scopedSmallProcessBegan: TimeInterval = 0
    private var scopedSmallRecordedGETs = 0
    // Five source-derived process shapes: CG login, client login, incoming-list relaunch,
    // client Reject relaunch, CG final login. Pager may fetch one exhaustion page per mount.
    private var scopedSmallMatchesCaps: [Int] { fullDRequestsGETs ? [4, 2, 4, 2, 4, 4, 2, 4, 4, 2] : [4, 4, 2, 4, 4] }
    private var scopedSmallPeerCaps: [Int] { fullDRequestsGETs ? [3, 0, 1, 0, 3, 1, 0, 1, 1, 0] : [3, 1, 0, 3, 1] }
    private var scopedSmallManagedCaps: [Int] { fullDRequestsGETs ? [0, 3, 0, 3, 0, 0, 3, 0, 0, 3] : [0, 0, 3, 0, 0] }
    private func scopedSmallDirectGET(_ path: String, token: String? = nil) throws -> (status: Int, body: [String: Any]) {
        try Guard.require(scopedSmallGETs && scopedSmallDirectGETAttempts < scopedDirectGETCap, "Small-direct-GET-cap7-no-extra-calls")
        let allowed = ["base/contents?ts_cache=0", "clients/matches?page=1&perPage=10&sort=distance",
                       "caregivers/matches?page=1&perPage=10&sort=distance"]
        try Guard.require(allowed.contains(path), "Small-direct-GET-exact-route-required")
        scopedSmallDirectGETAttempts += 1
        try journal?.event("small-scoped-direct-GET-intent", ["ordinal": scopedSmallDirectGETAttempts,
            "kind": path.hasPrefix("base/") ? "public-managed-copy" : "owned-first-page"])
        return try CarezaarAPI.callWithHTTPStatus("GET", path, token: token)
    }
    private func verifySmallPriorHistoryCheckpoint(_ j: Guard, environment: [String: String]) throws {
        guard let rawFiles = environment["QA_NATIVE_GRAPH_SMALL_BASELINE_FILES"], let fileData = rawFiles.data(using: .utf8),
              let files = try JSONSerialization.jsonObject(with: fileData) as? [String: String],
              let rawHashes = environment["QA_NATIVE_GRAPH_SMALL_BASELINE_SHA256"], let hashData = rawHashes.data(using: .utf8),
              let hashes = try JSONSerialization.jsonObject(with: hashData) as? [String: String] else {
            throw Guard.Stopped.invariant("frozen-current-r3-history-checkpoint-required")
        }
        for role in ["client", "caregiver"] {
            guard let path = files[role], let expectedHash = hashes[role] else { throw Guard.Stopped.invariant("both-frozen-history-roles-required") }
            let prior = try Data(contentsOf: URL(fileURLWithPath: path))
            let digest = SHA256.hash(data: prior).map { String(format: "%02x", $0) }.joined()
            try Guard.require(digest == expectedHash, "exact-prior-history-file-SHA-required")
            guard let previous = try JSONSerialization.jsonObject(with: prior) as? [String: String],
                  let current = try JSONSerialization.jsonObject(with: Data(contentsOf: j.directory.appendingPathComponent("before-\(role)-history.json"))) as? [String: String] else {
                throw Guard.Stopped.invariant("normalized-before-history-map-required")
            }
            try Guard.require(current == previous, "fresh-before-history-must-equal-accepted-r3-checkpoint")
        }
        try j.event("small-scoped-prior-history-checkpoint-verified", ["bothRoles": true])
    }
    private func remainingCoreNativeGETBudget() throws -> [String: Any] {
        try Guard.require((1...26).contains(processIndex) && scopedSmallProcessBegan > 0, "remaining-core-finite26-process-bound")
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - scopedSmallProcessBegan)
        try Guard.require(elapsed <= 2700, "remaining-core45minute-process-window")
        let ticks = Int(elapsed / 30), chatTicks = Int(elapsed / 10)
        var limits = Dictionary(uniqueKeysWithValues: ["info", "careconditions", "caredays", "carespecials", "certifications", "clienttypes", "commutes", "contents", "countries", "experiences", "genders", "issuetypes", "languageskills", "reasons", "roles", "shifts", "subjects", "worktypes", "languages", "states", "media", "faqs", "faq_categories"].map { ("GET /api/base/" + $0, 1) })
        limits["GET /api/auth/info"] = 2
        limits["GET /api/" + (activeRole == "client" ? "clients/matches" : "caregivers/matches")] = 4
        limits["GET /api/" + journal!.profilePath(activeRole)] = 3
        limits["GET /api/users/matches"] = 3
        limits["GET /api/users/chats"] = 4 + chatTicks
        limits["GET /api/users/notifications/count"] = 1 + ticks
        if let edge = journal?.edgeID { limits["GET /api/users/matches/\(edge)"] = 10 }
        if let chat = journal?.chatID { limits["GET /api/users/chats/\(chat)"] = 5 + chatTicks }
        var counts: [String: Int] = [:]
        for line in app.staticTexts["qa-request-counts"].label.split(separator: "\n").map(String.init) where line.hasPrefix("GET ") {
            guard let separator = line.lastIndex(of: "="), let value = Int(line[line.index(after: separator)...]), value >= 0 else { throw Guard.Stopped.invariant("remaining-core-GET-ledger-invalid") }
            let route = String(line[..<separator])
            try Guard.require(limits[route].map { value <= $0 } == true, "remaining-core-owned-GET-route-or-stop-limit-exceeded")
            counts[route] = value
        }
        try Guard.require(scopedSmallRecordedGETs + counts.values.reduce(0, +) <= 2400, "remaining-core-native-GET2400-stop-limit")
        return ["process": processIndex, "elapsedSeconds": elapsed, "notificationIntervalSeconds": 30,
                "notificationTicksAllowance": ticks, "chatPollIntervalSeconds": 10, "chatPollTicksAllowance": chatTicks,
                "GETCount": counts.values.reduce(0, +), "GETCap": limits.values.reduce(0, +), "derivedLimits": limits]
    }
    private func scopedSmallNativeGETBudget() throws -> [String: Any] {
        if remainingCoreGETs { return try remainingCoreNativeGETBudget() }
        try Guard.require((1...scopedProcessCount).contains(processIndex) && scopedSmallProcessBegan > 0, "Small-five-process-callgraph-required")
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - scopedSmallProcessBegan)
        let ticks = Int(elapsed / 30)
        let roleMatches = activeRole == "client" ? "clients/matches" : "caregivers/matches"
        let base = ["info", "careconditions", "caredays", "carespecials", "certifications", "clienttypes", "commutes",
                    "contents", "countries", "experiences", "genders", "issuetypes", "languageskills", "reasons", "roles",
                    "shifts", "subjects", "worktypes", "languages", "states", "media", "faqs", "faq_categories"]
        var limits = Dictionary(uniqueKeysWithValues: base.map { ("GET /api/base/" + $0, 1) })
        limits["GET /api/auth/info"] = 2
        limits["GET /api/" + roleMatches] = scopedSmallMatchesCaps[processIndex - 1]
        limits["GET /api/" + journal!.profilePath(activeRole)] = scopedSmallPeerCaps[processIndex - 1]
        limits["GET /api/users/matches"] = scopedSmallManagedCaps[processIndex - 1]
        limits["GET /api/users/notifications/count"] = 1 + ticks
        var counts: [String: Int] = [:]
        for line in app.staticTexts["qa-request-counts"].label.split(separator: "\n").map(String.init) where line.hasPrefix("GET ") {
            guard let separator = line.lastIndex(of: "="), let value = Int(line[line.index(after: separator)...]), value >= 0 else {
                throw Guard.Stopped.invariant("Small-native-GET-ledger-entry-invalid")
            }
            let route = String(line[..<separator])
            try Guard.require(limits[route].map { value <= $0 } == true, "Small-native-GET-route-or-derived-count-exceeded")
            counts[route] = value
        }
        try Guard.require(scopedSmallRecordedGETs + counts.values.reduce(0, +) <= scopedNativeGETCap, "finite-total-native-GET-cap-for-reviewed45minute-window")
        return ["process": processIndex, "elapsedSeconds": elapsed, "notificationIntervalSeconds": 30,
                "notificationTicksAllowance": ticks, "GETCount": counts.values.reduce(0, +),
                "GETCap": limits.values.reduce(0, +), "derivedLimits": limits]
    }
    private func run(_ phase: Guard.Phase) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["QA_NATIVE_GRAPH_PHASE_BATCH"] == "1", env["QA_NATIVE_GRAPH_PHASE"] == phase.rawValue else {
            throw XCTSkip("Exact reviewed phase/allocation control required")
        }
        let j = try Guard(environment: env); journal = j
        if remainingCoreGETs {
            try Guard.require([Guard.Phase.B, .C, .E, .Dblank].contains(phase) && !j.continuesExistingA, "remaining-core-four-phases-only")
            scopedSmallGETs = true
        }
        if fullDRequestsGETs {
            try Guard.require(phase == .D && !j.continuesExistingA, "only-fresh-full-D-Requests-contract")
            scopedSmallGETs = true
        }
        verifyBackOnFirstLogin = env["QA_NATIVE_GRAPH_VERIFY_BACK"] == "1"
        try Guard.require(verifyBackOnFirstLogin == (phase == .A), "Back-proof-on-first-required-login-per-size")
        for role in ["client", "caregiver"] { try j.officialProof(role) }
        _ = try j.requirePair("none"); try j.snapshotHistory()
        if fullDRequestsGETs || remainingCoreGETs { try verifySmallPriorHistoryCheckpoint(j, environment: env) }
        let response = try (fullDRequestsGETs || remainingCoreGETs) ? scopedSmallDirectGET("base/contents?ts_cache=0")
            : CarezaarAPI.callWithHTTPStatus("GET", "base/contents?ts_cache=0")
        try Guard.require(response.status == 200, "public-managed-English-copy-required")
        guard let rows = response.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("managed-copy-array-required") }
        for row in rows {
            guard let slug = row["slug"] as? String, let translations = row["translations"] as? [[String: Any]],
                  let value = translations.first(where: { ($0["language_id"] as? NSNumber)?.intValue == 1 })?["name"] as? String,
                  !value.isEmpty else { continue }
            labels[slug] = value
        }
        // Both actual first pages are checked before creating an edge. No hidden profile route substitutes.
        for role in ["client", "caregiver"] { try firstPagePeer(role, j: j) }
        try signIn(phase.requester, journal: j)
        try openExactPeerFromActualMatches(j); try profileState("none", j: j)
        try requestForm(j, submit: false)
        _ = try j.requirePair("none"); try writes(expectedWrites)
        try requestForm(j, submit: true)
        let edge = try j.bindCreatedPendingEdge()
        // Necessary canonical request already exists; no diagnostic-only creation or extra login.
        try j.captureBothPendingRequestsWitness(edge)
        try wait("native-requester-must-show-SENT") { self.app.buttons["match-withdraw"].exists }
        try profileState("sent", j: j)
        try inspectPendingIntroduction(j, edge: edge, outgoing: true)
        try signIn(phase.recipient, journal: j)
        try openExactPeerFromActualMatches(j); try profileState("received", j: j)
        try inspectPendingIntroduction(j, edge: edge, outgoing: false)
        // Manage intro closes to Manage Matches. Return to Main through an ordinary saved-state launch.
        try ordinaryMain(j); try openExactPeerFromActualMatches(j); try profileState("received", j: j)
        if phase == .B {
            try signIn(phase.requester, journal: j)
            try openExactPeerFromActualMatches(j); try profileState("sent", j: j)
            try confirmMutation("withdraw", j: j)
            try assertCurrentNoneAndHistory(j)
            try signIn(phase.recipient, journal: j)
            try openExactPeerFromActualMatches(j); try profileState("none", j: j)
            try assertCurrentNoneAndHistory(j)
        } else if phase == .A || phase == .D || phase == .Dblank {
            try confirmMutation("reject", j: j)
            try assertCurrentNoneAndHistory(j)
            try signIn(phase.requester, journal: j)
            try openExactPeerFromActualMatches(j); try profileState("none", j: j)
            try assertCurrentNoneAndHistory(j)
        } else {
            try confirmMutation("accept", j: j)
            try matchedScreenThenOrdinaryMain(j)
            try openExactPeerFromActualMatches(j); try profileState("active", j: j)
            if phase == .C { try chatDeliveryReplyViewportAndClientUnmatch(j) }
            else {
                try confirmMutation("unmatch", j: j)
                try assertCurrentNoneAndHistory(j)
                try signIn(phase.requester, journal: j)
                try openExactPeerFromActualMatches(j); try profileState("none", j: j)
                try assertCurrentNoneAndHistory(j)
            }
        }
        try recordProcessIfRunning()
        try j.verifyHistoryAndCompletion()
        if fullDRequestsGETs {
            try Guard.require(scopedSmallDirectGETAttempts == 9 && processIndex == 10, "full-D-exact-direct9-ten-processes-required")
            try j.event("full-D-Requests-caregiver-Reject-both-NONE-history-complete", ["directGETAttempts": 9,
                "appProcesses": 10, "newRequestAttempts": 1, "rejectAttempts": 1,
                "outgoingRequestsVerified": true, "incomingRequestsVerified": true, "bothNativeNONE": true,
                "historyUIBothRoles": true])
        }
        try Guard.require(!verifyBackOnFirstLogin || backVerified, "actual-Back-proof-required")
        let proof = XCTAttachment(string: "scenario=\(phase.rawValue);bothFinalNONE=true;exactCreatedEdgeBound=true;previousHistoryUnchanged=true;noAutomaticRetryOrCleanup=true;BackProof=\(backVerified)")
        proof.name = "owned-phase-anonymous-completion"; proof.lifetime = .keepAlways; add(proof)
    }
    private func text(_ key: String, _ fallback: String) -> String {
        guard let value = labels[key], !value.isEmpty else { return fallback }; return value
    }
    private func wait(_ code: String, timeout: TimeInterval = 40, _ condition: @escaping () -> Bool) throws {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        try Guard.require(XCTWaiter.wait(for: [e], timeout: timeout) == .completed, code)
    }
    private func ready(_ element: XCUIElement, timeout: TimeInterval = 30) throws {
        try wait("required-native-control-not-ready", timeout: timeout) {
            element.exists && element.isEnabled && element.isHittable && self.app.frame.intersects(element.frame)
                && !self.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch.exists
        }
    }
    private func count(_ path: String) -> Int {
        let prefix = path + "="
        return app.staticTexts["qa-request-counts"].label.split(separator: "\n").first { $0.hasPrefix(prefix) }
            .flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
    }
    private func writes(_ expected: [String: Int]) throws {
        try Guard.require(app.staticTexts["qa-request-counts"].exists, "actual-app-ledger-required")
        var result: [String: Int] = [:]
        for line in app.staticTexts["qa-request-counts"].label.split(separator: "\n").map(String.init) {
            guard !line.hasPrefix("GET ") else { continue }
            guard let separator = line.lastIndex(of: "="), let value = Int(line[line.index(after: separator)...]) else {
                throw Guard.Stopped.invariant("unexpected-non-GET-ledger-entry")
            }
            result[String(line[..<separator])] = value
        }
        try Guard.require(result == expected, "unexpected-native-mutation-or-attempt-count")
        if scopedSmallGETs { _ = try scopedSmallNativeGETBudget() }
    }
    private func bottom(_ title: String) throws {
        let buttons = app.buttons.matching(identifier: title)
        var stableSince: Date?
        try wait("bottom-tab-not-reachable", timeout: 40) {
            let candidates = buttons.allElementsBoundByIndex.filter {
                $0.isEnabled && $0.isHittable && self.app.frame.contains($0.frame)
                    && $0.frame.minY > self.app.frame.midY
            }
            guard candidates.count == 1 else { stableSince = nil; return false }
            if stableSince == nil { stableSince = Date() }
            return Date().timeIntervalSince(stableSince!) >= 1.5
        }
        let targets = buttons.allElementsBoundByIndex.filter {
            $0.isEnabled && $0.isHittable && self.app.frame.contains($0.frame)
                && $0.frame.minY > self.app.frame.midY
        }
        try Guard.require(targets.count == 1, "unique-ready-bottom-tab-required")
        try ready(targets[0]); targets[0].tap()
    }
    /// Decline only the positively identified task-triggered iOS password-save
    /// prompt; never save credentials or act on an unrelated system alert.
    private func settlePasswordSavePrompt(_ j: NativeOwnedGraphPhaseJournal? = nil, requireMainReady: Bool = false) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let began = Date()
        let deadline = began.addingTimeInterval(requireMainReady ? 90 : 8)
        var stableMainSince: Date?
        var declined = false
        while Date() < deadline {
            for owner in [app!, springboard] {
                let title = owner.staticTexts["Save Password?"].firstMatch
                let buttons = owner.buttons.matching(identifier: "Not Now")
                if title.exists {
                    try Guard.require(!declined, "one-observed-password-decline-only-no-retry")
                    let sheets = owner.sheets.matching(NSPredicate(format: "label == %@", "Save Password?"))
                    var stableSince: Date?, priorFrame: CGRect?
                    try wait("exact-password-sheet-leaf-must-settle-before-one-decline", timeout: 15) {
                        guard self.app.state == .runningForeground, sheets.count == 1 else { stableSince = nil; return false }
                        let sheet = sheets.firstMatch
                        let choices = sheet.buttons.matching(NSPredicate(format: "label == %@", "Not Now"))
                        guard choices.count == 1 else { stableSince = nil; return false }
                        let target = choices.firstMatch
                        guard target.exists && target.isEnabled && target.isHittable
                            && target.descendants(matching: .button).count == 0
                            && sheet.frame.contains(target.frame) && owner.frame.contains(target.frame)
                            && target.frame.width > 0 && target.frame.height > 0 else { stableSince = nil; return false }
                        if priorFrame != target.frame { priorFrame = target.frame; stableSince = Date() }
                        return stableSince.map { Date().timeIntervalSince($0) >= 1.5 } ?? false
                    }
                    let decline = sheets.firstMatch.buttons.matching(NSPredicate(format: "label == %@", "Not Now")).firstMatch
                    try Guard.require(sheets.count == 1 && decline.label == "Not Now" && decline.isEnabled && decline.isHittable,
                                      "exact-positive-password-sheet-leaf-required")
                    let observed = XCTAttachment(string: owner.debugDescription)
                    observed.name = "private-actual-password-save-AX"; observed.lifetime = .keepAlways; add(observed)
                    try capture("private-actual-password-save-prompt", element: owner)
                    let geometry = XCTAttachment(string: "SheetFrame=\(sheets.firstMatch.frame);declineFrame=\(decline.frame);label=Not Now;uniqueLeaf=true;stableSeconds=1.5;normalPressSeconds=0.1;attempt=1")
                    geometry.name = "exact-password-decline-one-action-geometry"; geometry.lifetime = .keepAlways; add(geometry)
                    try j?.event("native-password-save-decline-intent", ["role": activeRole, "attempt": 1])
                    declined = true
                    decline.press(forDuration: 0.1) // One normal system action; no retry, save, or settings change.
                    try wait("password-save-must-dismiss", timeout: 15) {
                        sheets.count == 0 && !owner.staticTexts.matching(NSPredicate(format: "label == %@", "Save Password?")).firstMatch.exists
                    }
                    try j?.event("native-password-save-declined", ["role": activeRole, "count": 1])
                } else if owner.alerts.count > 0 {
                    let unknown = XCTAttachment(string: owner.debugDescription)
                    unknown.name = "private-unknown-post-signin-alert-stop-AX"; unknown.lifetime = .keepAlways; add(unknown)
                    throw Guard.Stopped.invariant("unknown-post-signin-alert-no-action")
                }
            }
            if requireMainReady {
                let messages = app.buttons[text("bottom_navigation_messages", "Messages")].firstMatch
                let loaded = messages.exists && messages.isEnabled && messages.isHittable
                    && app.frame.contains(messages.frame)
                    && !app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch.exists
                if loaded {
                    if stableMainSince == nil { stableMainSince = Date() }
                    if Date().timeIntervalSince(stableMainSince!) >= 1.5 && Date().timeIntervalSince(began) >= 8 { return }
                } else { stableMainSince = nil }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        try Guard.require(!requireMainReady, "post-signin-Main-not-ready-after-positive-prompt-handling")
    }
    private func owner(_ role: String, _ j: NativeOwnedGraphPhaseJournal) throws {
        let profileTitle = text("bottom_navigation_profile", "Profile")
        let profileTabs = app.buttons.matching(identifier: profileTitle)
        let matchesTabs = app.buttons.matching(identifier: text("bottom_navigation_matches", "Matches"))
        let messagesTabs = app.buttons.matching(identifier: text("bottom_navigation_messages", "Messages"))
        let busy = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@",
            text("loading_please_wait", "Please wait..."))).firstMatch
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let displayed = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value == %@",
            text("profile_edit_email", "Email Address"), j.account(role).email))
        func actualLower(_ query: XCUIElementQuery) -> [XCUIElement] {
            query.allElementsBoundByIndex.filter {
                $0.exists && $0.isEnabled && $0.isHittable && self.app.frame.contains($0.frame)
                    && $0.frame.width > 0 && $0.frame.height > 0 && $0.frame.minY > self.app.frame.midY
            }
        }
        func exactVisibleEmail() -> Bool {
            displayed.count == 1 && displayed.firstMatch.isHittable && app.frame.contains(displayed.firstMatch.frame)
        }
        let totalPrefix = text(role == "client" ? "client_matches_all_matches" : "caregiver_matches_all_matches", "All Matches") + " ("
        let loadedTotal = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", totalPrefix)).firstMatch
        func supportedStart() -> NativeOwnerProfileStart? {
            let profile = actualLower(profileTabs), matches = actualLower(matchesTabs), messages = actualLower(messagesTabs)
            return NativeOwnerProfileStart.decide(foreground: app.state == .runningForeground,
                busy: busy.exists, interrupted: app.alerts.count > 0 || springboard.alerts.count > 0,
                uniqueTabs: profile.count == 1 && matches.count == 1 && messages.count == 1,
                matchesSelected: matches.count == 1 && matches[0].isSelected,
                profileSelected: profile.count == 1 && profile[0].isSelected,
                messagesSelected: messages.count == 1 && messages[0].isSelected,
                loadedMatches: loadedTotal.exists, exactVisibleOwnedEmail: exactVisibleEmail())
        }
        var taps = 0
        var observedStart: NativeOwnerProfileStart?
        var stableSince: Date?
        do {
            try wait("supported-stable-owned-Main-start-required", timeout: 90) {
                guard let current = supportedStart() else { observedStart = nil; stableSince = nil; return false }
                if current != observedStart { observedStart = current; stableSince = Date() }
                return Date().timeIntervalSince(stableSince ?? Date()) >= 3
            }
            guard let start = observedStart else { throw Guard.Stopped.invariant("explicit-owner-start-required") }
            try writes(expectedWrites)
            let beforeAX = XCTAttachment(string: app.debugDescription)
            beforeAX.name = "private-owner-before-\(start.rawValue)-AX"; beforeAX.lifetime = .keepAlways; add(beforeAX)
            try capture("private-owner-before-\(start.rawValue)", element: app)
            // Re-evaluate the same branch immediately before its only permitted action.
            // A branch change is a stop, never a reason to tap twice or choose another route.
            try Guard.require(supportedStart() == start, "owner-start-must-remain-identical-and-unblocked")
            if start == .transitionFromMatches {
                let target = actualLower(profileTabs)
                try Guard.require(target.count == 1, "one-observed-owner-Profile-target-required")
                let geometry = XCTAttachment(string: "start=\(start.rawValue);ProfileTapIntent=1;targetFrame=\(target[0].frame);appFrame=\(app.frame);foreground=true;selectedBefore=false")
                geometry.name = "private-owner-one-Profile-tap-geometry"; geometry.lifetime = .keepAlways; add(geometry)
                taps = 1
                target[0].tap() // One genuine normal transition. No retry or alternate navigation.
            } // Already-owned Profile revalidation performs ZERO additional taps.
            try wait("selected-Profile-and-exact-native-owner-required", timeout: 30) {
                let profile = actualLower(profileTabs), matches = actualLower(matchesTabs), messages = actualLower(messagesTabs)
                return NativeOwnerProfileStart.decide(foreground: self.app.state == .runningForeground,
                    busy: busy.exists, interrupted: self.app.alerts.count > 0 || springboard.alerts.count > 0,
                    uniqueTabs: profile.count == 1 && matches.count == 1 && messages.count == 1,
                    matchesSelected: matches.count == 1 && matches[0].isSelected,
                    profileSelected: profile.count == 1 && profile[0].isSelected,
                    messagesSelected: messages.count == 1 && messages[0].isSelected,
                    loadedMatches: false, exactVisibleOwnedEmail: exactVisibleEmail()) == .revalidateOwnedProfile
            }
            try Guard.require(taps == (start == .transitionFromMatches ? 1 : 0), "exact-owner-branch-tap-budget-required")
            try writes(expectedWrites)
            let proof = XCTAttachment(string: "start=\(start.rawValue);ProfileTaps=\(taps);foreground=true;ProfileSelected=true;exactVisibleOwnedEmail=true;noFallbackOrTapRetry=true")
            proof.name = "native-owner-explicit-start-and-exact-email-proof"; proof.lifetime = .keepAlways; add(proof)
            let afterAX = XCTAttachment(string: app.debugDescription)
            afterAX.name = "private-owner-selected-Profile-exact-email-AX"; afterAX.lifetime = .keepAlways; add(afterAX)
            try capture("private-owner-selected-Profile-exact-email", element: app)
            try j.event("native-owned-Profile-verified", ["role": role, "supportedStart": start.rawValue, "ProfileTaps": taps,
                "exactSemanticEmail": true, "foreground": true, "noRetryOrAlternateNavigation": true])
        } catch {
            let state = XCTAttachment(string: "supportedStart=\(observedStart?.rawValue ?? "none");ProfileTapIntents=\(taps);appStateRaw=\(app.state.rawValue);foreground=\(app.state == .runningForeground);noTapRetryOrFallback=true")
            state.name = "private-owner-transition-failure-state"; state.lifetime = .keepAlways; add(state)
            let ax = XCTAttachment(string: app.debugDescription)
            ax.name = "private-owner-transition-failure-AX"; ax.lifetime = .keepAlways; add(ax)
            try? capture("private-owner-transition-failure-no-retry", element: app)
            throw error
        }
    }
    /// Reveal the same genuine managed Welcome button by scrolling its exact
    /// native Intro scroll view; never substitute a route push or coordinate tap.
    private func revealWelcomeSignIn() throws -> XCUIElement {
        let welcome = app.buttons[text("intro_sign_in", "Sign in")].firstMatch
        try Guard.require(welcome.waitForExistence(timeout: 120), "actual-Welcome-Sign-in-must-exist")
        let scroll = app.scrollViews["v2-16-14997"].firstMatch
        try Guard.require(scroll.exists, "actual-native-Intro-scroll-view-required")
        var swipes = 0
        for _ in 0..<8 {
            if welcome.isEnabled && welcome.isHittable && app.frame.contains(welcome.frame) { break }
            scroll.swipeUp(velocity: .slow); swipes += 1
        }
        try ready(welcome)
        try Guard.require(app.frame.contains(welcome.frame), "complete-Welcome-Sign-in-control-must-be-visible")
        try writes([:])
        let proof = XCTAttachment(string: "actualIntroScrollView=true;boundedSwipes=\(swipes);completeSignInVisible=true;enabled=true;hittable=true;nonGETs=0")
        proof.name = "native-Welcome-reveal-structural"; proof.lifetime = .keepAlways; add(proof)
        return welcome
    }
    private func signIn(_ role: String, journal j: NativeOwnedGraphPhaseJournal) throws {
        try recordProcessIfRunning(); app.terminate(); activeRole = role; expectedWrites = [:]
        app.launchArguments = ["--qa-signout", "--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launchEnvironment = [:] // No QA login credentials are injected into app.
        if scopedSmallGETs { scopedSmallProcessBegan = ProcessInfo.processInfo.systemUptime }
        app.launch(); processIndex += 1
        let welcome = try revealWelcomeSignIn()
        welcome.tap()
        if verifyBackOnFirstLogin && !backVerified {
            try verifyEmptySignInBackThenReopen()
            backVerified = true
        }
        let email = app.textFields["Enter your email address..."]
        let password = app.secureTextFields["Enter your password..."]
        try ready(email); email.tap(); email.typeText(j.account(role).email)
        try ready(password); password.tap(); password.typeText(j.account(role).password)
        let returnKey = app.keyboards.buttons["Return"].firstMatch
        if returnKey.exists && returnKey.isHittable && app.frame.intersects(returnKey.frame) { returnKey.tap() }
        else { app.swipeDown(velocity: .slow) }
        let submit = app.buttons["Sign In"].firstMatch
        for _ in 0..<4 where !submit.isHittable { app.swipeUp(velocity: .slow) }
        try ready(submit); try writes([:])
        try j.uiLoginIntent(role); submit.tap(); expectedWrites = ["POST /api/auth/login": 1]
        // Positive system prompt handling must run before any hittability gate.
        try settlePasswordSavePrompt(j, requireMainReady: true)
        try ready(app.buttons[text("bottom_navigation_messages", "Messages")].firstMatch, timeout: 90)
        try writes(["POST /api/auth/login": 1])
        try Guard.require(app.staticTexts["qa-token-presence"].label == "accessPresent=true;refreshPresent=true", "native-saved-owned-pair-required")
        try writes(["POST /api/auth/login": 1])
        try owner(role, j)
    }
    /// The actual tab ScrollView and measured bottom tab frame define the visible
    /// content region; no fixed screen coordinate or hidden route substitutes.
    /// Short, held normal drags use current target geometry. Unlike a flick,
    /// release has no intended inertia, and an overshot target reverses direction.
    private func revealExactTabTarget(_ query: XCUIElementQuery, tag: String, finishedHistory: Bool = false, expectedCount: Int = 1, targetIndex: Int = 0) throws -> XCUIElement {
        let (scroll, viewport) = try finishedHistory ? actualHistoryScrollViewport() : actualTabScrollViewport()
        try Guard.require(expectedCount > 0 && expectedCount <= 10 && targetIndex >= 0 && targetIndex < expectedCount, "finite-exact-history-target-index")
        var lastFrame: CGRect?
        for step in 0..<8 {
            try Guard.require(query.count <= expectedCount, "ambiguous-exact-tab-target")
            let observed = query.count == expectedCount ? query.element(boundBy: targetIndex).frame : nil
            let current: CGRect? = observed.flatMap { frame in
                frame.width > 0 && frame.height > 0 && frame.minX.isFinite && frame.minY.isFinite
                    && frame.width.isFinite && frame.height.isFinite ? frame : nil
            }
            if let current { lastFrame = current }
            if query.count == expectedCount && query.element(boundBy: targetIndex).isEnabled && query.element(boundBy: targetIndex).isHittable,
               let current, viewport.contains(current) {
                let proof = XCTAttachment(string: "tag=\(tag);step=\(step);viewport=\(viewport);targetFrame=\(current);fullyContained=true")
                proof.name = "private-exact-scroll-target-visible"; proof.lifetime = .keepAlways; add(proof)
                try capture("private-\(tag)-fully-visible", element: app)
                return query.element(boundBy: targetIndex)
            }
            let frame = current ?? lastFrame
            let moveDown = frame.map { $0.minY < viewport.minY } ?? false
            let gap = frame.map { moveDown ? viewport.minY - $0.minY : $0.maxY - viewport.maxY } ?? viewport.height * 0.15
            // Target already fits but is blocked: do not scroll around an unknown
            // interruption or substitute a different action.
            if let current, viewport.contains(current) {
                try capture("private-\(tag)-blocked-stop", element: app)
                throw Guard.Stopped.invariant("fully-contained-target-not-hittable-no-alternate-action")
            }
            let distance = min(max(24, gap + 8), viewport.height * 0.20)
            let start = CGPoint(x: viewport.midX, y: viewport.midY)
            let end = CGPoint(x: start.x, y: start.y + (moveDown ? distance : -distance))
            try Guard.require(viewport.contains(start) && viewport.contains(end) && distance > 0,
                              "short-drag-must-remain-inside-observed-viewport")
            let geometry = XCTAttachment(string: "tag=\(tag);step=\(step);viewport=\(viewport);targetFrame=\(String(describing: current));lastKnownFrame=\(String(describing: lastFrame));direction=\(moveDown ? "down" : "up");distance=\(distance);start=\(start);end=\(end)")
            geometry.name = "private-directional-short-scroll-geometry"; geometry.lifetime = .keepAlways; add(geometry)
            if step == 0 { try capture("private-\(tag)-before-short-scroll", element: app) }
            let origin = scroll.coordinate(withNormalizedOffset: .zero)
            let a = origin.withOffset(CGVector(dx: start.x - scroll.frame.minX, dy: start.y - scroll.frame.minY))
            let b = origin.withOffset(CGVector(dx: end.x - scroll.frame.minX, dy: end.y - scroll.frame.minY))
            a.press(forDuration: 0.1, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        try capture("private-\(tag)-bounded-scroll-stop", element: app)
        throw Guard.Stopped.invariant("exact-target-not-fully-revealed-after-bounded-directional-drags")
    }
    /// Manage Matches is a pushed screen; its native navigation bar replaces Main's bottom tab context.
    private func actualHistoryScrollViewport() throws -> (XCUIElement, CGRect) {
        let title = text("profile_matches_title", "Matches")
        let bars = app.navigationBars.matching(identifier: title)
        let history = app.buttons.matching(identifier: text("match_tab_history", "History"))
        let busy = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text("loading_please_wait", "Please wait...")))
        try wait("pushed-History-context-settled", timeout: 30) {
            bars.count == 1 && history.count == 1 && history.firstMatch.isSelected && busy.count == 0
        }
        let scrolls = app.scrollViews.allElementsBoundByIndex.filter { $0.isHittable }
        try Guard.require(scrolls.count == 1 && bars.firstMatch.frame.height > 0, "unique-pushed-History-scroll-and-navigation-bar")
        let belowBar = CGRect(x: app.frame.minX, y: bars.firstMatch.frame.maxY, width: app.frame.width,
                              height: app.frame.maxY - bars.firstMatch.frame.maxY)
        let viewport = scrolls[0].frame.intersection(belowBar).intersection(app.frame)
        try Guard.require(!viewport.isNull && viewport.width > 0 && viewport.height > 0, "positive-History-content-viewport")
        return (scrolls[0], viewport)
    }
    private func actualTabScrollViewport() throws -> (XCUIElement, CGRect) {
        let scrolls = app.scrollViews.allElementsBoundByIndex.filter { $0.isHittable }
        let messages = app.buttons.matching(identifier: text("bottom_navigation_messages", "Messages")).allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.minY > self.app.frame.midY && self.app.frame.contains($0.frame)
        }
        try Guard.require(scrolls.count == 1 && messages.count == 1, "unique-actual-tab-scroll-and-bar-required")
        let aboveBar = CGRect(x: app.frame.minX, y: app.frame.minY, width: app.frame.width,
                              height: messages[0].frame.minY - app.frame.minY)
        let viewport = scrolls[0].frame.intersection(aboveBar)
        try Guard.require(!viewport.isNull && viewport.width > 0 && viewport.height > 0, "positive-tab-content-viewport-required")
        return (scrolls[0], viewport)
    }
    private func firstPagePeer(_ role: String, j: NativeOwnedGraphPhaseJournal) throws {
        let endpoint = role == "client" ? "clients/matches" : "caregivers/matches"
        let path = endpoint + "?page=1&perPage=10&sort=distance"
        let response = try scopedSmallGETs ? scopedSmallDirectGET(path, token: j.account(role).token)
            : CarezaarAPI.callWithHTTPStatus("GET", path, token: j.account(role).token)
        try Guard.require(response.status == 200, "independent-first-page-must-load")
        guard let rows = response.body["result"] as? [[String: Any]] else { throw Guard.Stopped.invariant("first-page-array-required") }
        let owned = rows.filter { j.stringID(($0["user"] as? [String: Any])?["id"]) == j.peer(role).id }
        if scopedSmallGETs {
            try j.event("small-scoped-first-page-cardinality", ["role": role, "rowCount": rows.count,
                "ownedPeerCount": owned.count, "page": 1, "perPage": 10])
            try Guard.require(rows.count <= 10, "Small-first-page-schema-page10-bound-required")
        }
        try Guard.require(owned.count == 1, "exact-peer-not-in-native-first-page-no-fabricated-card")
    }
    private func openExactPeerFromActualMatches(_ j: NativeOwnedGraphPhaseJournal) throws {
        let role = activeRole, endpoint = role == "client" ? "clients/matches" : "caregivers/matches"
        try firstPagePeer(role, j: j)
        try bottom(text("bottom_navigation_matches", "Matches"))
        let cards = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", j.peer(role).name, text("general_miles_away", "mile(s) away")))
        let totalPrefix = text(role == "client" ? "client_matches_all_matches" : "caregiver_matches_all_matches", "All Matches") + " ("
        let loadedTotal = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", totalPrefix)).firstMatch
        try wait("actual-native-matches-must-load") {
            self.count("GET /api/" + endpoint) >= 1 && loadedTotal.exists
                && !self.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch.exists
        }
        _ = try revealExactTabTarget(cards, tag: "owned-peer-card")
        try ready(cards.firstMatch)
        let fresh = try j.profiles()[role]!
        let active = fresh["is_match"] as? Bool == true
        let badge = cards.firstMatch.descendants(matching: .any)["active-match-icon"]
        // AppIcon's Canvas is accessibilityHidden; AX alone cannot certify badge paint.
        // The full target crop is mandatory evidence for independent active/restricted review.
        if !active { try Guard.require(!badge.exists, "restricted-card-no-AX-active-badge") }
        try capture("native-\(role)-\(fresh["match_status"] as? String ?? "unknown")-card-badge-PAINT-review-required", element: cards.firstMatch)
        try j.event("card-paint-evidence-captured", ["role": role, "expectedActive": active, "manualRasterReviewRequired": true])
        let beforeProfile = count("GET /api/" + j.profilePath(role))
        cards.firstMatch.tap()
        try wait("exact-native-peer-profile-not-loaded") { self.count("GET /api/" + j.profilePath(role)) > beforeProfile && self.app.staticTexts[j.peer(role).name].firstMatch.exists }
    }

    private var nativeChatGETsTotal = 0
    private var processIndex = 0
    private var recordedProcessIndex = 0
    private func recordProcessIfRunning() throws {
        guard processIndex > recordedProcessIndex else { return }
        try writes(expectedWrites)
        if let chat = journal?.chatID {
            nativeChatGETsTotal += count("GET /api/users/chats/\(chat)")
            try Guard.require(nativeChatGETsTotal <= 128, "finite-native-chat-read/poll-bound")
        }
        var snapshot: [String: Any] = ["role": activeRole,
            "ledger": app.staticTexts["qa-request-counts"].label, "expectedNonGET": expectedWrites,
            "dedicatedReadAckMutationCount": 0, "cumulativeNativeGETChatAttempts": nativeChatGETsTotal, "GETChatMayUpdateReadReceipt": journal?.phase == .C]
        if scopedSmallGETs {
            let budget = try scopedSmallNativeGETBudget(); snapshot["scopedSmallGETBudget"] = budget
            scopedSmallRecordedGETs += budget["GETCount"] as? Int ?? 0
        }
        try journal?.privateSnapshot("native-process-\(processIndex)-ledger.json", snapshot)
        recordedProcessIndex = processIndex
    }
    private func ordinaryMain(_ j: Guard) throws {
        try recordProcessIfRunning(); app.terminate(); expectedWrites = [:]
        app.launchArguments = ["--qa-request-counts", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
        app.launchEnvironment = [:]
        if scopedSmallGETs { scopedSmallProcessBegan = ProcessInfo.processInfo.systemUptime }
        app.launch(); processIndex += 1
        try settlePasswordSavePrompt(j, requireMainReady: true)
        try ready(app.buttons[text("bottom_navigation_messages", "Messages")].firstMatch, timeout: 90)
        try Guard.require(app.staticTexts["qa-token-presence"].label == "accessPresent=true;refreshPresent=true", "ordinary-relaunch-must-retain-saved-session")
        try writes([:]); try owner(activeRole, j)
    }
    private func verifyEmptySignInBackThenReopen() throws {
        let email = app.textFields["Enter your email address..."], password = app.secureTextFields["Enter your password..."]
        try ready(email); try ready(password)
        let submit = app.buttons["Sign In"].firstMatch
        try Guard.require(submit.exists && !submit.isEnabled
            && [email, password].allSatisfy { element in (element.value as? String).map { $0.isEmpty || $0 == element.placeholderValue } ?? false }, "Back-proof-requires-empty-disabled-SignIn")
        try writes([:])
        let candidates = app.buttons.matching(NSPredicate(format: "label == %@", "Back"))
        try Guard.require(candidates.count == 1, "one-real-Back-button-with-semantic-label-required")
        let back = candidates.element(boundBy: 0); try ready(back)
        let scene = app.scrollViews["v2-51-5170"].firstMatch
        try Guard.require(scene.exists, "actual-native-SignIn-scene-required")
        let scale = scene.frame.width / 412
        try Guard.require(scale.isFinite && scale > 0 && abs(back.frame.height - 40 * scale) < 1, "observed-source-Back-header-scale")
        let expected = CGRect(x: back.frame.minX, y: back.frame.minY + 4 * scale, width: 32 * scale, height: 32 * scale)
        var rectangles: [CGRect] = []
        for rect in back.descendants(matching: .other).allElementsBoundByIndex.map(\.frame) where
            abs(rect.minX - expected.minX) < 1 && abs(rect.minY - expected.minY) < 1
                && abs(rect.width - expected.width) < 1 && abs(rect.height - expected.height) < 1 {
            if !rectangles.contains(rect) { rectangles.append(rect) }
        }
        try Guard.require(rectangles.count == 1, "unique-observed-painted-Back-square")
        let rect = rectangles[0], center = CGPoint(x: rectangles[0].midX, y: rectangles[0].midY)
        try Guard.require(app.frame.insetBy(dx: -1, dy: -1).contains(rect)
            && back.frame.insetBy(dx: -1, dy: -1).contains(rect) && app.frame.contains(center) && back.frame.contains(center), "real-Back-target-contained-with-only-AX-rounding-tolerance")
        try capture("empty-SignIn-semantic-Back-before-required-login", element: app)
        back.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: center.x - back.frame.minX, dy: center.y - back.frame.minY)).tap()
        try Guard.require(password.waitForNonExistence(timeout: 15) && app.scrollViews["v2-16-14997"].exists, "real-Back-must-return-Welcome")
        try writes([:]); try journal?.event("actual-semantic-Back-returned-Welcome-before-login", ["label": "Back", "credentialsTyped": false, "nonGET": 0])
        let welcome = try revealWelcomeSignIn(); welcome.tap(); try ready(email); try ready(password)
        try writes([:])
    }
    private func profileState(_ state: String, j: Guard) throws {
        let ids = ["match-request", "match-withdraw", "match-reject", "match-accept", "match-unmatch"]
        let expected: Set<String> = state == "none" ? ["match-request"] : state == "sent" ? ["match-withdraw"]
            : state == "received" ? ["match-reject", "match-accept"] : ["match-unmatch"]
        for id in ids {
            if expected.contains(id) { try ready(app.buttons[id]) }
            else { try Guard.require(!app.buttons[id].exists, "incorrect-native-relationship-action") }
        }
        let message = app.buttons[text(activeRole == "client" ? "caregiver_details_message" : "client_details_message", "Message")]
        if state == "active" { try ready(message) }
        else { try Guard.require(!message.exists, "restricted-relationship-must-not-offer-Message") }
        if !j.introduction.isEmpty {
            try Guard.require(!app.staticTexts.matching(NSPredicate(format: "label == %@", j.introduction)).firstMatch.exists, "profile-top-must-not-show-introduction")
        }
        let actionLabels = ["match-request": text("match_match_button", "Request a Match"),
            "match-withdraw": text("match_withdraw_title", "Withdraw"),
            "match-reject": text("match_reject_title", text("match_reject", "Reject")),
            "match-accept": text("match_accept_title", "Accept"), "match-unmatch": text("match_unmatch_title", "Unmatch")]
        for id in expected { try Guard.require(app.buttons[id].label == actionLabels[id], "exact-managed-profile-action-label") }
        if state == "sent" {
            try Guard.require(app.buttons["match-withdraw"].label == text("match_withdraw_title", "Withdraw"), "outgoing-managed-Withdraw")
        }
        if state == "received" {
            let reject = app.buttons["match-reject"].frame, accept = app.buttons["match-accept"].frame
            try Guard.require(abs(reject.midY - accept.midY) < 8 ? reject.midX < accept.midX : reject.midY < accept.midY, "Reject-before-Accept")
        }
        try writes(expectedWrites)
        try capture("native-\(activeRole)-profile-\(state)", element: app)
    }
    private func requestForm(_ j: Guard, submit: Bool) throws {
        try ready(app.buttons["match-request"]); app.buttons["match-request"].tap()
        let title = text("match_match_button", "Request a Match")
        let contentView = app.scrollViews["match-request-content"].firstMatch
        try Guard.require(contentView.waitForExistence(timeout: 15), "actual-Match-form-content-required")
        let heading = contentView.staticTexts.matching(NSPredicate(format: "label == %@", title))
        try wait("one-actual-full-managed-title-StaticText-required", timeout: 15) { heading.count == 1 }
        try Guard.require(heading.firstMatch.identifier == "match-request-heading" && heading.firstMatch.label == title,
                          "one-full-managed-Match-heading")
        try ready(heading.firstMatch)
        try Guard.require(app.frame.contains(heading.firstMatch.frame), "full-heading-contained")
        let question = text("match_match_message", "Are you sure you want to match with this user? They should accept your request.")
        try Guard.require(app.staticTexts.matching(NSPredicate(format: "label == %@", question)).firstMatch.exists, "exact-managed-Match-body")
        let input = app.textFields[text("match_introduction_title", "Introduction")]
        try ready(input)
        try Guard.require((input.value as? String).map { $0.isEmpty || $0 == input.placeholderValue } == true, "request-input-starts-blank")
        if !j.introduction.isEmpty { input.tap(); input.typeText(j.introduction); app.swipeDown(velocity: .slow) }
        try Guard.require(j.introduction.count < 1000 && ((input.value as? String) == j.introduction
            || (j.phase.blankIntroduction && (input.value as? String) == input.placeholderValue)), "exact-full-or-truly-blank-introduction")
        let confirm = app.buttons["match-request-confirm"], cancel = app.buttons["match-request-dismiss"]
        try Guard.require(confirm.label == text("match_match_title", "Match") && cancel.label == text("general_cancel", "Cancel"), "exact-Match-and-distinct-Cancel-actions")
        try ready(confirm); try ready(cancel)
        try capture(submit ? "marked-native-request-before-one-submit" : "native-request-before-no-write-dismiss", element: app)
        try writes(expectedWrites)
        if submit {
            try j.requestIntent(activeRole); confirm.tap(); expectedWrites["POST /api/users/matches"] = 1
            try wait("one-native-request-POST", timeout: 60) { self.count("POST /api/users/matches") == 1 }
            // A ledger entry is dispatch only. Require the completed native response transition before binding.
            try wait("native-request-response-rendered-SENT", timeout: 60) {
                self.app.buttons["match-withdraw"].exists && self.app.buttons["match-withdraw"].isEnabled
                    && self.app.buttons["match-withdraw"].isHittable && !heading.firstMatch.exists
            }
        } else {
            cancel.tap(); try ready(app.buttons["match-request"])
            try Guard.require(heading.firstMatch.waitForNonExistence(timeout: 10), "native-request-dismiss-must-close-sheet")
        }
        try writes(expectedWrites)
    }
    // Resolve only inside the actual exact-title/body alert. UIKit may expose one physical action
    // as nested parent/child Buttons; distinct physical targets or multiple leaves are never guessed.
    private func exactAlertAction(_ alert: XCUIElement, identifier: String, label: String) throws -> XCUIElement {
        try Guard.require(alert.exists && alert.isHittable && app.frame.contains(alert.frame), "actual-contained-visible-confirmation-alert-required")
        let candidates = alert.buttons.matching(identifier: identifier).allElementsBoundByIndex
        let observations = candidates.map { element in
            NativeAlertActionObservation(identifier: element.identifier, label: element.label, frame: element.frame,
                isLeaf: element.descendants(matching: .button).count == 0,
                enabled: element.isEnabled, hittable: element.isHittable)
        }
        guard let index = NativeAlertActionPolicy.uniqueLeafIndex(observations, identifier: identifier, label: label,
                                                                 alertFrame: alert.frame, appFrame: app.frame) else {
            try capture("ambiguous-exact-alert-action-stopped", element: alert)
            throw Guard.Stopped.invariant("one-exact-managed-same-frame-actionable-alert-leaf-required")
        }
        let selected = candidates[index]
        try Guard.require(selected.exists && selected.identifier == identifier && selected.label == label
            && selected.isEnabled && selected.isHittable && selected.frame == observations[index].frame
            && app.frame.contains(selected.frame) && alert.frame.contains(selected.frame)
            && selected.descendants(matching: .button).count == 0,
            "resolved-alert-leaf-must-remain-the-observed-exact-action")
        let proof = XCTAttachment(string: "identifier=\(identifier);label=\(label);candidateCount=\(candidates.count);leafCount=1;physicalFrame=\(selected.frame);sameFrame=true;contained=true;actionableLeaf=true")
        proof.name = "exact-managed-alert-action-leaf-geometry"; proof.lifetime = .keepAlways; add(proof)
        return selected
    }
    private func confirmMutation(_ action: String, j: Guard) throws {
        guard let edge = j.edgeID else { throw Guard.Stopped.invariant("bound-edge-before-dialog") }
        let key = action == "withdraw" ? "match-withdraw" : "match-" + action
        let label = action == "withdraw" ? text("match_withdraw_title", "Withdraw") : action == "reject"
            ? text("match_reject_title", text("match_reject", "Reject")) : text("match_\(action)_title", action == "accept" ? "Accept" : "Unmatch")
        let fallback = action == "withdraw" ? "Are you sure you want to withdraw your match request with this user?" : action == "reject"
            ? "Are you sure you want to reject this match request?" : action == "accept"
            ? "Are you sure you want to accept this match request?" : "Are you sure you want to end your match with this user?"
        let question = text("match_\(action)_message", fallback)
        let body = (action == "accept" || action == "reject") && !j.introduction.isEmpty
            ? question + "\n\n" + text("match_introduction_title", "Introduction") + "\n" + j.introduction : question
        for attempt in 0...1 {
            try ready(app.buttons[key]); app.buttons[key].tap()
            let alert = app.alerts.firstMatch
            try Guard.require(alert.waitForExistence(timeout: 15)
                && alert.staticTexts.matching(NSPredicate(format: "label == %@", label)).count == 1
                && alert.staticTexts.matching(NSPredicate(format: "label == %@", body)).count == 1, "exact-managed-dialog-title-and-full-introduction-or-blank-body")
            let cancel = try exactAlertAction(alert, identifier: "match-confirm-dismiss", label: text("general_cancel", "Cancel"))
            let confirm = try exactAlertAction(alert, identifier: "match-action-confirm", label: label)
            try Guard.require(cancel.label == text("general_cancel", "Cancel") && confirm.label == label, "distinct-correct-dialog-actions")
            try ready(cancel); try ready(confirm); try writes(expectedWrites)
            try capture("\(action)-managed-dialog-\(attempt)", element: alert)
            if attempt == 0 {
                cancel.tap(); try Guard.require(alert.waitForNonExistence(timeout: 10), "dialog-dismiss-must-close")
                _ = try j.requirePair(action == "unmatch" ? "active" : "pending", edge: edge)
                try writes(expectedWrites)
            } else {
                try j.mutationIntent(action, role: activeRole)
                let route = (action == "accept" ? "PATCH" : "DELETE") + " /api/users/matches/\(edge)" + (action == "unmatch" ? "" : "/" + action)
                confirm.tap(); expectedWrites[route] = 1
                try wait("one-exact-bound-native-mutation", timeout: 60) { self.count(route) == 1 }
                try writes(expectedWrites)
                // Dispatch alone does not prove the awaited response completed. Require the actual post-response UI.
                if action == "accept" {
                    let matchedTitle = text("match_matched_title", "It's a Match!")
                    try wait("Accept-response-rendered-Matched-screen", timeout: 60) {
                        !alert.exists && self.app.staticTexts.matching(NSPredicate(format: "label == %@", matchedTitle)).firstMatch.exists
                    }
                } else {
                    let request = app.buttons["match-request"]
                    try wait("terminal-response-rendered-Request-Match", timeout: 60) {
                        !alert.exists && request.exists && request.isEnabled && request.isHittable
                    }
                }
                _ = try j.requirePair(action == "accept" ? "active" : "none", edge: action == "accept" ? edge : nil)
            }
        }
    }
    private func matchedScreenThenOrdinaryMain(_ j: Guard) throws {
        let title = text("match_matched_title", "It's a Match!")
        try wait("actual-matched-screen-required", timeout: 60) { self.app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch.exists }
        let ownCard = app.descendants(matching: .any)["matched-self-photo-card"].firstMatch
        let peerCard = app.descendants(matching: .any)["matched-partner-photo-card"].firstMatch
        let ownRole = text(activeRole == "client" ? "general_usertype_client" : "general_usertype_caregiver", activeRole == "client" ? "Client" : "Caregiver")
        let peerRole = text(activeRole == "client" ? "general_usertype_caregiver" : "general_usertype_client", activeRole == "client" ? "Caregiver" : "Client")
        try Guard.require(ownCard.exists && peerCard.exists && ownCard.label.contains(text("chat_screen_you", "You"))
            && ownCard.label.contains(ownRole) && peerCard.label.contains(j.peer(activeRole).name)
            && peerCard.label.contains(peerRole), "matched-screen-exact-full-peer-and-both-role-cards")
        let prompt = text("match_matched_prompt", "You and {PARTNER} have matched!").replacingOccurrences(of: "{PARTNER}", with: j.peer(activeRole).name)
        try Guard.require(app.staticTexts.matching(NSPredicate(format: "label == %@", prompt)).firstMatch.exists, "full-managed-matched-prompt")
        try ready(app.buttons[text("match_matched_chat_button", "Send a Message")])
        try ready(app.buttons[text("match_matched_profile_button", "View Profile")])
        try capture("actual-native-\(activeRole)-matched-screen", element: app)
        try writes(expectedWrites); try ordinaryMain(j)
    }
    private func openManage(_ tab: String, j: Guard) throws {
        try owner(activeRole, j)
        let query = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@",
            text("profile_matches_title", "Matches"), text("profile_matches_description", "Review your match history")))
        let row = try revealExactTabTarget(query, tag: "own-Manage-Matches"); row.tap()
        let segment = app.buttons[tab].firstMatch; try ready(segment)
        let before = count("GET /api/users/matches"), changesTab = !segment.isSelected
        if changesTab { segment.tap() }
        try wait("actual-managed-list-loaded", timeout: 60) {
            segment.isSelected && self.count("GET /api/users/matches") >= (changesTab ? before + 1 : 1)
                && !self.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Please wait")).firstMatch.exists
        }
    }
    private func inspectPendingIntroduction(_ j: Guard, edge: Int, outgoing: Bool) throws {
        try ordinaryMain(j)
        // Requests contains pending records for both sender and recipient. Matches is the active category.
        try openManage(text("match_tab_requests", "Requests"), j: j)
        let busy = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text("loading_please_wait", "Please wait...")))
        let bound = try j.ownedEdge(edge)
        guard let start = bound["created_at"] as? String, !start.isEmpty else { throw Guard.Stopped.invariant("exact-source-row-stored-start-required") }
        let context = text("match_start", "Start") + ": " + start
        let actualRows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", j.peer(activeRole).name, context))
        try wait("exact-bound-Requests-primary-row-applied-and-ANYbusy-gone", timeout: 60) {
            actualRows.count == 1 && actualRows.firstMatch.isEnabled && actualRows.firstMatch.isHittable
                && self.app.frame.contains(actualRows.firstMatch.frame) && busy.count == 0
        }
        let row = actualRows.firstMatch
        let ax = XCTAttachment(string: row.debugDescription); ax.name = "private-loaded-exact-pending-row-AX"; ax.lifetime = .keepAlways; add(ax)
        try capture("actual-loaded-exact-pending-row-before-caption-assertion", element: row)
        try capture("actual-loaded-Requests-full-frame", element: app)
        if outgoing {
            let caption = text("match_pending_acceptance", "Pending Acceptance")
            let exactLeaf = row.descendants(matching: .staticText).matching(NSPredicate(format: "label == %@", caption)).firstMatch.exists
            try Guard.require((exactLeaf || row.label.contains(caption)) && !row.label.contains("Pending Review"), "managed-Pending-Acceptance-never-Review")
        }
        let preview = app.buttons["match-introduction-\(edge)"]
        if j.phase.blankIntroduction {
            try Guard.require(!preview.exists, "blank-introduction-must-not-invent-preview-or-modal")
        } else {
            let busy = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text("loading_please_wait", "Please wait...")))
            try wait("exact-bound-pending-preview-applied-and-busy-overlay-gone", timeout: 60) {
                preview.exists && preview.isEnabled && preview.isHittable && self.app.frame.contains(preview.frame) && busy.count == 0
            }
            try ready(preview, timeout: 60)
            let first = String(j.introduction.prefix { !$0.isNewline })
            try Guard.require(first.count > 80 && preview.label == text("match_introduction_title", "Introduction") + ": " + first, "complete-first-line-not80-character-sliced")
            let reads = count("GET /api/" + j.profilePath(activeRole)); preview.tap()
            let detail = app.descendants(matching: .any)["match-introduction-detail"].firstMatch
            try Guard.require(detail.waitForExistence(timeout: 15)
                && detail.staticTexts.matching(NSPredicate(format: "label == %@", j.introduction)).count == 1
                && detail.staticTexts[j.peer(activeRole).name].exists, "full-introduction-and-exact-peer-modal")
            try capture("\(activeRole)-full-pending-introduction-modal", element: detail)
            let close = detail.buttons[text("general_cancel", "Cancel")].firstMatch; try ready(close); close.tap()
            try Guard.require(detail.waitForNonExistence(timeout: 10) && count("GET /api/" + j.profilePath(activeRole)) == reads, "intro-close-must-not-navigate-profile")
        }
        _ = try j.requirePair("pending", edge: edge); try writes(expectedWrites)
    }
    private func assertCurrentNoneAndHistory(_ j: Guard) throws {
        try wait("native-poststate-none", timeout: 60) { self.app.buttons["match-request"].exists }
        try profileState("none", j: j); _ = try j.requirePair("none")
        if fullDRequestsGETs || remainingCoreGETs { try j.event("full-D-native-profile-NONE", ["role": activeRole, "nativeProfileNONE": true]) }
        // Reopen the actual post-action card too; a stale open profile is insufficient card paint evidence.
        try ordinaryMain(j); try openExactPeerFromActualMatches(j); try profileState("none", j: j)
        try ordinaryMain(j); try openManage(text("match_tab_history", "History"), j: j)
        let histories = try j.history(activeRole)
        if j.phase.activeFlow, let edge = j.edgeID {
            guard let bytes = histories[edge], let row = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let start = row["created_at"] as? String, let end = row["finished_at"] as? String else { throw Guard.Stopped.invariant("actual-finished-owned-history-row-required") }
            let candidates = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@", j.peer(activeRole).name, start, end))
            let matching = try histories.compactMap { (id, bytes) -> Int? in
                guard let candidate = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      candidate["created_at"] as? String == start, candidate["finished_at"] as? String == end else { return nil }
                let side = activeRole == "client" ? "caregiver" : "client"
                let peerID = j.stringID(((candidate[side] as? [String: Any])?["user"] as? [String: Any])?["id"])
                return peerID == j.peer(activeRole).id ? id : nil
            }
            try Guard.require(matching.contains(edge) && matching.count <= 10, "exact-bound-edge-among-authenticated-same-label-history-models")
            try wait("all-same-label-History-models-have-native-rows", timeout: 30) { candidates.count == matching.count }
            let frames = candidates.allElementsBoundByIndex.map { $0.frame }
            try Guard.require(NativeHistoryPhysicalRows.distinct(frames, expected: matching.count),
                "same-label-history-rows-must-be-distinct-physical-rows-not-nested-duplicates")
            // Inspect EVERY matching row; date-only labels cannot identify one edge by themselves.
            // Exact authenticated models include the bound edge and preserve all previous history.
            for index in 0..<matching.count {
                _ = try revealExactTabTarget(candidates, tag: "finished-history-all-same-label-row-\(index)", finishedHistory: true,
                                            expectedCount: matching.count, targetIndex: index)
            }
            try j.event("all-same-label-ended-history-rows-inspected", ["role": activeRole, "authenticatedModelCount": matching.count,
                "nativePhysicalRowCount": frames.count, "boundEdgePresent": true, "everyRowInspected": true])
            try Guard.require(!app.buttons["match-introduction-\(edge)"].exists, "finished-row-must-not-offer-pending-intro-action")
        }
        try Guard.require(app.textFields.count == 0 && app.textViews.count == 0 && !app.buttons["Submit Review"].exists
            && !app.buttons["Submit review"].exists, "history-no-review-entry-form")
        if fullDRequestsGETs || remainingCoreGETs {
            let busy = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text("loading_please_wait", "Please wait...")))
            try wait("actual-History-settled-before-no-review-capture", timeout: 60) {
                busy.count == 0 && (!histories.isEmpty || self.app.staticTexts[self.text("match_tab_history", "History") + " (0)"].exists)
            }
        }
        try capture("\(activeRole)-poststate-finished-or-optional-pending-history", element: app)
        try writes(expectedWrites)
        if fullDRequestsGETs || remainingCoreGETs { try j.event("full-D-History-UI-inspected", ["role": activeRole, "noReviewForm": true, "ANYbusyGone": true]) }
    }
    private func capture(_ name: String, element: XCUIElement) throws {
        try Guard.require(element.exists, "real-capture-target-required")
        let shot = XCTAttachment(screenshot: element.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func messageRow(_ id: Int) -> XCUIElement { app.descendants(matching: .any)["chat-message-\(id)"].firstMatch }
    private func composerCandidate(allowDisabled: Bool = false) -> XCUIElement? {
        // A vertical SwiftUI TextField may expose UITextView after multiline typing.
        // Value/placeholder are mutable; one physical native text input is the stable target.
        let views = app.textViews.allElementsBoundByIndex.filter { $0.exists && (allowDisabled || ($0.isHittable && $0.isEnabled)) && $0.frame.width > 50 && app.frame.intersects($0.frame) }
        let fields = app.textFields.allElementsBoundByIndex.filter { $0.exists && (allowDisabled || ($0.isHittable && $0.isEnabled)) && $0.frame.width > 50 && app.frame.intersects($0.frame) }
        guard views.count <= 1 && fields.count <= 1, !views.isEmpty || !fields.isEmpty else { return nil }
        if let view = views.first, let field = fields.first {
            guard abs(view.frame.minX - field.frame.minX) <= 1 && abs(view.frame.minY - field.frame.minY) <= 1
                && abs(view.frame.width - field.frame.width) <= 1 && abs(view.frame.height - field.frame.height) <= 1 else { return nil }
        }
        return views.first ?? fields.first
    }
    private func composer(allowDisabled: Bool = false) throws -> XCUIElement {
        var found: XCUIElement?
        try wait("one-physical-native-chat-composer-required", timeout: 60) {
            let busy = self.app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", self.text("loading_please_wait", "Please wait...")))
            found = self.composerCandidate(allowDisabled: allowDisabled)
            return found != nil && busy.count == 0 && (allowDisabled || found!.isEnabled)
        }
        guard let found else { throw Guard.Stopped.invariant("unique-real-chat-text-input-required") }
        return found
    }
    private func transcript(above field: XCUIElement) throws -> XCUIElement {
        let candidates = app.scrollViews.allElementsBoundByIndex.filter {
            $0.exists && $0.frame.width > self.app.frame.width * 0.5 && $0.frame.height > 60
                && $0.frame.maxY <= field.frame.minY && $0.descendants(matching: .textField).count == 0
        }
        guard let result = candidates.max(by: { $0.frame.height < $1.frame.height }) else { throw Guard.Stopped.invariant("real-transcript-above-composer-required") }
        return result
    }
    private func exactConversationRow(_ j: Guard, unread: Bool?) throws -> XCUIElement {
        try bottom(text("bottom_navigation_messages", "Messages"))
        guard let chatID = j.chatID else { throw Guard.Stopped.invariant("bound-chat-id-required") }
        let rows = try j.ownedChatRows(activeRole)
        try Guard.require(rows.count == 1 && rows[0]["id"] as? Int == chatID, "same-owned-chat-list-row-required")
        let candidates = app.buttons.matching(NSPredicate(format: "label == %@", j.peer(activeRole).name))
        try wait("actual-owned-Messages-list-row-loaded", timeout: 60) { candidates.count > 0 }
        let row = try revealExactTabTarget(candidates, tag: "owned-existing-Messages-row")
        if let unread {
            let backendUnread = (rows[0]["new_message_count"] as? Int ?? -1) > 0
            try Guard.require(backendUnread == unread && ((row.value as? String)?.contains(text("messages_unread", "Unread")) == true) == unread,
                             "actual-unread-list-value-and-live-count-must-agree-before-chat-open")
        }
        try capture("\(activeRole)-actual-owned-Messages-row-unread-state", element: row)
        return row
    }
    private func openExistingConversation(_ j: Guard, unread: Bool? = nil) throws -> XCUIElement {
        let row = try exactConversationRow(j, unread: unread), before = count("GET /api/users/chats/\(j.chatID!)")
        row.tap()
        try wait("actual-existing-chat-detail-GET", timeout: 60) { self.count("GET /api/users/chats/\(j.chatID!)") > before }
        let field = try composer()
        if let latestBound = j.messageTexts.keys.max() {
            // Composer existence and GET dispatch precede load completion; await actual bound data in the native view.
            try wait("actual-bound-chat-response-applied", timeout: 60) { self.messageRow(latestBound).exists }
        }
        try writes(expectedWrites); return field
    }
    private func sendNative(_ body: String, role: String, parent: Int?, j: Guard) throws -> Int {
        let field = try composer()
        try Guard.require((field.value as? String).map { $0.isEmpty || $0 == field.placeholderValue } == true, "empty-owned-composer-before-one-native-send")
        field.tap(); field.typeText(body)
        let typedField = try composer()
        try Guard.require(typedField.value as? String == body, "exact-synthetic-native-draft-before-intent")
        let send = app.buttons["Send"]; try ready(send); try writes(expectedWrites)
        try j.nativeMessageIntent(role: role, text: body, parent: parent)
        let route = "POST /api/users/chats/\(j.chatID!)", expected = (expectedWrites[route] ?? 0) + 1
        send.tap(); expectedWrites[route] = expected
        try wait("one-native-message-POST-and-acknowledged-draft-clear", timeout: 60) {
            self.count(route) == expected && self.composerCandidate().map { ($0.value as? String) != body } == true && send.isEnabled
        }
        try writes(expectedWrites)
        let id = try j.verifyNativeMessage(role: role, text: body, parent: parent)
        try wait("acknowledged-native-message-row-applied", timeout: 30) { self.messageRow(id).exists }
        return id
    }
    private func visibleMessageAndTimestamp(_ id: Int, timestamp: String, field: XCUIElement) throws {
        let area = try transcript(above: field), row = messageRow(id)
        try wait("actual-message-row-and-footer-visible", timeout: 35) {
            guard row.exists && row.isHittable && area.frame.contains(row.frame) else { return false }
            let footer = row.staticTexts.matching(NSPredicate(format: "label == %@", timestamp))
            return footer.count == 1 && footer.firstMatch.isHittable && area.frame.contains(footer.firstMatch.frame)
        }
        try capture("owned-synthetic-message-row-and-exact-server-time", element: row)
    }
    private func storedMessage(_ id: Int, role: String, j: Guard) throws -> [String: Any] {
        let chat = try j.ownedChat(role)
        guard let rows = chat["messages"] as? [[String: Any]], let row = rows.first(where: { $0["id"] as? Int == id }) else { throw Guard.Stopped.invariant("bound-stored-message-required") }
        return row
    }
    private func awaitActualNativeChatDetail(_ j: Guard) throws -> Int {
        let busy = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text("loading_please_wait", "Please wait...")))
        var observed: Int?
        try wait("one-observed-native-chat-detail-route-and-completed-partner-paint", timeout: 60) {
            let prefix = "GET /api/users/chats/"
            var ids = Set<Int>()
            for line in self.app.staticTexts["qa-request-counts"].label.split(separator: "\n").map(String.init) where line.hasPrefix(prefix) {
                let parts = line.dropFirst(prefix.count).split(separator: "=")
                if parts.count == 2, let id = Int(parts[0]), id > 0, let count = Int(parts[1]), count > 0 { ids.insert(id) }
            }
            guard ids.count == 1, busy.count == 0,
                  self.app.staticTexts.matching(NSPredicate(format: "label == %@", j.peer("client").name)).count == 1,
                  self.composerCandidate() != nil else { return false }
            observed = ids.first; return true
        }
        guard let id = observed else { throw Guard.Stopped.invariant("actual-positive-native-chat-route-required") }
        try j.privateSnapshot("native-created-chat-detail-route-ledger.json", ["ledger": app.staticTexts["qa-request-counts"].label,
            "observedChatID": id, "ANYbusyGone": true, "exactOwnedPeerPaint": true])
        try capture("actual-native-empty-chat-loaded-before-binding-or-send", element: app)
        return id
    }
    private func chatDeliveryReplyViewportAndClientUnmatch(_ j: Guard) throws {
        // Client has accepted caregiver request and opened the actual active profile.
        try Guard.require(activeRole == "client", "C-client-acceptor-before-chat")
        if j.resumesBoundChat {
            guard let id = j.chatID else { throw Guard.Stopped.invariant("already-bound-chat-before-readonly-route") }
            try recordProcessIfRunning(); app.terminate(); expectedWrites = [:]
            app.launchArguments = ["--qa-request-counts", "--qa-push", "Chat/\(id)", "-carezaar.languageId", "1", "-carezaar.languageCode", "en"]
            app.launchEnvironment = [:]; scopedSmallProcessBegan = ProcessInfo.processInfo.systemUptime
            app.launch(); processIndex += 1
            let observed = try awaitActualNativeChatDetail(j)
            try Guard.require(observed == id && app.staticTexts["qa-token-presence"].label == "accessPresent=true;refreshPresent=true", "ordinary-saved-owner-and-exact-bound-chat-route")
            let field = try composer()
            try Guard.require((field.value as? String).map { $0.isEmpty || $0 == field.placeholderValue } == true, "old-unsent-draft-reset-on-ordinary-relaunch-no-POST")
            try writes([:]); try j.event("existing-bound-chat-opened-GET-only", ["newChatCreate": 0, "oldDraftNotSent": true])
        } else {
            let create = app.buttons[text("caregiver_details_message", "Message")]; try ready(create)
            try writes(expectedWrites); try j.prepareChatCreate(); create.tap()
            expectedWrites["POST /api/users/chats"] = 1
            try wait("one-native-chat-create", timeout: 60) { self.count("POST /api/users/chats") == 1 }
            _ = try composer()
            let observed = try awaitActualNativeChatDetail(j)
            _ = try j.bindChatAfterNativeCreate(observedID: observed); try writes(expectedWrites)
        }
        // SE3 cannot contain the Modern seven-line message anchor. Keep each bubble
        // bounded to two synthetic body lines there; retain actual overflow/anchor geometry assertions.
        let seedBodyLines = app.frame.height < 750 ? 2 : 7
        try j.event("device-sized-chat-seed-body", ["bodyLines": seedBodyLines, "appHeight": app.frame.height,
            "nativeSeedCap": 8, "actualOverflowStillRequired": true])
        var firstSeed: Int?, lastSeed: Int?, overflowObserved = false, seedCount = 0
        for ordinal in 1...8 {
            let body = j.marker + " client-seed-\(ordinal)\n"
                + (1...seedBodyLines).map { "Complete synthetic line \($0) for bounded viewport history." }.joined(separator: "\n")
            let id = try sendNative(body, role: "client", parent: nil, j: j)
            firstSeed = firstSeed ?? id; lastSeed = id; seedCount += 1
            // Ordinary saved-state reentry clears keyboard focus, never hidden login.
            // Measure the full real viewport before deciding whether another seed is necessary.
            try ordinaryMain(j); let field = try openExistingConversation(j)
            try Guard.require(!app.keyboards.firstMatch.exists, "seed-overflow-measured-without-software-keyboard")
            let area = try transcript(above: field), first = messageRow(firstSeed!)
            try Guard.require(first.exists, "first-owned-seed-AX-row-must-exist")
            if ordinal >= 2 && (!first.isHittable || first.frame.minY < area.frame.minY - 1) {
                overflowObserved = true; break
            }
        }
        try Guard.require(overflowObserved && seedCount <= 8, "actual-full-viewport-overflow-required-within-finite-native-send-cap")
        try j.event("viewport-derived-native-seed-count", ["nativeSeeds": seedCount, "cap": 8, "actualOverflowObserved": true])
        try signIn("caregiver", journal: j)
        try openExactPeerFromActualMatches(j); try profileState("active", j: j)
        try ordinaryMain(j)
        _ = try openExistingConversation(j, unread: true) // First caregiver detail GET occurs only after unread proof.
        guard let parentID = lastSeed else { throw Guard.Stopped.invariant("actual-native-seed-parent-required") }
        let parent = messageRow(parentID); try ready(parent)
        let options = app.buttons["chat-message-options-\(parentID)"]; try ready(options); options.tap()
        let reply = app.buttons[text("chat_screen_reply", "Reply")]; try ready(reply); reply.tap()
        try Guard.require(app.staticTexts.matching(NSPredicate(format: "label == %@", j.messageTexts[parentID]!)).firstMatch.exists,
                          "real-native-reply-preview-required")
        let replyBody = j.marker + " caregiver-reply"
        let replyID = try sendNative(replyBody, role: "caregiver", parent: parentID, j: j)
        try signIn("client", journal: j)
        try openExactPeerFromActualMatches(j); try profileState("active", j: j)
        try ordinaryMain(j)
        var field = try openExistingConversation(j, unread: true)
        let replyStored = try storedMessage(replyID, role: "caregiver", j: j)
        try Guard.require((replyStored["parent"] as? [String: Any])?["id"] as? Int == parentID
            && replyStored["seen_at"] is String, "native-client-detail-read-must-acknowledge-exact-caregiver-reply")
        try visibleMessageAndTimestamp(replyID, timestamp: try XCTUnwrap(replyStored["created_at"] as? String), field: field)
        let (bottomBody, bottomTime) = try j.postOnePeerIncoming(1)
        let bottomID = try XCTUnwrap(j.messageTexts.first(where: { $0.value == bottomBody })?.key)
        try visibleMessageAndTimestamp(bottomID, timestamp: bottomTime, field: field)
        let area = try transcript(above: field), anchorID = try XCTUnwrap(firstSeed), anchor = messageRow(anchorID)
        var established = false
        // Short drags: on the 6.9-inch screen one swipe moved the transcript about a full
        // viewport, so the anchor went from visible to below the fold in a single step and
        // the away-from-bottom state was never sampled (modern-C-v3a, v5a).
        for _ in 0..<36 {
            if anchor.exists && anchor.isHittable && area.frame.contains(anchor.frame) && !messageRow(bottomID).isHittable { established = true; break }
            let start = area.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40))
            let end = area.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        try Guard.require(established, "actual-older-reader-away-from-bottom-required-before-incoming")
        let oldY = anchor.frame.midY, readsBefore = count("GET /api/users/chats/\(j.chatID!)")
        try capture("client-actual-older-message-position-before-incoming", element: anchor)
        let (newBody, newTime) = try j.postOnePeerIncoming(2)
        let newID = try XCTUnwrap(j.messageTexts.first(where: { $0.value == newBody })?.key), newer = messageRow(newID)
        try wait("actual-new-data-applied-before-older-position-check", timeout: 45) {
            newer.exists && self.count("GET /api/users/chats/\(j.chatID!)") >= readsBefore + 2
        }
        try Guard.require(anchor.isHittable && area.frame.contains(anchor.frame) && abs(anchor.frame.midY - oldY) <= 3
            && !newer.isHittable, "applied-incoming-must-not-jump-older-reader")
        try capture("client-actual-older-position-preserved-after-applied-incoming", element: anchor)
        for _ in 0..<12 {
            if newer.exists && newer.isHittable && area.frame.contains(newer.frame) { break }
            area.swipeUp(velocity: .slow)
        }
        try visibleMessageAndTimestamp(newID, timestamp: newTime, field: field)
        let back = app.navigationBars.firstMatch.buttons.firstMatch; try ready(back); back.tap()
        field = try openExistingConversation(j, unread: false)
        try visibleMessageAndTimestamp(newID, timestamp: newTime, field: field)
        try j.verifyMessageHistory(j.ownedChat("caregiver")); try j.chatWorkflowComplete()
        try ordinaryMain(j); try openExactPeerFromActualMatches(j); try profileState("active", j: j)
        try confirmMutation("unmatch", j: j); try assertCurrentNoneAndHistory(j)
        try ordinaryMain(j); try closedOwnedConversation(j)
        try signIn("caregiver", journal: j)
        try openExactPeerFromActualMatches(j); try profileState("none", j: j)
        try assertCurrentNoneAndHistory(j)
        try ordinaryMain(j); try closedOwnedConversation(j)
    }
    private func closedOwnedConversation(_ j: Guard) throws {
        let row = try exactConversationRow(j, unread: nil); row.tap()
        let field = try composer(allowDisabled: true)
        let note = app.descendants(matching: .any)["chat-closed-note"].firstMatch
        try Guard.require(note.waitForExistence(timeout: 45) && field.exists && !field.isEnabled
            && app.buttons["Send"].exists && !app.buttons["Send"].isEnabled, "ended-owned-chat-must-be-readable-but-not-sendable")
        try Guard.require(note.label.contains(text("chat_screen_match_check", "You can only send messages to your current matches.")), "exact-managed-ended-chat-note")
        try j.verifyMessageHistory(j.ownedChat(activeRole))
        try capture("\(activeRole)-ended-chat-disabled-composer-and-retained-history", element: app)
        try writes(expectedWrites)
    }

}
