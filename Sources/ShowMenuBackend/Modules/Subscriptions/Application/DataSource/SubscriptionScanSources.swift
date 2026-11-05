import Foundation

/// A subscription found by the expiration scan: enough to open a unit of work on it.
struct SubscriptionReference: Sendable, Equatable {
    let accountId: String
    let id: Subscription.Id
    let expiresAt: Date
}

/// Read side of the expiration job: `active` subscriptions across **all** accounts.
///
/// A direct (non-transactional) query, so it is a *stale snapshot*: the job re-reads every hit
/// inside its own unit of work before acting (S05: the pinned client cannot query in a transaction).
protocol ExpiringSubscriptionSource: Sendable {
    /// `status == active && expiresAt <= cutoff`, oldest `expiresAt` first, at most `limit`.
    func activeSubscriptions(expiringBy cutoff: Date, limit: Int) async throws -> [SubscriptionReference]
}

/// Read side of the reconcile pass: recently updated `paid` invoices (top-level `invoices`).
protocol PaidInvoiceSource: Sendable {
    /// `status == paid && updatedAt >= since`, most recently updated first, at most `limit`.
    func paidInvoices(updatedSince since: Date, limit: Int) async throws -> [Invoice.Id]
}
