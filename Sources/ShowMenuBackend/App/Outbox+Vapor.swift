//
//  Outbox+Vapor.swift
//  ShowMenuBackend
//
//  App wiring for the transactional-outbox relay.
//

import Vapor
import Queues

extension Application {

    /// Register and start the transactional-outbox relay as a Vapor Queues
    /// scheduled job.
    ///
    /// **Opt-in**, like the other queue building blocks in this template (it is
    /// intentionally *not* called from `configure`). Add this to `configure(_:)`
    /// once a module actually records integration events through
    /// `context.outbox`:
    ///
    /// ```swift
    /// // in configure(_:)
    /// try app.startOutboxRelay()
    /// ```
    ///
    /// Notes:
    /// - The recording side (`UnitOfWorkContext.outbox`) is always wired; nothing
    ///   is published until a relay drains the outbox, so pair this with the first
    ///   use case that records.
    /// - Scheduled jobs run in-process on the event loop; no Queues *driver* is
    ///   required for the relay alone. A driver is only needed if you also
    ///   `dispatch` queue jobs elsewhere.
    /// - `.minutely()` is the finest stock cadence. For lower-latency delivery,
    ///   drive `deps.outboxRelay.drain()` from a tighter source (e.g. Cloud
    ///   Scheduler hitting an endpoint, or a Firestore Cloud Function trigger on
    ///   outbox-document creation).
    func startOutboxRelay() throws {
        queues.schedule(OutboxRelayJob(relay: deps.outboxRelay))
            .minutely()
            .at(0)
        try queues.startScheduledJobs()
        logger.info("Outbox relay scheduled", metadata: [
            "collection": .string(deps.outbox.collection)
        ])
    }
}
