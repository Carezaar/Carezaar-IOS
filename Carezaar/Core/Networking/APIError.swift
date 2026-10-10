import Foundation

/// Mirrors the Android client's error string resources:
/// error_unauthorized / error_forbidden / error_not_found / error_server / error_unknown.
enum APIError: Error, Equatable {
    /// 403 — "Valid JWT token is required!". The backend uses 403, *not* 401, for a
    /// missing or expired token, so this is the case that must drive token refresh.
    case unauthenticated(String)
    /// 422 — field validation failures keyed by field name.
    case validation(message: String, fields: [String: [String]])
    case notFound(String)
    case server(String)
    case network(String)
    case timeout
    case decoding(String)
    case unknown(String)

    /// User-facing message, matching the Android copy contract.
    var message: String {
        switch self {
        case .unauthenticated(let m): return m.isEmpty ? "Your session has expired. Please sign in again." : m
        case .validation(let m, _): return m
        case .notFound(let m): return m.isEmpty ? "Not found." : m
        case .server(let m): return m.isEmpty ? "Something went wrong on our end." : m
        case .network: return "No internet connection. Please try again."
        case .timeout: return "The server is taking too long to respond. Please try again."
        case .decoding: return "Unexpected response from the server."
        case .unknown(let m): return m.isEmpty ? "Something went wrong." : m
        }
    }

    /// The server's own text, when it has one.
    var serverMessage: String {
        switch self {
        case .unauthenticated(let m), .notFound(let m), .server(let m), .unknown(let m), .decoding(let m): return m
        case .validation(let m, _): return m
        case .network, .timeout: return ""
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
