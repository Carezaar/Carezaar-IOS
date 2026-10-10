import Foundation

struct Review: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let reviewer: UserTiny?
    let score: Int
    let comment: String?
    let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, reviewer, score, comment
        case createdAt = "created_at"
    }
}

/// The core domain object. There is no status enum on the wire — the lifecycle is
/// derived from the two acceptance flags, `isActive` and `finishedAt`.
struct Match: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let client: ClientBrief?
    let caregiver: CaregiverBrief?
    let clientReview: Review?
    let caregiverReview: Review?
    let createdAt: String?
    let finishedAt: String?
    let isClientAccepted: Bool
    let isCaregiverAccepted: Bool
    let isActive: Bool
    /// The requester's optional note, sent with `POST users/matches`.
    let introduction: String?

    private enum CodingKeys: String, CodingKey {
        case id, client, caregiver, introduction
        case clientReview = "review_client"
        case caregiverReview = "review_caregiver"
        case createdAt = "created_at"
        case finishedAt = "finished_at"
        case isClientAccepted = "is_client_accepted"
        case isCaregiverAccepted = "is_caregiver_accepted"
        case isActive = "is_active"
    }

    /// Which list tab this match belongs to. Mirrors `match_tab_matches`,
    /// `match_tab_requests` and `match_tab_history`.
    enum Stage { case active, pending, history }

    /// An open request arrives with `is_active: false` (verified live), so only
    /// `finished_at` marks a match as ended.
    var stage: Stage {
        if finishedAt != nil { return .history }
        return (isClientAccepted && isCaregiverAccepted) ? .active : .pending
    }

    /// True when the signed-in role still has to answer an incoming request.
    func awaitsResponse(from role: UserRole) -> Bool {
        guard stage == .pending else { return false }
        return role == .client ? !isClientAccepted : !isCaregiverAccepted
    }

    /// True when this role has already asked and is waiting on the other side.
    func awaitsPartner(for role: UserRole) -> Bool {
        guard stage == .pending else { return false }
        return role == .client ? (isClientAccepted && !isCaregiverAccepted)
                               : (isCaregiverAccepted && !isClientAccepted)
    }

    /// The review this role has written. The wire fields name the party being
    /// reviewed: a client's review of the caregiver lives in `review_caregiver`
    /// (verified live: its reviewer is the client).
    func review(by role: UserRole) -> Review? {
        role == .client ? caregiverReview : clientReview
    }
}

/// Query value for `GET users/matches?type=`.
enum MatchListType: String, Sendable {
    case matches
    case requests
    case histories
}

/// Query value for `GET clients|caregivers/matches?sort=`. The parameter is
/// required, and the backend only accepts these two values; Android defaults to
/// `distance`.
enum MatchSort: String, CaseIterable, Sendable {
    case distance, pay

    var title: String { self == .distance ? "Distance" : "Pay rate" }
}

extension Review {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        reviewer = c.lenient(.reviewer)
        score = c.lenient(.score, default: 0)
        comment = c.lenient(.comment)
        createdAt = c.lenient(.createdAt)
    }
}

extension Match {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        client = c.lenient(.client)
        caregiver = c.lenient(.caregiver)
        clientReview = c.lenient(.clientReview)
        caregiverReview = c.lenient(.caregiverReview)
        createdAt = c.lenient(.createdAt)
        finishedAt = c.lenient(.finishedAt)
        isClientAccepted = c.lenient(.isClientAccepted, default: false)
        isCaregiverAccepted = c.lenient(.isCaregiverAccepted, default: false)
        isActive = c.lenient(.isActive, default: false)
        introduction = c.lenient(.introduction)
    }
}
