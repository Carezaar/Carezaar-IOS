import Foundation

/// The lookup tables cached on bootstrap. Raw values are the `base/` path segments.
enum BaseTable: String, CaseIterable, Sendable {
    case careconditions, caredays, carespecials, certifications, clienttypes, commutes
    case contents, countries, experiences, genders, issuetypes, languageskills
    case reasons, roles, shifts, subjects, worktypes
}

/// `base/` — mirrors the Android `um` interface. Every call carries `ts_cache`.
///
/// The OpenAPI spec marks most of this group as requiring a bearer token, but the
/// deployed backend serves every `base/` table unauthenticated (verified against
/// all 23 endpoints). They are therefore requested without auth so the form pickers
/// can be populated during onboarding, before a session exists.
struct BaseService: Sendable {
    let client: APIClient

    init(client: APIClient = .shared) { self.client = client }

    func info() async throws -> BaseInfo {
        try await client.send(Endpoint(method: .get, path: "base/info", query: ["ts_cache": "0"], requiresAuth: false))
    }

    /// Fetches one translated lookup table.
    func items(_ table: BaseTable, tsCache: Int = 0) async throws -> [BaseItem] {
        try await client.send(
            Endpoint(method: .get, path: "base/\(table.rawValue)", query: ["ts_cache": String(tsCache)], requiresAuth: false)
        )
    }

    func languages(tsCache: Int = 0) async throws -> [Language] {
        try await client.send(Endpoint(method: .get, path: "base/languages",
                                       query: ["ts_cache": String(tsCache)], requiresAuth: false))
    }

    /// `base/cities` requires `language_id` and `state_id` — both mandatory per the
    /// spec, and the endpoint 422s without them. The Android client never calls it
    /// (there is no `cities` method on its base interface), so this has no Kotlin
    /// behaviour to mirror; it is provided for a state-scoped city picker.
    func cities(stateId: Int, languageId: Int) async throws -> [City] {
        try await client.send(Endpoint(method: .get, path: "base/cities",
                                       query: ["state_id": String(stateId),
                                               "language_id": String(languageId)],
                                       requiresAuth: false))
    }

    /// The only base endpoint the spec marks public that the Android client uses.
    func states(tsCache: Int = 0) async throws -> [USState] {
        try await client.send(Endpoint(method: .get, path: "base/states",
                                       query: ["ts_cache": String(tsCache)], requiresAuth: false))
    }

    func faqs(tsCache: Int = 0) async throws -> [Faq] {
        try await client.send(Endpoint(method: .get, path: "base/faqs",
                                       query: ["ts_cache": String(tsCache)], requiresAuth: false))
    }

    func faqCategories(tsCache: Int = 0) async throws -> [FaqCategory] {
        try await client.send(Endpoint(method: .get, path: "base/faq_categories",
                                       query: ["ts_cache": String(tsCache)], requiresAuth: false))
    }
}
