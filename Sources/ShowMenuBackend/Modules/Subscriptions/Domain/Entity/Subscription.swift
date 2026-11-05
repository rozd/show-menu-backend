import Foundation

/// An account's subscription to a plan (`accounts/{accountId}/subscriptions/{id}`).
///
/// FSM (Node `Subscription.fsm`): `active -> expired | suspended | cancelled`,
/// `expired -> active`, `suspended -> active | cancelled`. An invalid transition throws
/// ``InvalidStatusTransitionError`` **before** anything is mutated (roadmap bug 8: Node set
/// `expiresAt` even when the transition was refused and swallowed the error). A transition to
/// the current status is an idempotent no-op (`false`, no event).
///
/// The id is derived from the order (``Id/derive(orderId:)``), so activating the same order
/// twice addresses the same document and the `create` precondition leaves exactly one (bug 2).
/// Legacy `sub:<uuid>` ids decode as-is.
final class Subscription: AggregateRoot, @unchecked Sendable {
    typealias Event = SubscriptionEvent

    let id: Subscription.Id
    let events: DomainEventRecorder<Event> = .init()

    /// Opaque optimistic-concurrency token; set by the persistence layer.
    var version: Version = .none

    let planId: String
    let orderId: String
    let accountId: String
    private(set) var status: SubscriptionStatus
    private(set) var startedAt: Date
    private(set) var expiresAt: Date
    private(set) var suspensionReason: String?
    private(set) var cancellationReason: String?
    /// The payment (LiqPay transaction/payment id, or `<invoiceId>:paid` when LiqPay sent none)
    /// that last extended this subscription: re-running a handler on the same payment is a no-op.
    /// Additive field (Flutter ignores it); absent on legacy documents.
    private(set) var lastPaymentRef: String?
    private(set) var createdAt: Date
    private(set) var updatedAt: Date

    /// Rehydration initializer (no validation, no events): used by the mapper.
    init(
        id: Subscription.Id,
        planId: String,
        orderId: String,
        accountId: String,
        status: SubscriptionStatus,
        startedAt: Date,
        expiresAt: Date,
        suspensionReason: String? = nil,
        cancellationReason: String? = nil,
        lastPaymentRef: String? = nil,
        version: Version = .none,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.planId = planId
        self.orderId = orderId
        self.accountId = accountId
        self.status = status
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.suspensionReason = suspensionReason
        self.cancellationReason = cancellationReason
        self.lastPaymentRef = lastPaymentRef
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// A new `active` subscription for `orderId`, valid for one `duration` from `now`
    /// (Node `Subscription.create` + `activate`). Raises `subscription.activated`.
    static func activate(
        accountId: String, orderId: String, planId: String, duration: SubscriptionDuration,
        paymentRef: String?, now: Date = .now
    ) throws -> Subscription {
        guard !accountId.isEmpty else { throw Error.accountRequired }
        guard !orderId.isEmpty else { throw Error.orderRequired }
        guard !planId.isEmpty else { throw Error.planRequired }
        let subscription = Subscription(
            id: .derive(orderId: orderId), planId: planId, orderId: orderId, accountId: accountId,
            status: .active, startedAt: now, expiresAt: duration.add(to: now),
            lastPaymentRef: paymentRef, createdAt: now, updatedAt: now
        )
        subscription.record(event: .semantic(.subscriptionActivated, aggregateId: subscription.id, occurredAt: now))
        return subscription
    }

    // MARK: Transitions

    /// A payment extends the subscription by one `duration`, counted from the later of `now` and
    /// the current `expiresAt` (a payment never shortens paid time, a lapsed period restarts at
    /// `now`). A `suspended` or `expired` subscription is reactivated by it (`subscription.activated`).
    ///
    /// Idempotent per payment: the same `paymentRef` as the last applied one changes nothing
    /// (`false`). A `cancelled` subscription cannot be reactivated: throws
    /// ``InvalidStatusTransitionError`` and nothing is mutated.
    @discardableResult
    func extend(by duration: SubscriptionDuration, paymentRef: String?, now: Date = .now) throws -> Bool {
        if let paymentRef, paymentRef == lastPaymentRef { return false }
        let activated = try validatedMove(to: .active)
        expiresAt = duration.add(to: max(now, expiresAt))
        suspensionReason = nil
        cancellationReason = nil
        if let paymentRef { lastPaymentRef = paymentRef }
        status = .active
        updatedAt = now
        if activated {
            record(event: .semantic(.subscriptionActivated, aggregateId: id, occurredAt: now))
        }
        return true
    }

    /// `active -> suspended` with a reason. Already suspended -> `false`.
    @discardableResult
    func suspend(reason: String, now: Date = .now) throws -> Bool {
        guard try validatedMove(to: .suspended) else { return false }
        status = .suspended
        suspensionReason = reason
        updatedAt = now
        record(event: .semantic(.subscriptionSuspended, aggregateId: id, occurredAt: now))
        return true
    }

    /// `active | suspended -> cancelled` with a reason. Already cancelled -> `false`.
    @discardableResult
    func cancel(reason: String, now: Date = .now) throws -> Bool {
        guard try validatedMove(to: .cancelled) else { return false }
        status = .cancelled
        cancellationReason = reason
        updatedAt = now
        record(event: .semantic(.subscriptionCancelled, aggregateId: id, occurredAt: now))
        return true
    }

    /// `active -> expired` (the expiration job, S15). Already expired -> `false`.
    @discardableResult
    func expire(now: Date = .now) throws -> Bool {
        guard try validatedMove(to: .expired) else { return false }
        status = .expired
        updatedAt = now
        record(event: .semantic(.subscriptionExpired, aggregateId: id, occurredAt: now))
        return true
    }

    /// Checks the edge against the FSM without changing anything. `false` = already there.
    private func validatedMove(to target: SubscriptionStatus) throws -> Bool {
        guard status != target else { return false }
        var fsm = FiniteStateMachine(initial: status, transitions: Subscription.transitions)
        do {
            try fsm.transition(to: target)
        } catch {
            throw InvalidStatusTransitionError(
                aggregate: "subscription", id: id.rawValue, from: status.rawValue, to: target.rawValue
            )
        }
        return true
    }

    static let transitions: [StateTransition<SubscriptionStatus>] = [
        .init(source: .active, target: .expired),
        .init(source: .expired, target: .active),
        .init(source: .active, target: .suspended),
        .init(source: .suspended, target: .active),
        .init(source: .active, target: .cancelled),
        .init(source: .suspended, target: .cancelled),
    ]
}

extension Subscription {

    /// `sub:<uuid>` for legacy (Node) documents; `sub:<order uuid>` for the ones Vapor creates.
    struct Id: EntityId {
        static let prefix = "sub:"

        let rawValue: String
        init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// The deterministic id of the subscription of `orderId` (`order-<uuid>` -> `sub:<uuid>`;
        /// any other order id is appended whole).
        static func derive(orderId: String) -> Id {
            let orderPrefix = Order.Id.prefix
            let tail = orderId.hasPrefix(orderPrefix) ? String(orderId.dropFirst(orderPrefix.count)) : orderId
            return Id(rawValue: prefix + tail)
        }
    }

    enum Error: ValidationError, LocalizedError, Equatable {
        case accountRequired
        case orderRequired
        case planRequired

        var errorDescription: String? {
            switch self {
            case .accountRequired: "Account ID is required"
            case .orderRequired: "Order ID is required"
            case .planRequired: "Plan ID is required"
            }
        }
    }
}

/// Raw values are the stored strings (and the names Flutter's `SubscriptionStatus` parses).
enum SubscriptionStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case active, expired, cancelled, suspended
}
