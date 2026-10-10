import Foundation

/// The API pre-formats timestamps in UTC without saying so ("2026-09-25 02:16:52",
/// "2:22 09/25"). Android prints them as they come, so a user sees UTC; show the
/// viewer's local time instead, in the same format. Other strings pass through.
enum ServerTime {
    static func local(_ value: String?, now: Date = Date()) -> String {
        guard let value, !value.isEmpty else { return "" }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let local = Calendar.current
        let parts = value.split(whereSeparator: { ":- /".contains($0) }).compactMap { Int($0) }
        if value.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil, parts.count == 6,
           let date = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])) {
            let c = local.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        }
        if value.range(of: #"^\d{1,2}:\d{2} \d{2}/\d{2}$"#, options: .regularExpression) != nil, parts.count == 4 {
            // No year: take the current one, or last year if that lands in the future.
            let year = utc.component(.year, from: now)
            func make(_ y: Int) -> Date? { utc.date(from: DateComponents(year: y, month: parts[2], day: parts[3], hour: parts[0], minute: parts[1])) }
            guard var date = make(year) else { return value }
            if date.timeIntervalSince(now) > 86_400, let earlier = make(year - 1) { date = earlier }
            let c = local.dateComponents([.month, .day, .hour, .minute], from: date)
            return String(format: "%d:%02d %02d/%02d", c.hour!, c.minute!, c.month!, c.day!)
        }
        return value
    }
}
