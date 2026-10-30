import Foundation

/// Caregiver listing card (`clients/matches` returns these).
struct CaregiverBrief: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let user: User
    let salaryMin: Int?
    let salaryMax: Int?
    /// Miles from the viewer, rendered as `general_miles_away`.
    let distance: Double?
    let isMatch: Bool

    private enum CodingKeys: String, CodingKey {
        case id, user, distance
        case salaryMin = "salary_min"
        case salaryMax = "salary_max"
        case isMatch = "is_match"
    }
}

/// Caregiver skills. Note the single-select ids — a caregiver picks one commute,
/// experience, role and worktype, unlike a client which multi-selects all four.
struct CaregiverFull: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var user: User
    let commuteId: Int?
    let experienceId: Int?
    let roleId: Int?
    let worktypeId: Int?
    let lat: Double?
    let lng: Double?
    let salaryMin: Int?
    let salaryMax: Int?
    let distance: Double?
    let careconditionIds: [Int]
    let caredayIds: [Int]
    let carespecialIds: [Int]
    let certificationIds: [Int]
    let clienttypeIds: [Int]
    let languageskillIds: [Int]
    let shiftIds: [Int]
    var isMatch: Bool
    var matchStatus: String?
    var matchId: Int?
    let matchIntroduction: String?

    private enum CodingKeys: String, CodingKey {
        case id, user, lat, lng, distance
        case commuteId = "commute_id"
        case experienceId = "experience_id"
        case roleId = "role_id"
        case worktypeId = "worktype_id"
        case salaryMin = "salary_min"
        case salaryMax = "salary_max"
        case careconditionIds = "carecondition_ids"
        case caredayIds = "careday_ids"
        case carespecialIds = "carespecial_ids"
        case certificationIds = "certification_ids"
        case clienttypeIds = "clienttype_ids"
        case languageskillIds = "languageskill_ids"
        case shiftIds = "shift_ids"
        case isMatch = "is_match"
        case matchStatus = "match_status"
        case matchId = "match_id"
        case matchIntroduction = "match_introduction"
    }
}

/// Client listing card (`caregivers/matches` returns these).
struct ClientBrief: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let user: User
    let clienttypeId: Int?
    let lat: Double?
    let lng: Double?
    let salaryMin: Int?
    let salaryMax: Int?
    let distance: Double?
    let isMatch: Bool

    private enum CodingKeys: String, CodingKey {
        case id, user, lat, lng, distance
        case clienttypeId = "clienttype_id"
        case salaryMin = "salary_min"
        case salaryMax = "salary_max"
        case isMatch = "is_match"
    }
}

/// Client care preferences — all multi-select, plus `gender_ids` which the
/// caregiver profile does not have.
struct ClientFull: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var user: User
    let clienttypeId: Int?
    let lat: Double?
    let lng: Double?
    let salaryMin: Int?
    let salaryMax: Int?
    let distance: Double?
    let careconditionIds: [Int]
    let caredayIds: [Int]
    let carespecialIds: [Int]
    let certificationIds: [Int]
    let commuteIds: [Int]
    let experienceIds: [Int]
    let genderIds: [Int]
    let languageskillIds: [Int]
    let roleIds: [Int]
    let shiftIds: [Int]
    let worktypeIds: [Int]
    var isMatch: Bool
    var matchStatus: String?
    var matchId: Int?
    let matchIntroduction: String?

    private enum CodingKeys: String, CodingKey {
        case id, user, lat, lng, distance
        case clienttypeId = "clienttype_id"
        case salaryMin = "salary_min"
        case salaryMax = "salary_max"
        case careconditionIds = "carecondition_ids"
        case caredayIds = "careday_ids"
        case carespecialIds = "carespecial_ids"
        case certificationIds = "certification_ids"
        case commuteIds = "commute_ids"
        case experienceIds = "experience_ids"
        case genderIds = "gender_ids"
        case languageskillIds = "languageskill_ids"
        case roleIds = "role_ids"
        case shiftIds = "shift_ids"
        case worktypeIds = "worktype_ids"
        case isMatch = "is_match"
        case matchStatus = "match_status"
        case matchId = "match_id"
        case matchIntroduction = "match_introduction"
    }
}

extension CaregiverFull {
    func with(user: User) -> CaregiverFull { var copy = self; copy.user = user; return copy }
}

extension ClientFull {
    func with(user: User) -> ClientFull { var copy = self; copy.user = user; return copy }
}

extension CaregiverBrief {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        user = try c.decode(User.self, forKey: .user)
        salaryMin = c.lenient(.salaryMin)
        salaryMax = c.lenient(.salaryMax)
        distance = c.lenient(.distance)
        isMatch = c.lenient(.isMatch, default: false)
    }
}

extension ClientBrief {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        user = try c.decode(User.self, forKey: .user)
        clienttypeId = c.lenient(.clienttypeId)
        lat = c.lenient(.lat)
        lng = c.lenient(.lng)
        salaryMin = c.lenient(.salaryMin)
        salaryMax = c.lenient(.salaryMax)
        distance = c.lenient(.distance)
        isMatch = c.lenient(.isMatch, default: false)
    }
}

extension CaregiverFull {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        user = try c.decode(User.self, forKey: .user)
        commuteId = c.lenient(.commuteId)
        experienceId = c.lenient(.experienceId)
        roleId = c.lenient(.roleId)
        worktypeId = c.lenient(.worktypeId)
        lat = c.lenient(.lat)
        lng = c.lenient(.lng)
        salaryMin = c.lenient(.salaryMin)
        salaryMax = c.lenient(.salaryMax)
        distance = c.lenient(.distance)
        careconditionIds = c.lenient(.careconditionIds, default: [])
        caredayIds = c.lenient(.caredayIds, default: [])
        carespecialIds = c.lenient(.carespecialIds, default: [])
        certificationIds = c.lenient(.certificationIds, default: [])
        clienttypeIds = c.lenient(.clienttypeIds, default: [])
        languageskillIds = c.lenient(.languageskillIds, default: [])
        shiftIds = c.lenient(.shiftIds, default: [])
        isMatch = c.lenient(.isMatch, default: false)
        matchStatus = c.lenient(.matchStatus)
        matchId = c.lenient(.matchId)
        matchIntroduction = c.lenient(.matchIntroduction)
    }
}

extension ClientFull {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        user = try c.decode(User.self, forKey: .user)
        clienttypeId = c.lenient(.clienttypeId)
        lat = c.lenient(.lat)
        lng = c.lenient(.lng)
        salaryMin = c.lenient(.salaryMin)
        salaryMax = c.lenient(.salaryMax)
        distance = c.lenient(.distance)
        careconditionIds = c.lenient(.careconditionIds, default: [])
        caredayIds = c.lenient(.caredayIds, default: [])
        carespecialIds = c.lenient(.carespecialIds, default: [])
        certificationIds = c.lenient(.certificationIds, default: [])
        commuteIds = c.lenient(.commuteIds, default: [])
        experienceIds = c.lenient(.experienceIds, default: [])
        genderIds = c.lenient(.genderIds, default: [])
        languageskillIds = c.lenient(.languageskillIds, default: [])
        roleIds = c.lenient(.roleIds, default: [])
        shiftIds = c.lenient(.shiftIds, default: [])
        worktypeIds = c.lenient(.worktypeIds, default: [])
        isMatch = c.lenient(.isMatch, default: false)
        matchStatus = c.lenient(.matchStatus)
        matchId = c.lenient(.matchId)
        matchIntroduction = c.lenient(.matchIntroduction)
    }
}

/// Where the viewer stands with the profile's person, from the profile response itself
/// (`match_status`, `match_id`). `match_id` names the connection in every state but
/// `none`, so it never decides the state on its own.
enum ProfileMatchStatus: String, Sendable { case none, sent, received, active }

struct ProfileMatchState: Hashable, Sendable {
    let status: ProfileMatchStatus
    /// Nil only for `none`.
    let id: Int?

    /// Nil when the fields are missing or contradict each other (a status without its
    /// id, or `none` with one): the profile offers no action until it is re-read.
    init?(status raw: String?, id: Int?) {
        guard let raw, let status = ProfileMatchStatus(rawValue: raw) else { return nil }
        if status == .none {
            guard id == nil else { return nil }
        } else {
            guard let id, id > 0 else { return nil }
        }
        self.status = status
        self.id = id
    }
}

extension CaregiverFull {
    var matchState: ProfileMatchState? { ProfileMatchState(status: matchStatus, id: matchId) }
}

extension ClientFull {
    var matchState: ProfileMatchState? { ProfileMatchState(status: matchStatus, id: matchId) }
}

extension CaregiverFull {
    func with(matchStatus: String, matchId: Int?) -> Self {
        var copy = self; copy.matchStatus = matchStatus; copy.matchId = matchId; copy.isMatch = matchStatus == "active"; return copy
    }
}
extension ClientFull {
    func with(matchStatus: String, matchId: Int?) -> Self {
        var copy = self; copy.matchStatus = matchStatus; copy.matchId = matchId; copy.isMatch = matchStatus == "active"; return copy
    }
}
