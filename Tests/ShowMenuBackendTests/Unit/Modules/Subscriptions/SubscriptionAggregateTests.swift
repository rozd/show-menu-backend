import Foundation
import Testing
@testable import ShowMenuBackend

@Suite("Subscription aggregate")
struct SubscriptionAggregateTests {
    typealias F = SubscriptionFixtures

    private let now = Date(timeIntervalSince1970: 1_770_000_000) // 2026-02-02T02:40:00Z
    private let future = Date(timeIntervalSince1970: 1_772_000_000)
    private let past = Date(timeIntervalSince1970: 1_760_000_000)

    private func sub(_ status: SubscriptionStatus, expiresAt: Date? = nil) -> Subscription {
        F.subscription(status: status, expiresAt: expiresAt ?? future)
    }

    /// Drives the behavior method that targets `status`.
    private func apply(_ target: SubscriptionStatus, to subscription: Subscription) throws -> Bool {
        switch target {
        case .active: try subscription.extend(by: .monthly, paymentRef: "tx-new", now: now)
        case .suspended: try subscription.suspend(reason: "Payment failed", now: now)
        case .cancelled: try subscription.cancel(reason: "Payment refunded", now: now)
        case .expired: try subscription.expire(now: now)
        }
    }

    private static let validEdges: [(SubscriptionStatus, SubscriptionStatus, SubscriptionEventKind)] = [
        (.active, .expired, .subscriptionExpired),
        (.expired, .active, .subscriptionActivated),
        (.active, .suspended, .subscriptionSuspended),
        (.suspended, .active, .subscriptionActivated),
        (.active, .cancelled, .subscriptionCancelled),
        (.suspended, .cancelled, .subscriptionCancelled),
    ]

    @Test("every valid edge transitions and records exactly its semantic event", arguments: validEdges)
    func validTransition(edge: (SubscriptionStatus, SubscriptionStatus, SubscriptionEventKind)) throws {
        let subscription = sub(edge.0)
        #expect(try apply(edge.1, to: subscription) == true)
        #expect(subscription.status == edge.1)
        #expect(subscription.pullEvents().map(\.kind) == [edge.2])
    }

    private static let invalidEdges: [(SubscriptionStatus, SubscriptionStatus)] = {
        let valid = Set(validEdges.map { "\($0.0)->\($0.1)" })
        return SubscriptionStatus.allCases.flatMap { from in
            SubscriptionStatus.allCases.compactMap { to in
                from != to && !valid.contains("\(from)->\(to)") ? (from, to) : nil
            }
        }
    }()

    @Test("every other edge throws and mutates nothing, expiresAt included (bug 8)", arguments: invalidEdges)
    func invalidTransition(edge: (SubscriptionStatus, SubscriptionStatus)) throws {
        let subscription = F.subscription(
            status: edge.0, expiresAt: future,
            suspensionReason: edge.0 == .suspended ? "kept" : nil, cancellationReason: edge.0 == .cancelled ? "kept" : nil
        )
        let before = (subscription.expiresAt, subscription.updatedAt, subscription.lastPaymentRef,
                      subscription.suspensionReason, subscription.cancellationReason)

        #expect(throws: InvalidStatusTransitionError.self) { try apply(edge.1, to: subscription) }

        #expect(subscription.status == edge.0)
        #expect(subscription.expiresAt == before.0 && subscription.updatedAt == before.1)
        #expect(subscription.lastPaymentRef == before.2)
        #expect(subscription.suspensionReason == before.3 && subscription.cancellationReason == before.4)
        #expect(subscription.pullEvents().isEmpty)
    }

    @Test("a repeated suspend / cancel / expire is a silent no-op")
    func sameStatusNoOps() throws {
        #expect(try sub(.suspended).suspend(reason: "again", now: now) == false)
        #expect(try sub(.cancelled).cancel(reason: "again", now: now) == false)
        #expect(try sub(.expired).expire(now: now) == false)
        let suspended = sub(.suspended)
        _ = try suspended.suspend(reason: "again", now: now)
        #expect(suspended.pullEvents().isEmpty && suspended.suspensionReason == nil)
    }

    @Test("a cancelled subscription refuses a late payment and keeps its expiry (bug 8)")
    func cancelledRefusesExtension() throws {
        let cancelled = F.subscription(status: .cancelled, expiresAt: past, cancellationReason: "Payment refunded")
        #expect(throws: InvalidStatusTransitionError.self) {
            try cancelled.extend(by: .yearly, paymentRef: "tx-late", now: now)
        }
        #expect(cancelled.expiresAt == past && cancelled.lastPaymentRef == nil)
        #expect(cancelled.cancellationReason == "Payment refunded")
    }

    // MARK: Id

    @Test("the id is derived from the order: order-<uuid> -> sub:<uuid>")
    func derivedId() {
        #expect(Subscription.Id.derive(orderId: "order-0a1b-23").rawValue == "sub:0a1b-23")
        #expect(Subscription.Id.derive(orderId: "odd").rawValue == "sub:odd")
        #expect(Subscription.Id.derive(orderId: "order-x") == Subscription.Id.derive(orderId: "order-x"))
    }

    @Test("activate creates an active subscription for one period with the derived id and an activated event")
    func activate() throws {
        let created = try Subscription.activate(
            accountId: "a1", orderId: "order-1", planId: "plan-1", duration: .monthly, paymentRef: "tx-1", now: now
        )
        #expect(created.id.rawValue == "sub:1" && created.status == .active)
        #expect(created.startedAt == now && created.createdAt == now)
        #expect(created.expiresAt == SubscriptionDuration.monthly.add(to: now))
        #expect(created.suspensionReason == nil && created.cancellationReason == nil)
        #expect(created.lastPaymentRef == "tx-1")
        #expect(created.pullEvents().map(\.kind) == [.subscriptionActivated])
    }

    @Test("activate validates its inputs")
    func activateValidation() {
        #expect(throws: Subscription.Error.accountRequired) {
            try Subscription.activate(accountId: "", orderId: "o", planId: "p", duration: .daily, paymentRef: nil)
        }
        #expect(throws: Subscription.Error.orderRequired) {
            try Subscription.activate(accountId: "a", orderId: "", planId: "p", duration: .daily, paymentRef: nil)
        }
        #expect(throws: Subscription.Error.planRequired) {
            try Subscription.activate(accountId: "a", orderId: "o", planId: "", duration: .daily, paymentRef: nil)
        }
    }

    // MARK: Extension math

    @Test("a payment on an unexpired subscription adds one period to the current expiry (no event)")
    func extendActive() throws {
        let subscription = sub(.active, expiresAt: future)
        #expect(try subscription.extend(by: .monthly, paymentRef: "tx-2", now: now))
        #expect(subscription.expiresAt == SubscriptionDuration.monthly.add(to: future))
        #expect(subscription.status == .active && subscription.lastPaymentRef == "tx-2")
        #expect(subscription.pullEvents().isEmpty)
    }

    @Test("a payment on a lapsed subscription restarts the period at now and reactivates it")
    func extendExpired() throws {
        let subscription = sub(.expired, expiresAt: past)
        #expect(try subscription.extend(by: .weekly, paymentRef: "tx-2", now: now))
        #expect(subscription.expiresAt == SubscriptionDuration.weekly.add(to: now))
        #expect(subscription.status == .active)
        #expect(subscription.pullEvents().map(\.kind) == [.subscriptionActivated])
    }

    @Test("a payment reactivates a suspended subscription from its (unexpired) expiry and clears the reasons")
    func extendSuspended() throws {
        let subscription = F.subscription(status: .suspended, expiresAt: future, suspensionReason: "Payment failed")
        #expect(try subscription.extend(by: .monthly, paymentRef: "tx-2", now: now))
        #expect(subscription.status == .active && subscription.suspensionReason == nil)
        #expect(subscription.expiresAt == SubscriptionDuration.monthly.add(to: future))
    }

    @Test("the same payment reference is applied once")
    func extendIdempotent() throws {
        let subscription = sub(.active, expiresAt: future)
        #expect(try subscription.extend(by: .monthly, paymentRef: "tx-2", now: now))
        let once = subscription.expiresAt
        #expect(try subscription.extend(by: .monthly, paymentRef: "tx-2", now: now) == false)
        #expect(subscription.expiresAt == once)
    }

    @Test("suspend and cancel record the reason and touch nothing else")
    func reasons() throws {
        let suspended = sub(.active)
        try suspended.suspend(reason: "Payment failed", now: now)
        #expect(suspended.suspensionReason == "Payment failed" && suspended.expiresAt == future)
        let cancelled = sub(.suspended)
        try cancelled.cancel(reason: "Payment cancelled", now: now)
        #expect(cancelled.cancellationReason == "Payment cancelled" && cancelled.expiresAt == future)
    }
}
