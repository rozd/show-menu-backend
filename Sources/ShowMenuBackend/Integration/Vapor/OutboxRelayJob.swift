//
//  OutboxRelayJob.swift
//  ShowMenuBackend
//
//  Vapor Queues scheduled job that drains the transactional outbox.
//

import Foundation
import Vapor
import Queues

/// Vapor Queues scheduled job that drains the outbox on a fixed cadence.
///
/// A thin shell over the portable ``OutboxRelay``: it owns no logic, just invokes
/// `relay.drain()` on each scheduled tick. Registered/scheduled in
/// `App/Outbox+Vapor.swift`.
///
/// > Alternative relay: a Firestore Cloud Function triggered on outbox-document
/// > creation could publish rows with lower latency. The polling job here is the
/// > portable default (no Functions deployment, works against any store).
struct OutboxRelayJob: AsyncScheduledJob {
    let relay: OutboxRelay

    func run(context: QueueContext) async throws {
        _ = await relay.drain()
    }
}
