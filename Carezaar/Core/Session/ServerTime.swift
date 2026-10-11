import Foundation

/// Server timestamps are already display strings. Preserve their timezone and formatting.
enum ServerTime {
    static func local(_ value: String?, now: Date = Date()) -> String { value ?? "" }
}
