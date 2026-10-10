import Foundation

/// Every Carezaar response is wrapped in this envelope.
/// Verified live: `{ "result": ..., "meta": ..., "message": "...", "errors": ... }`
struct APIEnvelope<T: Decodable>: Decodable {
    let result: T?
    let meta: APIMeta?
    let message: String?
    let errors: [String: [String]]?

    /// Used for `204 No Content`, which several write endpoints (e.g. `users/otp/send`)
    /// answer with an empty body rather than the envelope.
    static var empty: APIEnvelope<T> {
        APIEnvelope(result: nil, meta: nil, message: nil, errors: nil)
    }

    init(result: T?, meta: APIMeta?, message: String?, errors: [String: [String]]?) {
        self.result = result
        self.meta = meta
        self.message = message
        self.errors = errors
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = try c.decodeIfPresent(T.self, forKey: .result)
        meta = try c.decodeIfPresent(APIMeta.self, forKey: .meta)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        errors = try c.decodeIfPresent([String: [String]].self, forKey: .errors)
    }

    private enum CodingKeys: String, CodingKey { case result, meta, message, errors }
}

/// Pagination block returned alongside paged collections.
struct APIMeta: Decodable {
    let currentPage: Int?
    let lastPage: Int?
    let perPage: Int?
    let total: Int?

    private enum CodingKeys: String, CodingKey {
        case currentPage = "current_page"
        case lastPage = "last_page"
        case perPage = "per_page"
        case total
    }
}

/// Empty payload for endpoints whose `result` carries no data.
struct EmptyPayload: Decodable {}

extension KeyedDecodingContainer {
    /// For fields the app can do without: a missing, null or mistyped value takes the
    /// default instead of failing the whole response (and with it a list or screen).
    /// Identity fields (`id`, `user`, `role`) stay strict.
    func lenient<T: Decodable>(_ key: Key, default value: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? value
    }

    func lenient<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
