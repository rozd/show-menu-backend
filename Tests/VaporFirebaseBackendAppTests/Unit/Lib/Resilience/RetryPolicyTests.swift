import Foundation
import Testing
@testable import VaporFirebaseBackendApp

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}

@Suite("RetryPolicy")
struct RetryPolicyTests {

    // MARK: - Success on first attempt

    @Test("returns result on first success")
    func firstSuccess() async throws {
        let policy = RetryPolicy(maxAttempts: 3, backoff: .immediate, shouldRetry: { _ in true })
        let result = try await policy.execute { "ok" }
        #expect(result == "ok")
    }

    // MARK: - Retries on failure

    @Test("retries and succeeds on second attempt")
    func retriesOnce_thenSucceeds() async throws {
        let counter = Counter()
        let policy = RetryPolicy(maxAttempts: 3, backoff: .immediate, shouldRetry: { _ in true })
        let result = try await policy.execute {
            await counter.increment()
            let current = await counter.value
            if current < 2 { throw TestRetryError() }
            return "recovered"
        }
        #expect(result == "recovered")
        let count = await counter.value
        #expect(count == 2)
    }

    // MARK: - Exhausts retries

    @Test("throws last error after exhausting all attempts")
    func exhaustsRetries() async {
        let counter = Counter()
        let policy = RetryPolicy(maxAttempts: 3, backoff: .immediate, shouldRetry: { _ in true })
        do {
            let _: Void = try await policy.execute {
                await counter.increment()
                throw TestRetryError()
            }
        } catch {
            #expect(error is TestRetryError)
        }
        let count = await counter.value
        #expect(count == 3)
    }

    // MARK: - shouldRetry filtering

    @Test("does not retry when shouldRetry returns false")
    func shouldRetryFalse_noRetry() async {
        let counter = Counter()
        let policy = RetryPolicy(maxAttempts: 3, backoff: .immediate, shouldRetry: { _ in false })
        do {
            let _: Void = try await policy.execute {
                await counter.increment()
                throw TestRetryError()
            }
        } catch {
            #expect(error is TestRetryError)
        }
        let count = await counter.value
        #expect(count == 1)
    }

    @Test("retries for matching errors only")
    func selectiveRetry() async {
        let counter = Counter()
        let policy = RetryPolicy(maxAttempts: 3, backoff: .immediate, shouldRetry: { error in
            error is TestRetryError
        })
        do {
            let _: Void = try await policy.execute {
                await counter.increment()
                let current = await counter.value
                if current == 1 { throw TestRetryError() }
                throw PermanentError()
            }
        } catch {
            #expect(error is PermanentError)
        }
        let count = await counter.value
        #expect(count == 2)
    }

    // MARK: - Single attempt

    @Test("maxAttempts 1 means no retry")
    func singleAttempt_noRetry() async {
        let counter = Counter()
        let policy = RetryPolicy(maxAttempts: 1, backoff: .immediate, shouldRetry: { _ in true })
        do {
            let _: Void = try await policy.execute {
                await counter.increment()
                throw TestRetryError()
            }
        } catch {
            #expect(error is TestRetryError)
        }
        let count = await counter.value
        #expect(count == 1)
    }
}

// MARK: - Backoff

@Suite("RetryPolicy.Backoff")
struct RetryPolicyBackoffTests {

    @Test("exponential backoff with cap")
    func exponentialWithCap() {
        let backoff = RetryPolicy.Backoff.exponential(initial: 5, multiplier: 2, cap: 60)
        #expect(backoff.delay(forAttempt: 1) == 5)   // 5 * 2^0
        #expect(backoff.delay(forAttempt: 2) == 10)  // 5 * 2^1
        #expect(backoff.delay(forAttempt: 3) == 20)  // 5 * 2^2
        #expect(backoff.delay(forAttempt: 4) == 40)  // 5 * 2^3
        #expect(backoff.delay(forAttempt: 5) == 60)  // capped (would be 80)
        #expect(backoff.delay(forAttempt: 99) == 60) // capped
    }

    @Test("immediate backoff yields zero")
    func immediateBackoff() {
        let backoff = RetryPolicy.Backoff.immediate
        #expect(backoff.delay(forAttempt: 1) == 0)
        #expect(backoff.delay(forAttempt: 99) == 0)
    }
}

// MARK: - Cancellation

@Suite("RetryPolicy — Cancellation")
struct RetryPolicyCancellationTests {

    @Test("CancellationError is never retried")
    func cancellationNeverRetried() async {
        let counter = Counter()
        let policy = RetryPolicy(maxAttempts: 3, backoff: .immediate, shouldRetry: { _ in true })

        await #expect(throws: CancellationError.self) {
            try await policy.execute {
                await counter.increment()
                throw CancellationError()
            }
        }

        let count = await counter.value
        #expect(count == 1)
    }
}

private struct TestRetryError: Error {}
private struct PermanentError: Error {}
