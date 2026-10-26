import Foundation

/// A conservative schedule supplied by the API. Unsupported OSM rules remain unknown.
public struct FacilityHours: Codable, Sendable {
    public struct Period: Codable, Sendable { let weekday: Int?; let open: String; let close: String }
    public struct Window: Codable, Sendable { let start: String; let end: String }
    public let raw: String?
    public let timezone: String?
    public let weekly: [Period]?
    public let exceptions: [String: [Period]]?
    public let windows: [Window]?
    public let valid_from: String?
    public let valid_until: String?

    public static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    public func isOpen(at date: Date) -> Bool? {
        if raw == "24/7" { return true }
        if let windows {
            guard let start = Self.date(valid_from), let end = Self.date(valid_until), start <= date, date < end else { return nil }
            for window in windows {
                guard let opened = Self.date(window.start), let closed = Self.date(window.end) else { return nil }
                if opened <= date && date < closed { return true }
            }
            return false
        }
        guard let weekly, let timezone, let zone = TimeZone(identifier: timezone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        func key(_ date: Date) -> String? {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        guard let currentDayKey = key(date) else { return nil }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { return nil }
            guard let dayKey = key(day) else { return nil }
            if offset == -1, exceptions?[currentDayKey] != nil { continue }
            let weekday = (calendar.component(.weekday, from: day) + 5) % 7
            let periods = exceptions?[dayKey] ?? weekly.filter { $0.weekday == weekday }
            for period in periods {
                guard let opened = Self.minutes(period.open), var closed = Self.minutes(period.close) else { return nil }
                if closed <= opened { closed += 1440 }
                let current = minute - offset * 1440
                if opened <= current && current < closed { return true }
            }
        }
        return false
    }
    public func isOpen(at date: Date, duration: TimeInterval) -> Bool? {
        guard duration.isFinite, duration >= 0, duration <= 7200 else { return nil }
        var points = [date]
        if duration > 0 {
            let end = date.addingTimeInterval(duration)
            points.append(end.addingTimeInterval(-0.001))
            // Weekly schedules change on minute boundaries; absolute windows may change at seconds.
            var minute = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60 + 60)
            while minute < end { points.append(minute); minute.addTimeInterval(60) }
            for window in windows ?? [] {
                for value in [window.start, window.end] {
                    if let boundary = Self.date(value), date <= boundary, boundary < end { points.append(boundary) }
                }
            }
            for value in [valid_from, valid_until] {
                if let boundary = Self.date(value), date <= boundary, boundary < end { points.append(boundary) }
            }
        }
        let states = points.map { isOpen(at: $0) }
        if states.contains(where: { $0 == false }) { return false }
        return states.allSatisfy { $0 == true } ? true : nil
    }
    private static func minutes(_ text: String) -> Int? {
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let parts = pieces.compactMap { Int($0) }
        guard parts.count == 2, (0...24).contains(parts[0]), (0..<60).contains(parts[1]), parts[0] < 24 || parts[1] == 0 else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
