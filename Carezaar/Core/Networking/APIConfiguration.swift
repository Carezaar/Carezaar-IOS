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

    /// Android configures 120s; 60s keeps a stalled screen from looking frozen while
    /// still covering the slowest live endpoints (base tables, multipart upload).
    static let requestTimeout: TimeInterval = 60
    /// The backend only accepts `perPage` of 10, 25 or 50 (anything else is a 422);
    /// Android always sends 10.
    static let defaultPageSize = 10
}
