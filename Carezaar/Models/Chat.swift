import Foundation

struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    /// Threaded reply target. `POST users/chats/{id}` sends this back as `parent_id`.
    let parent: Box<ChatMessage>?
    let message: String
    let createdAt: String?
    let updatedAt: String?
    let seenAt: String?
    /// The wire tells you which side sent it, not a user id.
    let isFromCaregiver: Bool

    private enum CodingKeys: String, CodingKey {
        case id, parent, message
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case seenAt = "seen_at"
        case isFromCaregiver = "is_from_caregiver"
    }

    /// True when this message belongs to the signed-in user.
    func isMine(role: UserRole) -> Bool {
        role == .caregiver ? isFromCaregiver : !isFromCaregiver
    }
}

/// Indirection so `ChatMessage` can reference itself without an infinite-size struct.
final class Box<T: Codable & Hashable & Sendable>: Codable, Hashable, @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
    init(from decoder: Decoder) throws {
        value = try T(from: decoder)
    }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    static func == (lhs: Box<T>, rhs: Box<T>) -> Bool { lhs.value == rhs.value }
    func hash(into hasher: inout Hasher) { hasher.combine(value) }
}

/// Conversation row in the Messages tab.
struct ChatBrief: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let client: ClientBrief?
    let caregiver: CaregiverBrief?
    let updatedAt: String?
    let newMessageCount: Int
    let lastMessage: String?
    let isSeen: Bool

    private enum CodingKeys: String, CodingKey {
        case id, client, caregiver
        case updatedAt = "updated_at"
        case newMessageCount = "new_message_count"
        case lastMessage = "last_message"
        case isSeen = "is_seen"
    }

    /// The other party, from the signed-in user's point of view.
    func partner(for role: UserRole) -> User? {
        role == .client ? caregiver?.user : client?.user
    }
}

struct ChatFull: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let client: ClientBrief?
    let caregiver: CaregiverBrief?
    let updatedAt: String?
    let messages: [ChatMessage]

    private enum CodingKeys: String, CodingKey {
        case id, client, caregiver, messages
        case updatedAt = "updated_at"
    }

    func partner(for role: UserRole) -> User? {
        role == .client ? caregiver?.user : client?.user
    }

    /// The API returns messages newest-first with minute-precision timestamps; the
    /// Android transcript reads oldest-at-top. Ids are monotonic, so order by id.
    var chronologicalMessages: [ChatMessage] { messages.sorted { $0.id < $1.id } }
}

extension ChatMessage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        isFromCaregiver = try c.decode(Bool.self, forKey: .isFromCaregiver)
        parent = c.lenient(.parent)
        message = c.lenient(.message, default: "")
        createdAt = c.lenient(.createdAt)
        updatedAt = c.lenient(.updatedAt)
        seenAt = c.lenient(.seenAt)
    }
}

extension ChatBrief {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        client = c.lenient(.client)
        caregiver = c.lenient(.caregiver)
        updatedAt = c.lenient(.updatedAt)
        newMessageCount = c.lenient(.newMessageCount, default: 0)
        lastMessage = c.lenient(.lastMessage)
        isSeen = c.lenient(.isSeen, default: true)
    }
}

extension ChatFull {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        client = c.lenient(.client)
        caregiver = c.lenient(.caregiver)
        updatedAt = c.lenient(.updatedAt)
        messages = c.lenient(.messages, default: [])
    }
}
