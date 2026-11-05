import Foundation

/// A closed→open→half-open fast-fail protection for outbound dependencies.
///
/// The circuit breaker breaks when a threshold of consecutive failures is reached,
/// immediately rejecting further calls. After a cooldown, a single probe (half-open)
/// is admitted; success closes the circuit and resets the count; probe failure
/// reopens and restarts the cooldown. State transitions and timing are driven by an
/// injected `now` closure, enabling deterministic testing. The half-open state
/// admits exactly one concurrent probe; all other callers fast-fail while a probe
/// is in flight.
actor CircuitBreaker {
    enum State: Sendable, Equatable {
        case closed
        case open
        case halfOpen
    }

    private(set) var state: State = .closed
    private let failureThreshold: Int
    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date
    private var consecutiveFailures = 0
    private var openedAt: Date?
    private var lastError: (any Error)?
    private var probeInFlight = false

    init(
        failureThreshold: Int = 5,
        cooldown: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.failureThreshold = failureThreshold
        self.cooldown = cooldown
        self.now = now
    }

    func execute<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        switch state {
        case .open:
            let elapsed = openedAt.map { now().timeIntervalSince($0) } ?? 0
            if elapsed < cooldown {
                // Cooldown not yet elapsed — fast-fail with retryAfter.
                throw CircuitBreakerOpenError(
                    failureCount: consecutiveFailures,
                    lastError: lastError,
                    retryAfter: cooldown - elapsed
                )
            }
            // Cooldown elapsed — transition to half-open.
            state = .halfOpen
            fallthrough

        case .halfOpen:
            // Only one probe allowed in half-open. While it is in flight, all other
            // callers fast-fail; retryAfter is nil because the probe's outcome, not
            // a cooldown, decides when the circuit reopens or closes.
            if probeInFlight {
                throw CircuitBreakerOpenError(
                    failureCount: consecutiveFailures,
                    lastError: lastError,
                    retryAfter: nil
                )
            }
            // Claim the probe slot.
            probeInFlight = true
            defer { probeInFlight = false }

            do {
                let result = try await operation()
                recordSuccess()
                return result
            } catch {
                recordFailure(error)
                throw error
            }

        case .closed:
            do {
                let result = try await operation()
                recordSuccess()
                return result
            } catch {
                recordFailure(error)
                throw error
            }
        }
    }

    private func recordSuccess() {
        consecutiveFailures = 0
        lastError = nil
        state = .closed
    }

    private func recordFailure(_ error: any Error) {
        consecutiveFailures += 1
        lastError = error
        if consecutiveFailures >= failureThreshold {
            state = .open
            openedAt = now()
        }
    }

    func reset() {
        state = .closed
        consecutiveFailures = 0
        openedAt = nil
        lastError = nil
        probeInFlight = false
    }
}

struct CircuitBreakerOpenError: Error, CustomStringConvertible {
    let failureCount: Int
    let lastError: (any Error)?
    let retryAfter: TimeInterval?

    var description: String {
        let cause = lastError.map { "\($0)" } ?? "unknown"
        let result = "Circuit breaker tripped after \(failureCount) consecutive failures (last: \(cause))"
        if let retryAfter {
            return result + "; retry after \(String(format: "%.1f", retryAfter))s"
        }
        return result
    }
}
