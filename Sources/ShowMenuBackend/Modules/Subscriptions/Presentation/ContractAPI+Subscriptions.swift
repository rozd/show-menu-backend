import ShowMenuContracts

/// Subscriptions' witnesses: the legacy cancel stub and the daily expiration job.
extension ContractAPI {

    /// Legacy no-op stub kept for client compatibility: answers the JSON string `"OK"` and changes
    /// nothing (subscriptions end through expiration).
    func cancelSubscription(
        _ input: Operations.CancelSubscription.Input
    ) async throws -> Operations.CancelSubscription.Output {
        .ok(.init(body: .json(.ok)))
    }

    func checkExpiredSubscriptions(
        _ input: Operations.CheckExpiredSubscriptions.Input
    ) async throws -> Operations.CheckExpiredSubscriptions.Output {
        try await SubscriptionJobController(job: app.deps.checkExpiredSubscriptionsJob).checkExpired(input)
    }
}
