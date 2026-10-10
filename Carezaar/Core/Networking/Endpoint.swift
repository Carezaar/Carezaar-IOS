import Foundation

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
}
