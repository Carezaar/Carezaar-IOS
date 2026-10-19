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

/// Client-supplied PDFs remain the interim fallback only when no server URL is
/// configured. A configured invalid URL or remote failure must never show stale text.
enum LegalDocumentConfiguration {
    static let termsOfUseFile = "terms-of-use"
    static let privacyPolicyFile = "privacy-policy"
    static let termsURLKey = "CarezaarTermsOfUseURL"
    static let privacyURLKey = "CarezaarPrivacyPolicyURL"

    static func httpsURL(_ raw: String?) throws -> URL? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw URLError(.badURL)
        }
        return url
    }

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: APIConfiguration.requestTimeout)
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }
}
