import Foundation
import Testing
@testable import ShowMenuBackend

// MARK: - Test fixtures

private enum RateLimiterTestError: Error { case operationFailed }

// MARK: - Rate Limit Arithmetic Tests

@Suite("RateLimit — arithmetic")
struct RateLimitArithmeticTests {

    @Test("perSecond(10) has spacing of 100ms")
    func perSecond_spacing() {
        let limit = RateLimit.perSecond(10)
        #expect(limit.spacing == .milliseconds(100))
    }

    @Test("perMinute(600) has spacing of 100ms")
    func perMinute_spacing() {
        let limit = RateLimit.perMinute(600)
        #expect(limit.spacing == .milliseconds(100))
    }

    @Test("every(70ms) has spacing of 70ms")
    func every_spacing() {
        let limit = RateLimit.every(.milliseconds(70))
        #expect(limit.spacing == .milliseconds(70))
    }

    @Test("RateLimit(4, per: 1s) has spacing of 250ms")
    func custom_spacing() {
        let limit = RateLimit(4, per: .seconds(1))
        #expect(limit.spacing == .milliseconds(250))
    }
}

// MARK: - Acquisition Tests

/// Timing assertions here are **lower bounds only**. `Task.sleep` never returns
/// early, so "elapsed >= X" is stable; an upper bound on a sleep would be flaky
/// under CI scheduling noise. The one `<` assertion below covers a path that
/// performs no sleep at all.
@Suite("RateLimiter — acquisition")
struct RateLimiterAcquisitionTests {

    @Test("first acquisition does not wait")
    func firstAcquisition_noWait() async throws {
        let limiter = RateLimiter(.every(.seconds(5)))

        let start = ContinuousClock.now
        try await limiter.acquire()
        let elapsed = ContinuousClock.now - start

        // Should return essentially immediately (no sleep is performed).
        #expect(elapsed < .milliseconds(500))
    }

    @Test("serial acquisitions are paced")
    func serialAcquisitions_paced() async throws {
        let limiter = RateLimiter(.every(.milliseconds(50)))

        let start = ContinuousClock.now
        try await limiter.acquire()  // slot 0
        try await limiter.acquire()  // slot 1 (at 50ms)
        try await limiter.acquire()  // slot 2 (at 100ms)
        let elapsed = ContinuousClock.now - start

        // 3 acquisitions with 50ms spacing: should take >= 100ms (0ms + 50ms + 50ms).
        #expect(elapsed >= .milliseconds(100))
    }

    @Test("concurrent acquisitions are serialized and paced")
    func concurrentAcquisitions_serialized() async throws {
        let limiter = RateLimiter(.every(.milliseconds(50)))

        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await limiter.acquire()
                }
            }
            try await group.waitForAll()
        }
        let elapsed = ContinuousClock.now - start

        // 4 concurrent calls are serialized by the actor and paced:
        // slot 0 (0ms), slot 1 (50ms), slot 2 (100ms), slot 3 (150ms).
        // This test documents the reentrant/stale-read bug that the redesign fixes:
        // the broken implementation would finish in ~50ms (all woken together),
        // while the correct reservation scheme takes >= 150ms.
        #expect(elapsed >= .milliseconds(150))
    }
}

// MARK: - Execute Tests

@Suite("RateLimiter — execute")
struct RateLimiterExecuteTests {

    @Test("execute returns the operation's value")
    func execute_returnsValue() async throws {
        let limiter = RateLimiter(.perSecond(1))
        let result = try await limiter.execute {
            42
        }
        #expect(result == 42)
    }

    @Test("execute rethrows errors from the operation")
    func execute_rethrowsError() async throws {
        let limiter = RateLimiter(.perSecond(1))

        await #expect(throws: RateLimiterTestError.self) {
            try await limiter.execute {
                throw RateLimiterTestError.operationFailed
            }
        }
    }
}

// MARK: - Cancellation Tests

@Suite("RateLimiter — cancellation")
struct RateLimiterCancellationTests {

    @Test("cancellation during sleep propagates CancellationError")
    func cancellation_propagates() async throws {
        let limiter = RateLimiter(.every(.seconds(10)))

        // First acquisition consumes slot 0.
        try await limiter.acquire()

        // Second acquisition will wait for slot 1 (at 10 seconds).
        let task = Task {
            try await limiter.acquire()
        }

        // Let the task enter its sleep (a small delay ensures it has started).
        try await Task.sleep(for: .milliseconds(50))

        // Cancel the task.
        task.cancel()

        // The task should throw CancellationError.
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
