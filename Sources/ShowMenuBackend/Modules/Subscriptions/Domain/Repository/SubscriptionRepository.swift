import Foundation

protocol SubscriptionRepository: Repository
where Entity == Subscription, Model == SubscriptionModel, DTO == SubscriptionDTO {

    /// Subscriptions live under `accounts/{accountId}/subscriptions`, so a lookup needs the account.
    /// (`fetch(byId:)` from `Repository` cannot address a sub-collection and throws.)
    func fetch(accountId: String, id: Subscription.Id) async throws -> Subscription?

    /// The subscription of an order: the deterministic id first (a transactional `get`), then,
    /// for subscriptions Node created under a random `sub:<uuid>` id, a **direct** query on
    /// `orderId` (the pinned client cannot query inside a transaction, roadmap S05).
    func find(accountId: String, orderId: String) async throws -> Subscription?
}
