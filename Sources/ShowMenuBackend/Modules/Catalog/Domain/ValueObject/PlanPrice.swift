import Foundation

/// A plan's price for one billing period. Mirrors Node's `PlanPrice`:
/// `{price: {currency, amount}, duration}`.
struct PlanPrice: Sendable, Hashable, Codable {
    let price: Price
    let duration: SubscriptionDuration
}
