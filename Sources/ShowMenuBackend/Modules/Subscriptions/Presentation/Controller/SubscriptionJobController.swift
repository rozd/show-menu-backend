import Foundation
import ShowMenuContracts
import Vapor

/// `checkExpiredSubscriptions`: the daily Cloud Scheduler job. Authenticated by
/// `ContractAccessMiddleware` (scheduler access), not by a user token. Answers
/// `{scanned, expired, expiring, reconciled}`.
///
/// Optional query `reconcileDays` (1...365) widens the reconcile look-back for a one-off catch-up
/// run (for example the pre-cutover drain); the scheduled job omits it (default 7 days). The
/// generator does not enforce the spec's `minimum`/`maximum`, so the range is checked here.
struct SubscriptionJobController: Sendable {

    let job: CheckExpiredSubscriptionsJob

    func checkExpired(
        _ input: Operations.CheckExpiredSubscriptions.Input
    ) async throws -> Operations.CheckExpiredSubscriptions.Output {
        var window: TimeInterval?
        if let days = input.query.reconcileDays {
            guard (1...365).contains(days) else {
                throw Abort(.unprocessableEntity, reason: "reconcileDays must be between 1 and 365")
            }
            window = TimeInterval(days) * CheckExpiredSubscriptionsJob.day
        }
        let summary = try await job.run(reconcileWindow: window)
        return .ok(.init(body: .json(.init(
            scanned: summary.scanned,
            expired: summary.expired,
            expiring: summary.expiring,
            reconciled: summary.reconciled
        ))))
    }
}
