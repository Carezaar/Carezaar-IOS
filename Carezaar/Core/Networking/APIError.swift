import Foundation

/// Mirrors the Android client's error string resources:
/// error_unauthorized / error_forbidden / error_not_found / error_server / error_unknown.
enum APIError: Error, Equatable {
    /// 403 — "Valid JWT token is required!". The backend uses 403, *not* 401, for a
    /// missing or expired token, so this is the case that must drive token refresh.
    case unauthenticated(String)
    /// 403 on a freshly renewed, valid session: this request is not allowed (for example the
    /// other role's screen). Not a session problem — the user stays signed in, as on the web.
    case forbidden(String)
    /// 422 — field validation failures keyed by field name.
    case validation(message: String, fields: [String: [String]])
    case notFound(String)
    case server(String)
    /// The transport establishes that no connection was made; deliberate retry is safe.
    case connectionUnavailable
    case network(String)
    case timeout
    case decoding(String)
    case unknown(String)

    /// Common display copy has one managed resolver; raw service diagnostics are
    /// available separately for classification and never become a second UI path.
    @MainActor
    var message: String { Feedback.message(self) }

    /// The server's own text, when it has one.
    var serverMessage: String {
        switch self {
        case .unauthenticated(let m), .forbidden(let m), .notFound(let m), .server(let m), .unknown(let m), .decoding(let m): return m
        case .validation(let m, _): return m
        case .connectionUnavailable, .network, .timeout: return ""
        }
    }

    /// The request never got an answer from the server (no connection, dropped
    /// connection, timeout), as opposed to the server answering with an error.
    var isUnreachable: Bool {
        switch self {
        case .network, .timeout, .connectionUnavailable: return true
        default: return false
        }
    }

    /// The server's message is an implementation detail (a PHP notice, a missing
    /// route) rather than something written for people.
    var isTechnical: Bool {
        serverMessage.range(of: #"undefined (array key|index|offset|variable|property)|array key|exception|sqlstate|stack trace|call to (a )?(member|undefined)|route .* could not be found|method is not supported|\.php|symfony|laravel|syntax error|null given"#,
                            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The server could not perform the action at all, as opposed to rejecting input.
    var isServiceFault: Bool {
        switch self {
        case .server, .notFound: return true
        default: return isTechnical
        }
    }

    /// First validation message for a given field, for inline form errors.
    func fieldError(_ field: String) -> String? {
        guard case .validation(_, let fields) = self else { return nil }
        return fields[field]?.first
    }
}

/// `auth/login` answered 409: the account's email is verified but sign-up was never
/// finished (no profile and/or no client/caregiver entity). Android shows the
/// server's message and opens the profile step of sign-up (parity review v3, B1).
struct RegistrationIncompleteError: Error, Equatable {
    let message: String
    let role: UserRole?
}

/// The original protected write was explicitly refused before renewal failed.
/// Its cause retains the managed error category, while reconciliation must not
/// treat that refusal as a possibly committed mutation.
struct AuthorizationRejectedMutationError: Error {
    let cause: APIError
}

/// Shared transport evidence for writes in every feature.
enum MutationOutcome {
    static func mayHaveCommitted(_ error: Error) -> Bool {
        if error is CancellationError || error is AuthorizationRejectedMutationError { return false }
        guard let api = error as? APIError else { return true }
        switch api {
        case .validation, .notFound, .unauthenticated, .forbidden, .connectionUnavailable: return false
        case .network, .timeout, .decoding, .server, .unknown: return true
        }
    }
}
