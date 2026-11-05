//
//  RetryPolicy.swift
//  ShowMenuBackend
//
//  Retries a transient-failure-prone async operation with bounded exponential backoff.
//

import Foundation

/// Retries a transient-failure-prone async operation: bounded attempts, capped
/// exponential backoff, and a caller-supplied `shouldRetry` predicate.
///
/// Compose the predicate with transport error taxonomies (e.g.
/// `FirestoreError.isRetryable` — see `RetryPolicy.firestore` in
/// `Integration/Firestore/`). Cancellation is honored: a thrown
/// `CancellationError` is never retried, and cancelling the surrounding task
/// during an inter-attempt sleep stops the loop.
///
/// No jitter (deliberate simplicity) — fine as a default; add jitter at the
/// call site if many concurrent callers can hammer one dependency.
struct RetryPolicy: Sendable {

    /// A pure, capped exponential backoff schedule.
    ///
    /// `delay(forAttempt: n)` is the wait after the n-th failure, before
    /// attempt n + 1: `initial × multiplier^(n−1)`, capped at `cap`. Pure math
    /// — testable without sleeping. Also reused standalone where retries span
    /// process boundaries (the outbox relay persists per-row attempt counts
    /// and derives each row's next `availableAt` from this schedule).
    struct Backoff: Sendable, Equatable {
        /// Delay after the first failure.
        var initial: TimeInterval
        /// Growth factor per subsequent failure.
        var multiplier: Double
        /// Upper bound on the delay.
        var cap: TimeInterval

        static func exponential(
            initial: TimeInterval = 1,
            multiplier: Double = 2,
            cap: TimeInterval = 30
        ) -> Backoff {
            Backoff(initial: initial, multiplier: multiplier, cap: cap)
        }

        /// No waiting between attempts (tests, in-memory work).
        static let immediate = Backoff(initial: 0, multiplier: 1, cap: 0)

        /// Backoff before the next attempt, given `attempt` failures so far (>= 1).
        func delay(forAttempt attempt: Int) -> TimeInterval {
            min(cap, initial * pow(multiplier, Double(max(0, attempt - 1))))
        }
    }

    /// Total attempts including the first (>= 1; `1` means no retry).
    var maxAttempts: Int
    /// Wait schedule between attempts.
    var backoff: Backoff
    /// Whether a failure is transient and worth retrying. Default: retry everything.
    var shouldRetry: @Sendable (any Error) -> Bool

    init(
        maxAttempts: Int = 3,
        backoff: Backoff = .exponential(),
        shouldRetry: @escaping @Sendable (any Error) -> Bool = { _ in true }
    ) {
        precondition(maxAttempts >= 1, "maxAttempts must be at least 1")
        self.maxAttempts = maxAttempts
        self.backoff = backoff
        self.shouldRetry = shouldRetry
    }

    /// Run `operation`, retrying per the policy. Rethrows the operation's last
    /// error once attempts are exhausted or `shouldRetry` declines.
    func execute<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maxAttempts, !(error is CancellationError), shouldRetry(error) else {
                    throw error
                }
                try await Task.sleep(for: .seconds(backoff.delay(forAttempt: attempt)))
                attempt += 1
            }
        }
    }
}
