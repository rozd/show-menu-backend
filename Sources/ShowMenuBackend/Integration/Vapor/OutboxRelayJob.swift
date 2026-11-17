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
/// > Alternative relays: a change-stream / CDC trigger firing on outbox-row
/// > insertion, or an external scheduler hitting a drain endpoint, would publish
/// > with lower latency. The polling job here is the portable default — it needs
/// > no store-specific trigger mechanism and no extra deployment unit.
struct OutboxRelayJob: AsyncScheduledJob {
    let relay: OutboxRelay

    func run(context: QueueContext) async throws {
        _ = await relay.drain()
    }
}
