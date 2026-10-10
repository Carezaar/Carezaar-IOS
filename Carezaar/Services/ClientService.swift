import Foundation

/// Care preferences a client submits. All selections are multi-value.
struct ClientPreferences: Sendable {
    var clienttypeId: Int
    var lat: Double
    var lng: Double
    var salaryMin: Int?
    var salaryMax: Int?
    var careconditionIds: [Int] = []
    var caredayIds: [Int] = []
    var carespecialIds: [Int] = []
    var certificationIds: [Int] = []
    var commuteIds: [Int] = []
    var experienceIds: [Int] = []
    var genderIds: [Int] = []
    var languageskillIds: [Int] = []
    var roleIds: [Int] = []
    var shiftIds: [Int] = []
    var worktypeIds: [Int] = []
}

/// `clients/` — mirrors the Android `g30` interface.
struct ClientService: Sendable {
    let client: APIClient

    init(client: APIClient = .shared) { self.client = client }

    func profile() async throws -> ClientFull {
        try await client.send(Endpoint(method: .get, path: "clients/profile"))
    }

    /// Creates the client entity at the end of signup.
    func create(userId: String, preferences p: ClientPreferences) async throws -> ClientFull {
        var fields = Self.sharedFields(p)
        fields["user_id"] = .string(userId)
        // Create uses snake_case here.
        fields["certification_ids"] = .ids(p.certificationIds)
        // Final signup step, before any session exists: keyed by `user_id`. The
        // account only becomes able to sign in once this entity exists (verified live).
        return try await client.send(
            Endpoint(method: .post, path: "clients", body: .form(fields), requiresAuth: false)
        )
    }

    /// Updates preferences.
    ///
    /// The backend expects **`certificationIds`** in camelCase on this endpoint while
    /// the create endpoint above expects `certification_ids` — an asymmetry carried
    /// over from the Android client, where sending only snake_case silently drops the
    /// field.
    ///
    /// Both spellings are sent. Today the camelCase one is read and the other is
    /// ignored; if the backend ever corrects the typo this keeps working instead of
    /// breaking silently. Flagged to Carezaar either way.
    func updateProfile(_ p: ClientPreferences) async throws -> ClientFull {
        var fields = Self.sharedFields(p)
        fields["certificationIds"] = .ids(p.certificationIds)
        fields["certification_ids"] = .ids(p.certificationIds)
        return try await client.send(
            Endpoint(method: .put, path: "clients/profile", body: .form(fields))
        )
    }

    /// Caregivers matched to this client's preferences.
    func matches(sort: MatchSort = .distance, page: Int = 1,
                 perPage: Int = APIConfiguration.defaultPageSize) async throws -> ([CaregiverBrief], APIMeta?) {
        try await client.sendPaged(
            Endpoint(method: .get, path: "clients/matches",
                     query: ["sort": sort.rawValue, "page": String(page), "perPage": String(perPage)])
        )
    }

    func caregiver(id: String) async throws -> CaregiverFull {
        try await client.send(Endpoint(method: .get, path: "clients/caregivers/\(id)"))
    }

    private static func sharedFields(_ p: ClientPreferences) -> [String: FormValue?] {
        ["clienttype_id": .int(p.clienttypeId),
         "lat": .double(p.lat),
         "lng": .double(p.lng),
         "salary_min": p.salaryMin.map { .int($0) } ?? nil,
         "salary_max": p.salaryMax.map { .int($0) } ?? nil,
         "carecondition_ids": .ids(p.careconditionIds),
         "careday_ids": .ids(p.caredayIds),
         "carespecial_ids": .ids(p.carespecialIds),
         "commute_ids": .ids(p.commuteIds),
         "experience_ids": .ids(p.experienceIds),
         "gender_ids": .ids(p.genderIds),
         "languageskill_ids": .ids(p.languageskillIds),
         "role_ids": .ids(p.roleIds),
         "shift_ids": .ids(p.shiftIds),
         "worktype_ids": .ids(p.worktypeIds)]
    }
}
