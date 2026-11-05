import Foundation
import FirestoreAPI

// Lossless Timestamp <-> Date helpers.
//
// The pinned FirebaseAPI `Timestamp(_ date:)` truncates to whole seconds and
// `Date(timestamp:)` divides nanos by 1_000_000 (should be 1_000_000_000), so
// sub-second values are corrupted. Models that persist client-read timestamps
// (D6) should use these instead.

extension Timestamp {

    /// Exact conversion, preserving sub-second precision (floor semantics, nanos in 0..<1e9).
    init(exact date: Date) {
        let interval = date.timeIntervalSince1970
        var seconds = interval.rounded(.down)
        var nanos = ((interval - seconds) * 1_000_000_000).rounded()
        if nanos >= 1_000_000_000 {
            seconds += 1
            nanos = 0
        }
        self.init(seconds: Int64(seconds), nanos: Int32(nanos))
    }

    /// The point in time as a `Date`, with correct nanosecond scaling.
    var asDate: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    }
}
