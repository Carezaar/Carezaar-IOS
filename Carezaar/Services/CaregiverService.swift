import Foundation

/// Skills a caregiver submits. Commute, experience, role and worktype are
/// single-select here, unlike the client side.
struct CaregiverSkills: Sendable {
    var commuteId: Int
    var experienceId: Int
    var roleId: Int
    var worktypeId: Int
    var lat: Double
    var lng: Double
    var salaryMin: Int
    var salaryMax: Int
    var careconditionIds: [Int] = []
    var caredayIds: [Int] = []
    var carespecialIds: [Int] = []
    var certificationIds: [Int] = []
    var clienttypeIds: [Int] = []
    var languageskillIds: [Int] = []
    var shiftIds: [Int] = []
}

/// `caregivers/` — mirrors the Android `zv` interface.
struct CaregiverService: Sendable {
    let client: APIClient

    init(client: APIClient = .shared) { self.client = client }

    func profile() async throws -> CaregiverFull {
        try await client.send(Endpoint(method: .get, path: "caregivers/profile"))
    }

    func create(userId: String, skills s: CaregiverSkills) async throws -> CaregiverFull {
        var fields = Self.sharedFields(s)
        fields["user_id"] = .string(userId)
        // Final signup step, before any session exists: keyed by `user_id`.
        return try await client.send(
            Endpoint(method: .post, path: "caregivers", body: .form(fields), requiresAuth: false)
        )
    }

    /// Unlike the client service, both create and update use `certification_ids`.
    func updateProfile(_ s: CaregiverSkills) async throws -> CaregiverFull {
        try await client.send(
            Endpoint(method: .put, path: "caregivers/profile", body: .form(Self.sharedFields(s)))
        )
    }

    /// Clients matched to this caregiver's services.
    func matches(sort: MatchSort = .distance, page: Int = 1,
                 perPage: Int = APIConfiguration.defaultPageSize) async throws -> ([ClientBrief], APIMeta?) {
        try await client.sendPaged(
            Endpoint(method: .get, path: "caregivers/matches",
                     query: ["sort": sort.rawValue, "page": String(page), "perPage": String(perPage)])
        )
    }

    func client(id: String) async throws -> ClientFull {
        try await client.send(Endpoint(method: .get, path: "caregivers/clients/\(id)"))
    }

    private static func sharedFields(_ s: CaregiverSkills) -> [String: FormValue?] {
        ["commute_id": .int(s.commuteId),
         "experience_id": .int(s.experienceId),
         "role_id": .int(s.roleId),
         "worktype_id": .int(s.worktypeId),
         "lat": .double(s.lat),
         "lng": .double(s.lng),
         "salary_min": .int(s.salaryMin),
         "salary_max": .int(s.salaryMax),
         "carecondition_ids": .ids(s.careconditionIds),
         "careday_ids": .ids(s.caredayIds),
         "carespecial_ids": .ids(s.carespecialIds),
         "certification_ids": .ids(s.certificationIds),
         "clienttype_ids": .ids(s.clienttypeIds),
         "languageskill_ids": .ids(s.languageskillIds),
         "shift_ids": .ids(s.shiftIds)]
    }
}
