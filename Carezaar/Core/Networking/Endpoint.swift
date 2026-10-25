import Foundation
import CryptoKit

enum HTTPMethod: String {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
}

/// Request body encodings actually used by the Android client.
/// Every write is form-urlencoded except `users/profile`, which is multipart.
enum RequestBody {
    case none
    /// `application/x-www-form-urlencoded`. Nil values are omitted, matching Retrofit's
    /// behaviour for nullable `@Field` parameters.
    case form([String: FormValue?])
    /// `multipart/form-data` with optional file part.
    case multipart(fields: [String: String?], file: MultipartFile?)
}

/// A form field value. Multi-select ids are sent as a comma-joined string
/// (`"1,4,9"`), which is how the Android client encodes `*_ids` parameters.
enum FormValue {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case ids([Int])

    var encoded: String {
        switch self {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return v ? "1" : "0"
        case .ids(let v): return v.map(String.init).joined(separator: ",")
        }
    }
}

struct MultipartFile {
    let name: String
    let filename: String
    let mimeType: String
    let data: Data
}

struct Endpoint {
    let method: HTTPMethod
    /// Path relative to `https://new.carezaar.com/api/`, e.g. `users/matches/12/accept`.
    let path: String
    var query: [String: String?] = [:]
    var body: RequestBody = .none
    /// Endpoints reachable without a bearer token: `base/cities`, `base/states`,
    /// `users/otp/send`, `users/otp/verify`, `auth/login`, `auth/register`.
    var requiresAuth: Bool = true
    /// `Idempotency-Key` for one logical submission (see IdempotencyStore). The same endpoint
    /// value is replayed after a renewed sign-in, so the key stays the same.
    var idempotencyKey: String? = nil
}

// MARK: - Idempotency (client request, 25 Oct 2026)


/// `Idempotency-Key` for the three writes the client named: `POST users/chats/{id}` (send a
/// message), `POST users/issues` (report an issue) and `POST users/matches` (request a match).
///
/// Live API contract (verified 25 Oct 2026 with the QA accounts, web-qa/idem-probe.mjs):
/// the key must be a UUID (otherwise 422 `idempotency_invalid`); the same key with the same
/// request replays the first answer (`Idempotency-Replayed: true`) and creates nothing, also
/// for two at once; the same key with different data is 409 `idempotency_conflict`; keys are
/// per account; an expired key is 409 `idempotency_expired`.
///
/// One key per logical submission, kept in UserDefaults (scoped by account, operation, target
/// and a hash of the data) until the outcome is known, so a retry after a timeout, a lost
/// connection, a renewed sign-in, an app restart or another visit to the screen sends the same
/// key. A confirmed success, or an answer proving the request was not carried out, retires it;
/// the next submission (even with identical text) gets a new key. An uncertain outcome keeps
/// it: a request is never repeated with a new key on a guess.
enum IdempotentOperation: String, Codable, Sendable {
    case chatMessage = "chat_message", issue, matchRequest = "match_request"
}

struct PendingSubmission: Codable, Equatable, Sendable {
    let key: String
    let created: Date
    let account: String
    let operation: IdempotentOperation
    let target: String
    /// What the person submitted, so the screen can offer it again after a restart.
    var draft: String?
    /// Newest record id known when the submission began, for reconciliation.
    var after: Int?
    /// The message replied to, for a chat message.
    var parent: Int?
}

/// The server's 409 for a key: `idempotency_conflict` or `idempotency_expired`.
struct IdempotencyServerError: Error, Equatable { let code: String }
/// Same key, different data: not resent, and not resent with a new key either.
struct IdempotencyConflictError: Error, Equatable {}
/// The server forgot the key and the resource shows the earlier attempt was not carried out.
struct SubmissionNotCarriedOutError: Error, Equatable {}

@MainActor
final class IdempotencyStore {
    static let shared = IdempotencyStore()
    static let storageKey = "carezaar.pendingSubmissions.v1"
    /// Kept for a day; the server forgets keys sooner, which it reports as expired.
    static let maxAge: TimeInterval = 24 * 60 * 60

    /// The signed-in account submissions are scoped to (set by the session).
    var account: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var accountKey: String { account ?? "signed-out" }

    private func readAll() -> [String: PendingSubmission] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let all = try? JSONDecoder().decode([String: PendingSubmission].self, from: data) else { return [:] }
        let now = Date()
        return all.filter { now.timeIntervalSince($0.value.created) < Self.maxAge }
    }

    private func writeAll(_ all: [String: PendingSubmission]) {
        defaults.set(try? JSONEncoder().encode(all), forKey: Self.storageKey)
    }

    /// A stable hash of the request data (SHA-256 of the sorted fields).
    static func payloadHash(_ form: [String: FormValue?]) -> String {
        let canonical = form.compactMap { key, value in value.map { "\(key)=\($0.encoded)" } }.sorted().joined(separator: "&")
        return SHA256.hash(data: Data(canonical.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func scope(_ operation: IdempotentOperation, _ target: String, _ form: [String: FormValue?]) -> String {
        "\(accountKey)|\(operation.rawValue)|\(target)|\(Self.payloadHash(form))"
    }

    /// The unresolved submissions of the signed-in account for one operation and target, newest first.
    func pending(_ operation: IdempotentOperation, target: String) -> [PendingSubmission] {
        readAll().values.filter { $0.account == accountKey && $0.operation == operation && $0.target == target }
            .sorted { $0.created > $1.created }
    }

    /// Retires every unresolved submission for an operation and target, once the resource
    /// shows how it ended (e.g. the profile shows the request as sent).
    func retireAll(_ operation: IdempotentOperation, target: String) {
        writeAll(readAll().filter { !($0.value.account == accountKey && $0.value.operation == operation && $0.value.target == target) })
    }

    func clearAll() { defaults.removeObject(forKey: Self.storageKey) }

    /// True when the answer proves the request was not carried out (or was refused for good).
    /// No answer, a timeout or a server error is uncertain.
    nonisolated static func isDefinitive(_ error: Error) -> Bool {
        if error is IdempotencyConflictError || error is SubmissionNotCarriedOutError { return true }
        if error is IdempotencyServerError { return (error as? IdempotencyServerError)?.code == "idempotency_conflict" }
        if error is AuthorizationRejectedMutationError { return true }
        guard let api = error as? APIError else { return false }
        switch api {
        case .validation, .forbidden, .notFound, .unknown, .unauthenticated: return true
        case .server, .connectionUnavailable, .network, .timeout, .decoding: return false
        }
    }

    /// Sends one logical submission with its key: a new one, or the same one again while its
    /// earlier attempt is unresolved.
    func submit<T>(_ operation: IdempotentOperation, target: String, form: [String: FormValue?],
                   draft: String? = nil, after: Int? = nil, parent: Int? = nil,
                   send: (String) async throws -> T,
                   reconcile: ((PendingSubmission) async throws -> T?)? = nil) async throws -> T {
        let scope = scope(operation, target, form)
        var all = readAll()
        let record = all[scope] ?? PendingSubmission(key: UUID().uuidString.lowercased(), created: Date(), account: accountKey,
                                                     operation: operation, target: target, draft: draft, after: after, parent: parent)
        all[scope] = record
        writeAll(all)
        func retire() { var now = readAll(); now.removeValue(forKey: scope); writeAll(now) }
        do {
            let result = try await send(record.key)
            retire()
            return result
        } catch let error as IdempotencyServerError where error.code == "idempotency_expired" {
            // The server no longer knows this key: find out whether the earlier attempt went
            // through before anything is sent again. A failed check leaves the key in place.
            let found = try await reconcile?(record) ?? nil
            retire()
            if let found { return found }
            throw SubmissionNotCarriedOutError()
        } catch let error as IdempotencyServerError where error.code == "idempotency_conflict" {
            retire()
            throw IdempotencyConflictError()
        } catch {
            if Self.isDefinitive(error) { retire() }
            throw error
        }
    }
}
