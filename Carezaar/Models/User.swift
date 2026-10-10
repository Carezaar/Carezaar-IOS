import Foundation

/// Verification state driving the `Pending` route and the drawer's
/// `navigation_drawer_user_pending` / `_user_verified` labels.
enum UserStatus: String, Codable, Sendable {
    case pending = "PENDING"
    case unverified = "UNVERIFIED"
    case verified = "VERIFIED"

    /// Unknown future values decode as `.unverified` rather than failing the whole response.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = UserStatus(rawValue: raw.uppercased()) ?? .unverified
    }
}

/// The two product roles. `auth/register` sends this as a lowercase string.
enum UserRole: String, Codable, Sendable {
    case client
    case caregiver

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = UserRole(rawValue: raw.lowercased()) ?? .client
    }
}

/// `UserFull` / `UserBrief` share an identical shape in the Android client.
struct User: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let countryId: Int
    let genderId: Int?
    let role: UserRole
    let email: String
    let firstName: String?
    let lastName: String?
    let photo: String?
    let bio: String?
    let dateOfBirth: String?
    let status: UserStatus
    let isFavorite: Bool

    var fullName: String {
        [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, email, photo, bio, status
        case countryId = "country_id"
        case genderId = "gender_id"
        case firstName = "first_name"
        case lastName = "last_name"
        case dateOfBirth = "date_of_birth"
        case isFavorite = "is_favorite"
    }
}

/// `UserTiny` — the reviewer shape, which additionally carries `rating`.
struct UserTiny: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let countryId: Int
    let genderId: Int?
    let role: UserRole
    let email: String
    let firstName: String?
    let lastName: String?
    let photo: String?
    let bio: String?
    let dateOfBirth: String?
    let rating: Double
    let status: UserStatus
    let isFavorite: Bool

    var fullName: String {
        [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, email, photo, bio, rating, status
        case countryId = "country_id"
        case genderId = "gender_id"
        case firstName = "first_name"
        case lastName = "last_name"
        case dateOfBirth = "date_of_birth"
        case isFavorite = "is_favorite"
    }
}

struct Session: Codable, Sendable {
    let accessToken: String
    let refreshToken: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

// Decoders live in extensions so the memberwise initialisers stay available.

extension User {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(UserRole.self, forKey: .role)
        countryId = c.lenient(.countryId, default: 0)
        genderId = c.lenient(.genderId)
        email = c.lenient(.email, default: "")
        firstName = c.lenient(.firstName)
        lastName = c.lenient(.lastName)
        photo = c.lenient(.photo)
        bio = c.lenient(.bio)
        dateOfBirth = c.lenient(.dateOfBirth)
        status = c.lenient(.status, default: .unverified)
        isFavorite = c.lenient(.isFavorite, default: false)
    }
}

extension UserTiny {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(UserRole.self, forKey: .role)
        countryId = c.lenient(.countryId, default: 0)
        genderId = c.lenient(.genderId)
        email = c.lenient(.email, default: "")
        firstName = c.lenient(.firstName)
        lastName = c.lenient(.lastName)
        photo = c.lenient(.photo)
        bio = c.lenient(.bio)
        dateOfBirth = c.lenient(.dateOfBirth)
        rating = c.lenient(.rating, default: 0)
        status = c.lenient(.status, default: .unverified)
        isFavorite = c.lenient(.isFavorite, default: false)
    }
}
