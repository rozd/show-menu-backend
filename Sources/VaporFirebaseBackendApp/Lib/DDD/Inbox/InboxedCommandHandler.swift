//
//  InboxedCommandHandler.swift
//  VaporFirebaseBackendApp
//
//  A CommandHandler-refining protocol implementing consumer-side event de-duplication.
//

import Foundation

/// What a handler needs to be inbox-deduplicating. Bundled so an inboxed
/// handler grows by exactly one stored property.
///
/// There is deliberately no per-handler ``InboxConfiguration`` here: the only
/// policy (retention TTL) is a property of the *store*, so it is applied once,
/// where the store factory is built (`CompositionRoot.inboxStoreFactory` reads
/// the app-level `inboxConfiguration`). A second copy here could silently
/// disagree with the one the store actually uses.
struct InboxComponents: Sendable {

    /// Builds an ``InboxStore`` bound to the *same* `UnitOfWorkContext`
    /// (and therefore the same transaction) the wrapped work uses — mirroring how
    /// a repository resolves its data source from `ctx.transaction`.
    let storeFactory: InboxStoreFactory

    init(storeFactory: @escaping InboxStoreFactory) {
        self.storeFactory = storeFactory
    }
}

/// A ``CommandHandler`` that de-duplicates integration events by id, keyed on the
/// event's `IntegrationEvent.id` (read from ``RequestContext/integrationEventId``).
/// Handler invocations outside of event dispatch (no task-local) transparently
/// skip de-duplication.
///
/// Opt in by **conforming**: a handler implements only ``CommandHandler/perform(_:in:)``
/// (the real work) plus the ``inbox`` components, and inherits the default
/// ``handle(_:)`` below — which means reserve, the work, and the record write
/// **all run inside the handler's single `UnitOfWork` transaction**. That is the
/// crux of the atomicity guarantee: the processed-event marker and the handler's
/// writes commit or roll back together, so a crash can never leave
/// "marked-but-not-done" or "done-but-not-marked".
///
/// Because this protocol *refines* ``CommandHandler``, its ``handle(_:)`` default
/// is more specialized than the base one and is selected for conformers — so the
/// inbox wrapping happens automatically without any decorator/erasure.
///
/// **Concurrent duplicate semantics:** when two deliveries of the same event
/// race, both probe an empty slot and run the work, but only one `create` can
/// satisfy the `exists == false` precondition, which Firestore enforces at
/// commit. The loser's commit fails, and the Firestore transaction runner
/// retries the whole closure (it retries any error, with backoff, up to its
/// attempt limit). On the retry `reserve` sees the winner's committed marker
/// and returns `.alreadyProcessed`, so the loser skips silently and the
/// transaction commits with no writes. The winner did the work, so this is
/// correct by outcome. Only if the commit conflict persists through every
/// attempt does an error escape (a mapped `FirestoreError`, logged and swallowed
/// by the dispatcher). A later redelivery observes the committed marker and
/// skips cleanly.
protocol InboxedCommandHandler: CommandHandler where Result == Void {

    var inbox: InboxComponents { get }
}

extension InboxedCommandHandler {

    /// Opens the `UnitOfWork` and runs the reserve → work → complete sequence
    /// inside one transaction, so the processed-event marker and the handler's
    /// writes share a single commit / rollback.
    func handle(_ command: Params) async throws -> Void {
        try await unitOfWork.execute { context in
            try await performWithInbox(command, in: context)
        }
    }

    /// The cross-cutting body. Ordering matters because the store contract is
    /// strictly read-then-write (many stores forbid a read after a transaction
    /// has buffered writes — see ``InboxStore``):
    ///
    /// 1. **reserve** (read) — probe the slot *before* the work touches the
    ///    transaction.
    /// 2. on `.alreadyProcessed` → return silently, **without** running the work.
    /// 3. on `.proceed` → run the real work, then **complete** (write) the record
    ///    as the last write in the transaction; the transactional `create`'s
    ///    uniqueness precondition is the in-flight guard for the new-event race.
    ///
    /// A request with no event id behaves exactly like a plain handler.
    private func performWithInbox(_ command: Params, in context: any UnitOfWorkContext) async throws -> Void {
        // No event id on this invocation → transparent pass-through.
        guard let eventId = RequestContext.integrationEventId else {
            return try await perform(command, in: context)
        }

        let store = inbox.storeFactory(context)
        let id = InboxRecordId.derive(
            consumer: String(reflecting: Params.self),
            eventId: eventId
        )

        // READ phase: must precede any write in the transaction.
        switch try await store.reserve(id: id) {

        case .alreadyProcessed:
            // Event already processed — skip the work.
            return

        case .proceed(let ticket):
            // Run the real work (its reads, then its writes)...
            try await perform(command, in: context)
            // ...then persist the marker as the final write in the same transaction.
            try await store.complete(ticket: ticket)
        }
    }
}
