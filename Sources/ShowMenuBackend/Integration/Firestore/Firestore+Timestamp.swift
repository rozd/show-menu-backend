import Foundation
import FirestoreAPI

// Lossless Timestamp <-> Date helpers.
//
// The pinned FirebaseAPI `Timestamp(_ date:)` truncates to whole seconds and
// `Date(timestamp:)` divides nanos by 1_000_000 (should be 1_000_000_000), so
// sub-second values are corrupted. Models that persist client-read timestamps
// (D6) should use these instead.

extension Timestamp {

    /// Millisecond-precise conversion, matching Node's `Timestamp.fromDate` (a JS `Date` has
    /// millisecond precision; sub-millisecond digits are floored). Nanos are in 0..<1e9.
    init(exact date: Date) {
        // Snap to whole microseconds first: a Double near 1.7e9 s only resolves ~0.24 µs, so a
        // ms-aligned date (…123 ms) may read back as …122.9999 ms and a bare floor would drift
        // it down by 1 ms.
        let micros = (date.timeIntervalSince1970 * 1_000_000).rounded()
        let millis = (micros / 1_000).rounded(.down)
        let seconds = (millis / 1_000).rounded(.down)
        let nanos = (millis - seconds * 1_000) * 1_000_000
        self.init(seconds: Int64(seconds), nanos: Int32(nanos))
    }

    /// The point in time as a `Date`, with correct nanosecond scaling.
    var asDate: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    }
}
