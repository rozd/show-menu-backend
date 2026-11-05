import Foundation
import Testing
@testable import ShowMenuBackend

// MARK: - Test fixtures

private struct TestCommand: Command {
    struct Payload: Codable, Sendable, Equatable {
        let value: String
    }
    let payload: Payload
    let metadata: CommandMetadata = CommandMetadata(correlationId: "test")
}

private struct TestResult: Codable, Sendable, Equatable {
    let echoed: String
}

/// A `CommandHandler` spy: counts how many times the *work* actually runs, and
/// can be configured to return a value or throw.
private final class SpyCommandHandler: IdempotentCommandHandler, @unchecked Sendable {
    typealias Params = TestCommand
    typealias Result = TestResult

    let unitOfWork: any UnitOfWork
    let idempotency: IdempotencyComponents
    private let behavior: @Sendable (TestCommand) throws -> TestResult
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int { lock.withLock { _callCount } }

    init(
        unitOfWork: any UnitOfWork = StubUnitOfWork(),
        idempotency: IdempotencyComponents,
        behavior: @escaping @Sendable (TestCommand) throws -> TestResult = { TestResult(echoed: $0.payload.value) }
    ) {
        self.unitOfWork = unitOfWork
        self.idempotency = idempotency
        self.behavior = behavior
    }

    func perform(_ command: TestCommand, in context: any UnitOfWorkContext) async throws -> TestResult {
        lock.withLock { _callCount += 1 }
        return try behavior(command)
    }
}

// MARK: - Fixtures for the overridable `fingerprint(for:)` hook

/// A command carrying identity *outside* its payload (mirrors how
/// `UpdateFeatureCommand.featureId` is a route parameter, not a payload field).
private struct ScopedCommand: Command {
    struct Payload: Codable, Sendable, Equatable {
        let value: String
    }
    let resourceId: String
    let payload: Payload
    let metadata: CommandMetadata = CommandMetadata(correlationId: "test")
}

/// The canonical scope a `ScopedHandler` fingerprints over: the out-of-payload
/// `resourceId` folded in with the payload. Shared by the handler and the test
/// so seeded fingerprints match what the handler computes.
private struct ScopedFingerprint: Encodable {
    let resourceId: String
    let payload: ScopedCommand.Payload
}

/// A handler that overrides `fingerprint(for:)` to include `resourceId`, so the
/// same key reused against a different resource is a mismatch, not a mis-replay.
private final class ScopedHandler: IdempotentCommandHandler, @unchecked Sendable {
    typealias Params = ScopedCommand
    typealias Result = TestResult

    let unitOfWork: any UnitOfWork = StubUnitOfWork()
    let idempotency: IdempotencyComponents
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    init(idempotency: IdempotencyComponents) { self.idempotency = idempotency }

    func perform(_ command: ScopedCommand, in context: any UnitOfWorkContext) async throws -> TestResult {
        lock.withLock { _callCount += 1 }
        return TestResult(echoed: command.payload.value)
    }

    func fingerprint(for command: ScopedCommand) throws -> RequestFingerprint {
        try RequestFingerprint(payload: ScopedFingerprint(
            resourceId: command.resourceId,
            payload: command.payload
        ))
    }
}

@Suite("IdempotentCommandHandler")
struct IdempotentCommandHandlerTests {

    private let configuration = IdempotencyConfiguration.default

    private func makeSUT(
        store: InMemoryIdempotencyStore
    ) -> SpyCommandHandler {
        SpyCommandHandler(
            idempotency: IdempotencyComponents(
                storeFactory: { _ in store },
                configuration: configuration
            )
        )
    }

    /// The record id the decorator computes for `key` under the default scope.
    private func recordId(forKey key: String) throws -> String {
        configuration.scope.recordId(
            key: try IdempotencyKey(key),
            commandType: String(reflecting: TestCommand.self),
            principalId: nil
        )
    }

    private func command(_ value: String) -> TestCommand {
        TestCommand(payload: .init(value: value))
    }

    // MARK: - New key executes once and stores the response

    @Test("new key runs the work once and stores the response")
    func newKeyRunsOnceAndStores() async throws {
        let store = InMemoryIdempotencyStore()
        let sut = makeSUT(store: store)

        let result = try await RequestContext.$idempotencyKey.withValue(try IdempotencyKey("k-new")) {
            try await sut.handle(command("hello"))
        }

        #expect(result == TestResult(echoed: "hello"))
        #expect(sut.callCount == 1)
        let id = try recordId(forKey: "k-new")
        #expect(await store.entry(id: id)?.status == .completed)
    }

    // MARK: - Completed duplicate replays without re-executing

    @Test("completed duplicate replays the stored response without re-running")
    func completedDuplicateReplays() async throws {
        let store = InMemoryIdempotencyStore()
        let sut = makeSUT(store: store)
        let key = try IdempotencyKey("k-dup")

        let first = try await RequestContext.$idempotencyKey.withValue(key) {
            try await sut.handle(command("once"))
        }
        // Same key, same body → must replay the first response, not re-execute.
        let second = try await RequestContext.$idempotencyKey.withValue(key) {
            try await sut.handle(command("once"))
        }

        #expect(first == second)
        #expect(sut.callCount == 1)   // work ran exactly once
    }

    // MARK: - In-flight duplicate is rejected (not run twice)

    @Test("in-flight duplicate is rejected and the work is not run")
    func inFlightDuplicateRejected() async throws {
        let store = InMemoryIdempotencyStore()
        let sut = makeSUT(store: store)
        let key = try IdempotencyKey("k-inflight")
        let id = try recordId(forKey: key.rawValue)
        let fingerprint = try RequestFingerprint(payload: command("body").payload)
        await store.seedInProgress(id: id, fingerprint: fingerprint)

        await #expect(throws: IdempotencyError.requestInProgress(key: "k-inflight")) {
            try await RequestContext.$idempotencyKey.withValue(key) {
                try await sut.handle(command("body"))
            }
        }
        #expect(sut.callCount == 0)   // never executed
    }

    // MARK: - Same key, different body → reject

    @Test("same key with a different body is rejected as a fingerprint mismatch")
    func sameKeyDifferentBodyRejected() async throws {
        let store = InMemoryIdempotencyStore()
        let sut = makeSUT(store: store)
        let key = try IdempotencyKey("k-mismatch")
        let id = try recordId(forKey: key.rawValue)
        // A completed record exists for a *different* body.
        let otherFingerprint = try RequestFingerprint(payload: command("ORIGINAL body").payload)
        await store.seedCompleted(
            id: id,
            fingerprint: otherFingerprint,
            response: StoredResponse(status: 200, body: Data())
        )

        await #expect(throws: IdempotencyError.fingerprintMismatch(key: "k-mismatch")) {
            try await RequestContext.$idempotencyKey.withValue(key) {
                try await sut.handle(command("DIFFERENT body"))
            }
        }
        #expect(sut.callCount == 0)
    }

    // MARK: - No key → transparent pass-through

    @Test("request without an Idempotency-Key runs normally and stores nothing")
    func noKeyPassesThrough() async throws {
        let store = InMemoryIdempotencyStore()
        let sut = makeSUT(store: store)

        // No RequestContext.idempotencyKey set.
        let result = try await sut.handle(command("plain"))

        #expect(result == TestResult(echoed: "plain"))
        #expect(sut.callCount == 1)
        #expect(await store.count == 0)   // no record written
    }

    // MARK: - Expired record is re-executed (TTL)

    @Test("expired record is treated as absent and the work runs again")
    func expiredRecordReExecutes() async throws {
        let store = InMemoryIdempotencyStore()
        let sut = makeSUT(store: store)
        let key = try IdempotencyKey("k-expired")
        let id = try recordId(forKey: key.rawValue)
        let fingerprint = try RequestFingerprint(payload: command("body").payload)
        // A completed record whose TTL already elapsed.
        await store.seedCompleted(
            id: id,
            fingerprint: fingerprint,
            response: StoredResponse(status: 200, body: try JSONEncoder().encode(TestResult(echoed: "STALE"))),
            expiresAt: Date(timeIntervalSince1970: 0)
        )

        let result = try await RequestContext.$idempotencyKey.withValue(key) {
            try await sut.handle(command("body"))
        }

        #expect(sut.callCount == 1)              // re-executed, not replayed
        #expect(result == TestResult(echoed: "body"))
    }

    // MARK: - Overridden fingerprint(for:) folds in out-of-payload identity

    /// The record id for `key` under the default scope, for `ScopedCommand`.
    private func scopedRecordId(forKey key: String) throws -> String {
        configuration.scope.recordId(
            key: try IdempotencyKey(key),
            commandType: String(reflecting: ScopedCommand.self),
            principalId: nil
        )
    }

    @Test("overridden fingerprint rejects the same key reused against a different resource")
    func overriddenFingerprintRejectsDifferentResource() async throws {
        let store = InMemoryIdempotencyStore()
        let sut = ScopedHandler(idempotency: IdempotencyComponents(
            storeFactory: { _ in store },
            configuration: configuration
        ))
        let key = try IdempotencyKey("k-scoped")
        let id = try scopedRecordId(forKey: key.rawValue)
        let payload = ScopedCommand.Payload(value: "body")
        // A completed record exists for resource "A" with this exact body...
        let fingerprintA = try RequestFingerprint(payload: ScopedFingerprint(resourceId: "A", payload: payload))
        await store.seedCompleted(
            id: id,
            fingerprint: fingerprintA,
            response: StoredResponse(status: 200, body: Data())
        )

        // ...a retry with the SAME key and SAME payload but resource "B" must be a
        // mismatch — the override folds resourceId into the fingerprint, so it does
        // not silently replay resource A's response. (The default payload-only scope
        // would have matched and mis-replayed.)
        await #expect(throws: IdempotencyError.fingerprintMismatch(key: "k-scoped")) {
            try await RequestContext.$idempotencyKey.withValue(key) {
                try await sut.handle(ScopedCommand(resourceId: "B", payload: payload))
            }
        }
        #expect(sut.callCount == 0)
    }

    @Test("overridden fingerprint replays when the same resource is retried")
    func overriddenFingerprintReplaysSameResource() async throws {
        let store = InMemoryIdempotencyStore()
        let sut = ScopedHandler(idempotency: IdempotencyComponents(
            storeFactory: { _ in store },
            configuration: configuration
        ))
        let key = try IdempotencyKey("k-scoped-same")

        let first = try await RequestContext.$idempotencyKey.withValue(key) {
            try await sut.handle(ScopedCommand(resourceId: "A", payload: .init(value: "body")))
        }
        // Same key, same resource, same body → replay without re-running.
        let second = try await RequestContext.$idempotencyKey.withValue(key) {
            try await sut.handle(ScopedCommand(resourceId: "A", payload: .init(value: "body")))
        }

        #expect(first == second)
        #expect(sut.callCount == 1)
    }
}
