import Foundation

/// Subscription period. Raw values equal Node's `SubscriptionDuration` strings.
enum SubscriptionDuration: String, Sendable, Hashable, Codable, CaseIterable {
    case daily, weekly, monthly, yearly

    /// Calendar addition in UTC (Node: date-fns `addDays/Weeks/Months/Years`).
    func add(to date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let (component, value): (Calendar.Component, Int) = switch self {
        case .daily: (.day, 1)
        case .weekly: (.day, 7)
        case .monthly: (.month, 1)
        case .yearly: (.year, 1)
        }
        return calendar.date(byAdding: component, value: value, to: date)!
    }

    /// Fixed-length approximation (Node `durationFromPeriodicity`), in seconds.
    var approximateSeconds: TimeInterval {
        switch self {
        case .daily: 86_400
        case .weekly: 7 * 86_400
        case .monthly: 30 * 86_400
        case .yearly: 365 * 86_400
        }
    }
}
