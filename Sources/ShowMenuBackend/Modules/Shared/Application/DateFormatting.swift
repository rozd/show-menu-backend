import Foundation

extension Date {
    /// JS `Date.toISOString()` form: `2026-01-02T03:04:05.678Z` (UTC, milliseconds).
    var jsISOString: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
    }
}
