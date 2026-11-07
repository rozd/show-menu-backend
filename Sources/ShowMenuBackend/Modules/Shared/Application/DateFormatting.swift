import Foundation

extension Date {
    /// JS `Date.toISOString()` form: `2026-01-02T03:04:05.678Z` (UTC, milliseconds).
    var jsISOString: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
    }
}

/// A stored/DTO date string that is not RFC 3339. A data-integrity fault, not a client error:
/// it propagates as a 500.
struct InvalidDateStringError: Error, Equatable, CustomStringConvertible {
    let value: String
    var description: String { "Invalid date string: \(value)" }
}

extension Date {
    /// Parses an RFC 3339 / ISO-8601 instant, with or without fractional seconds
    /// (the inverse of ``jsISOString``, lenient about the milliseconds).
    static func parseISO(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Like ``parseISO(_:)`` but throws ``InvalidDateStringError``.
    static func parseISOOrThrow(_ string: String) throws -> Date {
        guard let date = parseISO(string) else { throw InvalidDateStringError(value: string) }
        return date
    }
}
