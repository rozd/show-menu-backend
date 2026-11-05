//
//  IdempotentCommandHandler.swift
//  VaporFirebaseBackendApp
//
//  A CommandHandler-refining protocol implementing inbound command de-duplication.
//

import Foundation

/// Store factory + policy a handler needs to be idempotent. Bundled so an
/// idempotent handler grows by exactly one stored property.
struct IdempotencyComponents: Sendable {

    /// Builds an ``IdempotencyStore`` bound to the *same* `UnitOfWorkContext`
    /// (and therefore the same transaction) the wrapped work uses — mirroring how
    /// a repository resolves its data source from `ctx.transaction`.
    let storeFactory: IdempotencyStoreFactory

    let configuration: IdempotencyConfiguration

    init(
        storeFactory: @escaping IdempotencyStoreFactory,
        configuration: IdempotencyConfiguration = .default
    ) {
        self.storeFactory = storeFactory
        self.configuration = configuration
    }
}

/// A ``CommandHandler`` that de-duplicates retried inbound commands, keyed on the
/// request's `Idempotency-Key` (read from ``RequestContext/idempotencyKey``).
///
/// Opt in by **conforming**: a handler implements only ``CommandHandler/perform(_:in:)``
/// (the real work) plus the ``idempotency`` components, and inherits the default
/// ``handle(_:)`` below — which means reserve, the work, and the record write
/// **all run inside the handler's single `UnitOfWork` transaction**. That is the
/// crux of the atomicity guarantee: the de-duplication record and the command's
/// writes commit or roll back together, so a crash can never leave
/// "marked-but-not-done" or "done-but-not-marked".
///
/// Because this protocol *refines* ``CommandHandler``, its ``handle(_:)`` default
/// is more specialized than the base one and is selected for conformers — so the
/// idempotency wrapping happens automatically without any decorator/erasure.
protocol IdempotentCommandHandler: CommandHandler where Result: Codable {

    var idempotency: IdempotencyComponents { get }

    /// The request scope a reused idempotency key must match for the stored
    /// response to be replayed. A retry whose scope differs is rejected as a
    /// ``IdempotencyError/fingerprintMismatch(key:)`` rather than replaying the
    /// first call's response.
    ///
    /// Defaults to the command's `payload`. **Caveat:** the record id is keyed on
    /// `(principalId, commandType, key)`, so identity carried *outside* the
    /// payload — e.g. a route/path parameter like `UpdateItemCommand.itemId` — is
    /// **not** in the default fingerprint. A key reused with the same body but a
    /// different path parameter would then replay the wrong resource's response
    /// (silent wrong-data, not a 422). Well-behaved clients mint a fresh key per
    /// logical operation, so this only bites on a client bug — but handlers whose
    /// command carries out-of-payload identity should **override** this to fold
    /// those fields in, turning the silent mis-replay into a clean mismatch.
    func fingerprint(for command: Params) throws -> RequestFingerprint
}

extension IdempotentCommandHandler {

    /// Default scope: the command payload only. See the protocol requirement for
    /// when a handler should override this.
    func fingerprint(for command: Params) throws -> RequestFingerprint {
        try RequestFingerprint(payload: command.payload)
    }


    /// Opens the `UnitOfWork` and runs the reserve → work → store sequence inside
    /// one transaction, so the de-duplication record and the command's writes
    /// share a single commit / rollback.
    func handle(_ command: Params) async throws -> Result {
        try await unitOfWork.execute { context in
            try await performIdempotently(command, in: context)
        }
    }

    /// The cross-cutting body. Ordering matters because the Firestore binding
    /// forbids reads after writes, so the protocol is strictly read-then-write:
    ///
    /// 1. **reserve** (read) — probe the slot *before* the work touches the
    ///    transaction.
    /// 2. on `.replay` → return the stored response, **without** running the work.
    /// 3. on `.inProgress` / `.mismatch` → reject (the work never runs).
    /// 4. on `.proceed` → run the real work, then **complete** (write) the record
    ///    as the last write in the transaction; the transactional `create`'s
    ///    uniqueness precondition is the in-flight guard for the new-key race.
    ///
    /// A request with no key behaves exactly like a plain handler.
    private func performIdempotently(_ command: Params, in context: any UnitOfWorkContext) async throws -> Result {
        // No key on this request → transparent pass-through.
        guard let key = RequestContext.idempotencyKey else {
            return try await perform(command, in: context)
        }

        let store = idempotency.storeFactory(context)
        let id = idempotency.configuration.scope.recordId(
            key: key,
            commandType: String(reflecting: Params.self),
            principalId: RequestContext.principal?.id
        )
        // `self.` disambiguates the overridable method from the local binding.
        let fingerprint = try self.fingerprint(for: command)

        // READ phase: must precede any write in the transaction.
        switch try await store.reserve(id: id, fingerprint: fingerprint) {

        case .replay(let stored):
            // Return what the first call returned — no re-execution.
            return try JSONDecoder().decode(Result.self, from: stored.body)

        case .inProgress:
            switch idempotency.configuration.inFlight {
            case .rejectConflict:
                throw IdempotencyError.requestInProgress(key: key.rawValue)
            }

        case .mismatch:
            throw IdempotencyError.fingerprintMismatch(key: key.rawValue)

        case .proceed(let ticket):
            // Run the real work (its reads, then its writes)...
            let result = try await perform(command, in: context)
            // ...then persist the record as the final write in the same transaction.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let body = try encoder.encode(result)
            // `status: 200` is an intentional advisory default at this altitude: the
            // handler does not know (and must not learn) the transport status. The
            // controller deterministically re-derives the concrete status from the
            // Result type on replay (e.g. 201 for a create), so this value is never
            // read on the reply path — only `body` is. See StoredResponse's doc-comment.
            try await store.complete(
                ticket: ticket,
                response: StoredResponse(status: 200, body: body)
            )
            return result
        }
    }
}
