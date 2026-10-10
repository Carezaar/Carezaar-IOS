import Foundation

struct AppNotification: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let user: User?
    let partner: User?
    let chat: ChatBrief?
    /// Joins to `base/subjects`, which supplies the translated notification text.
    let subjectId: Int
    let createdAt: String?
    let seenAt: String?

    var isSeen: Bool { seenAt != nil }

    private enum CodingKeys: String, CodingKey {
        case id, user, partner, chat
        case subjectId = "subject_id"
        case createdAt = "created_at"
        case seenAt = "seen_at"
    }
}

struct Issue: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let issuetypeId: Int?
    let title: String?
    let description: String?
    let reply: String?
    let createdAt: String?
    let repliedAt: String?
    let isReplied: Bool

    /// `report_an_issue_status_pending` / `_resolved`.
    var isResolved: Bool { isReplied }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, reply
        case issuetypeId = "issuetype_id"
        case createdAt = "created_at"
        case repliedAt = "replied_at"
        case isReplied = "is_replied"
    }
}
