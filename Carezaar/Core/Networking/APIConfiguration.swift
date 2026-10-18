import Foundation

enum APIConfiguration {
    /// Base URL recovered from the Android binary. Debug builds can point at staging
    /// with `CAREZAAR_API_BASE_URL`; Release always uses production.
    static var baseURL: URL {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["CAREZAAR_API_BASE_URL"],
           let url = URL(string: raw) {
            return url
        }
        #endif
        return URL(string: "https://new.carezaar.com/api/")!
    }

    /// Maximum wait for an individual response, matching the current client brief.
    static let requestTimeout: TimeInterval = 120
    /// The backend only accepts `perPage` of 10, 25 or 50 (anything else is a 422);
    /// Android always sends 10.
    static let defaultPageSize = 10
}

/// The sign-up consent's documents (parity review v3, C2): the client's Terms of Use
/// and Privacy Policy PDFs (17 Oct 2026), bundled under `Assets/legal`.
enum LegalDocumentConfiguration {
    static let termsOfUseFile = "terms-of-use"
    static let privacyPolicyFile = "privacy-policy"
}
