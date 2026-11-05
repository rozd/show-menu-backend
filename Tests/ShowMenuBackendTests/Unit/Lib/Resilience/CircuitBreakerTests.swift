import Foundation
import Testing
@testable import ShowMenuBackend

// MARK: - Test Fixtures

private struct TestCBError: Error {}

private actor RunTracker {
    var didRun = false
    func record() { didRun = true }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(startingAt: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.current = startingAt
    }

    var now: @Sendable () -> Date {
        { self.read() }
    }

    func read() -> Date {
        lock.withLock { current }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            current.addTimeInterval(interval)
        }
    }
}

// MARK: - Core Behavior

@Suite("CircuitBreaker")
struct CircuitBreakerTests {

    @Test("starts in closed state")
    func startsClosedAsync() async {
        let clock = TestClock()
        let breaker = CircuitBreaker(now: clock.now)
        #expect(await breaker.state == .closed)
    }

    @Test("successful execution returns the value and stays closed")
    func successReturnsValueAsync() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(now: clock.now)

        let result = try await breaker.execute {
            "success"
        }

        #expect(result == "success")
        #expect(await breaker.state == .closed)
    }

    @Test("failures below threshold stay closed")
    func failuresBelowThresholdAsync() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(failureThreshold: 3, now: clock.now)

        // Two failures (below threshold of 3).
        for _ in 0..<2 {
            await #expect(throws: TestCBError.self) {
                try await breaker.execute {
                    throw TestCBError()
                }
            }
        }

        #expect(await breaker.state == .closed)
    }

    @Test("reaching the threshold opens the circuit")
    func thresholdOpensAsync() async throws {
        let clock = TestClock()
        let threshold = 3
        let breaker = CircuitBreaker(failureThreshold: threshold, now: clock.now)

        for _ in 0..<threshold {
            await #expect(throws: TestCBError.self) {
                try await breaker.execute {
                    throw TestCBError()
                }
            }
        }

        #expect(await breaker.state == .open)
    }

    @Test("open circuit fast-fails without running the operation")
    func openFastFailsAsync() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(failureThreshold: 2, now: clock.now)

        // Trip the breaker.
        for _ in 0..<2 {
            await #expect(throws: TestCBError.self) {
                try await breaker.execute {
                    throw TestCBError()
                }
            }
        }

        // Verify it's open.
        #expect(await breaker.state == .open)

        // Now try to call it — should fast-fail without running the operation.
        let tracker = RunTracker()

        await #expect(throws: CircuitBreakerOpenError.self) {
            try await breaker.execute {
                await tracker.record()
                return "should not run"
            }
        }
        #expect(!(await tracker.didRun))
    }

    @Test("open error carries failureCount, lastError, retryAfter, and description")
    func openErrorContentsAsync() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(failureThreshold: 2, now: clock.now)

        // Trip with one failure, then a second.
        let firstError = TestCBError()
        await #expect(throws: TestCBError.self) {
            try await breaker.execute {
                throw firstError
            }
        }

        let secondError = TestCBError()
        await #expect(throws: TestCBError.self) {
            try await breaker.execute {
                throw secondError
            }
        }

        // At this point, the circuit is open due to 2 failures.
        #expect(await breaker.state == .open)

        // The next call should fail with CircuitBreakerOpenError.
        // We're at time 1_000_000, it opened just now, cooldown is 30s.
        let error: CircuitBreakerOpenError = try #require(
            await captureCircuitBreakerOpenError {
                try await breaker.execute { }
            }
        )

        #expect(error.failureCount == 2)
        #expect(error.lastError != nil)
        // retryAfter should be approximately 30 (the full cooldown, since we just opened).
        #expect(error.retryAfter ?? 0 > 29 && error.retryAfter ?? 0 <= 30)
        // Description should mention the failure count.
        #expect(error.description.contains("2"))
    }

    @Test("retryAfter decreases as time advances through the cooldown")
    func retryAfterDecreaseAsync() async throws {
        let clock = TestClock()
        let cooldown: TimeInterval = 30
        let breaker = CircuitBreaker(failureThreshold: 1, cooldown: cooldown, now: clock.now)

        // Trip immediately.
        await #expect(throws: TestCBError.self) {
            try await breaker.execute {
                throw TestCBError()
            }
        }

        // At time 0 (just opened), retryAfter should be ~30.
        let error1: CircuitBreakerOpenError = try #require(
            await captureCircuitBreakerOpenError {
                try await breaker.execute { }
            }
        )
        let retryAfter1 = try #require(error1.retryAfter)
        #expect(retryAfter1 > 29 && retryAfter1 <= 30)

        // Advance by 20s, leaving ~10s of cooldown.
        clock.advance(by: 20)
        let error2: CircuitBreakerOpenError = try #require(
            await captureCircuitBreakerOpenError {
                try await breaker.execute { }
            }
        )
        let retryAfter2 = try #require(error2.retryAfter)
        #expect(retryAfter2 > 9 && retryAfter2 <= 10)
    }

    @Test("after cooldown elapses, a probe runs and success closes the circuit")
    func probeSucceedsClosesAsync() async throws {
        let clock = TestClock()
        let cooldown: TimeInterval = 30
        let breaker = CircuitBreaker(failureThreshold: 3, cooldown: cooldown, now: clock.now)

        // Trip the breaker with 3 failures.
        for _ in 0..<3 {
            await #expect(throws: TestCBError.self) {
                try await breaker.execute {
                    throw TestCBError()
                }
            }
        }
        #expect(await breaker.state == .open)

        // Advance past cooldown.
        clock.advance(by: cooldown + 1)

        // The next call should enter half-open and run the probe.
        let result = try await breaker.execute {
            "probe succeeded"
        }
        #expect(result == "probe succeeded")
        #expect(await breaker.state == .closed)

        // Now fail 2 more times (below new threshold of 3) and verify still closed.
        for _ in 0..<2 {
            await #expect(throws: TestCBError.self) {
                try await breaker.execute {
                    throw TestCBError()
                }
            }
        }
        #expect(await breaker.state == .closed)
    }

    @Test("probe failure reopens the circuit and restarts the cooldown")
    func probeFailureReopensAsync() async throws {
        let clock = TestClock()
        let cooldown: TimeInterval = 30
        let breaker = CircuitBreaker(failureThreshold: 1, cooldown: cooldown, now: clock.now)

        // Trip the breaker.
        await #expect(throws: TestCBError.self) {
            try await breaker.execute { throw TestCBError() }
        }
        #expect(await breaker.state == .open)

        // Advance past cooldown so a probe is allowed.
        clock.advance(by: cooldown + 1)

        // The probe fails.
        await #expect(throws: TestCBError.self) {
            try await breaker.execute { throw TestCBError() }
        }
        #expect(await breaker.state == .open)

        // Immediately after probe failure, retryAfter should be full cooldown (30).
        let error1: CircuitBreakerOpenError = try #require(
            await captureCircuitBreakerOpenError {
                try await breaker.execute { }
            }
        )
        let retryAfter1 = try #require(error1.retryAfter)
        #expect(retryAfter1 > 29 && retryAfter1 <= 30)

        // Advance by less than cooldown — still fails.
        clock.advance(by: cooldown - 1)
        await #expect(throws: CircuitBreakerOpenError.self) {
            try await breaker.execute { "test" }
        }

        // Advance the rest — now a probe is allowed and succeeds.
        clock.advance(by: 2)
        let result = try await breaker.execute { "recovered" }
        #expect(result == "recovered")
        #expect(await breaker.state == .closed)
    }

    @Test("single-probe guard: in-flight probe blocks concurrent calls")
    func singleProbeGuardAsync() async throws {
        let clock = TestClock()
        let cooldown: TimeInterval = 30
        let breaker = CircuitBreaker(failureThreshold: 1, cooldown: cooldown, now: clock.now)

        // Trip the breaker.
        await #expect(throws: TestCBError.self) {
            try await breaker.execute { throw TestCBError() }
        }
        #expect(await breaker.state == .open)

        // Advance past cooldown.
        clock.advance(by: cooldown + 1)

        // Two one-shot gates: the probe signals "started", then blocks until "release".
        // No sleeps — the started signal can only fire after the breaker has claimed
        // the probe slot, so the second call below deterministically fast-fails.
        let (started, startedGate) = AsyncStream.makeStream(of: Void.self)
        let (release, releaseGate) = AsyncStream.makeStream(of: Void.self)

        let probeTask = Task {
            try await breaker.execute {
                startedGate.yield(())
                startedGate.finish()
                for await _ in release { break }
                return "probe result"
            }
        }

        // Wait until the probe is in flight.
        for await _ in started { break }

        // A second execute while the probe is in flight fast-fails without running.
        let tracker = RunTracker()
        await #expect(throws: CircuitBreakerOpenError.self) {
            try await breaker.execute {
                await tracker.record()
                return "should not run"
            }
        }
        #expect(!(await tracker.didRun))

        // Release the probe; its success closes the circuit.
        releaseGate.yield(())
        releaseGate.finish()

        let probeResult = try await probeTask.value
        #expect(probeResult == "probe result")
        #expect(await breaker.state == .closed)
    }

    @Test("success after failures resets the count")
    func successResetsCountAsync() async throws {
        let clock = TestClock()
        let threshold = 3
        let breaker = CircuitBreaker(failureThreshold: threshold, now: clock.now)

        // 2 failures, then success.
        await #expect(throws: TestCBError.self) {
            try await breaker.execute { throw TestCBError() }
        }
        await #expect(throws: TestCBError.self) {
            try await breaker.execute { throw TestCBError() }
        }
        let result = try await breaker.execute { "success" }
        #expect(result == "success")

        // After reset, we can fail threshold−1 times and still stay closed.
        for _ in 0..<(threshold - 1) {
            await #expect(throws: TestCBError.self) {
                try await breaker.execute { throw TestCBError() }
            }
        }
        #expect(await breaker.state == .closed)
    }

    @Test("reset() returns an open breaker to closed")
    func resetAsync() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker(failureThreshold: 2, now: clock.now)

        // Trip the breaker.
        for _ in 0..<2 {
            await #expect(throws: TestCBError.self) {
                try await breaker.execute { throw TestCBError() }
            }
        }
        #expect(await breaker.state == .open)

        // Reset.
        await breaker.reset()
        #expect(await breaker.state == .closed)

        // Now we can fail threshold−1 times and stay closed.
        await #expect(throws: TestCBError.self) {
            try await breaker.execute { throw TestCBError() }
        }
        #expect(await breaker.state == .closed)
    }
}

// MARK: - Helper

private func captureCircuitBreakerOpenError(
    _ block: () async throws -> Void
) async -> CircuitBreakerOpenError? {
    do {
        try await block()
        return nil
    } catch let error as CircuitBreakerOpenError {
        return error
    } catch {
        return nil
    }
}
