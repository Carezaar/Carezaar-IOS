import Foundation

/// Enum-backed routing, as the iOS architecture doc recommends: "Map the Android
/// AppNavHost string routing directly to a SwiftUI NavigationStack path model or
/// coordinators using enum-based routing states."
///
/// Raw values are the Android route identifiers recovered from the shipped APK, so
/// deep links and analytics stay aligned across platforms.
enum Route: Hashable, Sendable {
    case splash
    case intro
    case signIn
    case signUpCredentials(role: UserRole)
    case signUpProfile
    case signUpFormClient
    case signUpFormCaregiver
    case forgotPassword
    case otp
    case setupPassword
    case main
    case matches
    case chats
    case chat(chatId: Int)
    case notifications
    case profile
    case favorites
    case caregiverDetails(caregiverId: String)
    case clientDetails(clientId: String)
    case caregiverSkills
    case clientPreferences
    case changeLanguage
    case changePassword
    case contactSupport
    case faq
    case reportAnIssue
    case deleteAccount
    case matched(partner: MatchedPartner)
    case profileEdit
    case manageMatches
    case helpCenter

    /// The Android `AppNavHost` identifier for this destination.
    var identifier: String {
        switch self {
        case .splash: return "Splash"
        case .intro: return "Intro"
        case .signIn: return "SignIn"
        case .signUpCredentials(let role): return "SignUpCredentials/\(role.rawValue)"
        case .signUpProfile: return "SignUpProfile"
        case .signUpFormClient: return "SignUpFormClient"
        case .signUpFormCaregiver: return "SignUpFormCaregiver"
        case .forgotPassword: return "ForgotPassword"
        case .otp: return "OTP"
        case .setupPassword: return "SetupPassword"
        case .main: return "Main"
        case .matches: return "Matches"
        case .chats: return "Chats"
        case .chat(let id): return "Chat/\(id)"
        case .notifications: return "Notifications"
        case .profile: return "Profile"
        case .favorites: return "Favorites"
        case .caregiverDetails(let id): return "CaregiverDetails/\(id)"
        case .clientDetails(let id): return "ClientDetails/\(id)"
        case .caregiverSkills: return "CaregiverSkills"
        case .clientPreferences: return "ClientPreferences"
        case .changeLanguage: return "ChangeLanguage"
        case .changePassword: return "ChangePassword"
        case .contactSupport: return "ContactSupport"
        case .faq: return "FAQ"
        case .reportAnIssue: return "ReportAnIssue"
        case .deleteAccount: return "DeleteAccount"
        case .matched(let partner):
            switch partner {
            case .caregiver(let id): return "Matched/caregivers/\(id)"
            case .client(let id): return "Matched/clients/\(id)"
            }
        case .profileEdit: return "ProfileEdit"
        case .manageMatches: return "ManageMatches"
        case .helpCenter: return "HelpCenter"
        }
    }
}

/// The three tabs of `Main`.
enum MainTab: String, CaseIterable, Hashable, Sendable {
    case matches, messages, profile
}

extension Route {
    /// Routes reachable without a session — used by the `--qa-route` capture harness.
    static let allUnauthenticated: [Route] = [
        .splash, .intro, .signIn,
        .signUpCredentials(role: .client), .signUpCredentials(role: .caregiver),
        .signUpProfile, .signUpFormClient, .signUpFormCaregiver,
        .forgotPassword, .otp, .setupPassword,
    ]
}
