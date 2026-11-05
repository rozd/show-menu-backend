//
//  RateLimiter.swift
//  ShowMenuBackend
//
//  Client-side pacing for outbound calls to a rate-limited dependency.
//

import Foundation

// MARK: - Rate Limit

/// A rate limit written the way third-party APIs document theirs — "600 requests
/// per minute" — rather than as a hand-computed interval.
///
/// Stating the vendor's published quota keeps the *intent* at the call site and
/// leaves the derived ``spacing`` an implementation detail. The alternative, a
/// bare `minInterval: .milliseconds(70)`, reads as a magic number tuned to one
/// vendor and loses the reason it was chosen.
struct RateLimit: Sendable, Equatable {

    /// Permitted acquisitions per ``period``. Always >= 1.
    let count: Int

    /// Window the ``count`` applies to. Always positive.
    let period: Duration

    /// - Precondition: `count >= 1` and `period > .zero`.
    init(_ count: Int, per period: Duration) {
        precondition(count >= 1, "RateLimit.count must be at least 1, got \(count)")
        precondition(period > .zero, "RateLimit.period must be positive, got \(period)")
        self.count = count
        self.period = period
    }

    /// `count` acquisitions per second.
    static func perSecond(_ count: Int) -> RateLimit {
        RateLimit(count, per: .seconds(1))
    }

    /// `count` acquisitions per minute.
    static func perMinute(_ count: Int) -> RateLimit {
        RateLimit(count, per: .seconds(60))
    }

    /// One acquisition every `interval` — the literal minimum-spacing form.
    static func every(_ interval: Duration) -> RateLimit {
        RateLimit(1, per: interval)
    }

    /// Minimum time between successive acquisitions: `period / count`.
    ///
    /// E.g. `RateLimit.perSecond(10).spacing == .milliseconds(100)`.
    var spacing: Duration {
        period / count
    }
}

// MARK: - Rate Limiter

/// Paces outbound calls so a rate-limited dependency is never hammered.
///
/// ```swift
/// let limiter = RateLimiter(.perMinute(600))
/// let page = try await limiter.execute { try await vendor.fetchPage(cursor) }
/// ```
///
/// **How it paces: reservation, not "time since the last call".** Each caller
/// *reserves* the next free slot, then sleeps until its own slot falls due. The
/// reservation is written before the method ever suspends, so it is atomic with
/// respect to the actor: N concurrent callers get N distinct, evenly spaced
/// slots, assigned in the order the actor admits them.
///
/// The naive alternative — "if `now - lastCall < spacing`, sleep the difference"
/// — is broken under concurrency, which is precisely the case a limiter exists
/// for. Actors are *reentrant*: the `await` on the sleep releases the actor, so
/// every concurrent caller reads the same stale `lastCall`, sleeps the same
/// amount, and wakes together. The limit then holds only for strictly serial
/// callers, who needed no limiter in the first place.
///
/// **Smooth spacing, no burst.** Successive acquisitions are at least
/// `period / count` apart, so the vendor's window is never exceeded. The
/// trade-off against a token bucket: an idle limiter banks no credit, so a quiet
/// period is not followed by a burst of `count` calls. That is the deliberate,
/// conservative choice — and it needs no bucket state.
///
/// **Bounds the rate of *starts*, not concurrency.** ``execute(_:)`` runs its
/// operation outside the actor, so slow operations overlap freely. Add a bounded
/// task group or a semaphore if you also need a concurrency cap.
///
/// **Per-process and in-memory.** Every Cloud Run instance gets its own limiter,
/// so size the limit per instance (vendor quota ÷ max instances), or reach for a
/// distributed limiter when a single global quota must hold.
///
/// **Cancellation propagates.** A caller cancelled while waiting throws
/// `CancellationError` and does *not* run its operation. Its reserved slot is
/// abandoned rather than reclaimed — that can only make pacing more
/// conservative, never less.
///
/// **No injectable clock**, unlike its neighbour ``CircuitBreaker``. That one
/// only *reads* time, so a `now` closure fully determinizes it; a limiter must
/// actually sleep, so injecting `now` alone would buy nothing. Its tests use
/// small real durations and assert lower bounds only.
actor RateLimiter {

    /// Minimum gap between successive slots, derived from the limit.
    private let spacing: Duration

    /// Instant at which the next slot falls due; `nil` until the first acquisition.
    private var nextSlot: ContinuousClock.Instant?

    /// - Parameter limit: The limit to enforce. Intentionally has no default —
    ///   the right value comes from the dependency's published quota, and a
    ///   baked-in default is just one vendor's number in disguise.
    init(_ limit: RateLimit) {
        self.spacing = limit.spacing
    }

    /// Reserves the next slot and waits until it falls due.
    ///
    /// Returns immediately when the limiter has been idle for at least
    /// ``RateLimit/spacing``.
    ///
    /// - Throws: `CancellationError` if the task is cancelled while waiting.
    func acquire() async throws {
        let now = ContinuousClock.now
        let slot = max(now, nextSlot ?? now)
        // Reserve before suspending. Nothing may `await` between reading
        // `nextSlot` and writing it, or concurrent callers claim the same slot —
        // that reentrancy hole is the bug this design exists to close.
        nextSlot = slot + spacing

        guard slot > now else { return }
        // `tolerance: .zero`: pacing should be tight, so opt out of the clock's
        // default coalescing slack.
        try await Task.sleep(until: slot, tolerance: .zero, clock: .continuous)
    }

    /// Waits for a slot, then runs `operation`.
    ///
    /// `nonisolated` on purpose: the operation runs in the caller's context, not
    /// under the limiter's isolation.
    ///
    /// The signature matches ``RetryPolicy/execute(_:)`` and
    /// ``CircuitBreaker/execute(_:)``, so the three nest. Put the limiter
    /// **innermost**, so every retried attempt is paced:
    ///
    /// ```swift
    /// try await policy.execute {
    ///     try await breaker.execute {
    ///         try await limiter.execute { try await vendor.call() }
    ///     }
    /// }
    /// ```
    ///
    /// - Returns: Whatever `operation` returns.
    /// - Throws: `CancellationError` if cancelled while waiting for a slot;
    ///   rethrows anything `operation` throws.
    nonisolated func execute<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        return try await operation()
    }
}
