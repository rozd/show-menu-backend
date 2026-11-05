import Vapor

extension ExpirationSummary: Content {}

/// `POST /api/v1/subscriptions/jobs/check-expired`: the daily Cloud Scheduler job. Guarded by
/// ``SchedulerAuthMiddleware`` (not by a user token). Answers `{scanned, expired, expiring, reconciled}`.
///
/// Optional query `reconcileDays` (1...365) widens the reconcile look-back for a one-off catch-up
/// run (for example the pre-cutover drain); the scheduled job omits it (default 7 days).
struct SubscriptionJobController: Sendable {

    let job: CheckExpiredSubscriptionsJob

    @Sendable
    func checkExpired(req: Request) async throws -> ExpirationSummary {
        var window: TimeInterval?
        if let raw = req.query[String.self, at: "reconcileDays"] {
            guard let days = Int(raw), (1...365).contains(days) else {
                throw Abort(.unprocessableEntity, reason: "reconcileDays must be between 1 and 365")
            }
            window = TimeInterval(days) * CheckExpiredSubscriptionsJob.day
        }
        return try await job.run(reconcileWindow: window)
    }
}
