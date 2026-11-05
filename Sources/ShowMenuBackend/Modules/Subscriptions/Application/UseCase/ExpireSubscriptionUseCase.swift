import Foundation
import Logging

/// One subscription of the expiration job, in its own unit of work.
///
/// Re-reads the subscription through the transaction (the scan was a stale snapshot: a renewal
/// callback may have extended it since), then applies ``Subscription/expireIfNeeded(now:)``:
///
/// * `expired` -> persisted with the optimistic CAS (a concurrent writer surfaces as
///   `ConcurrencyError`, which the job counts and skips);
/// * `expiring` -> **no write**: the aggregate's `subscription.expiring` event is handed to the
///   collector and dispatched after commit. Re-running inside the window re-raises it
///   (as Node did); nothing consumes it yet.
struct ExpireSubscriptionUseCase: UseCase {
    struct Params: Sendable {
        let accountId: String
        let subscriptionId: Subscription.Id
    }

    let context: any UnitOfWorkContext
    let subscriptionRepositoryFactory: RepositoryFactory<any SubscriptionRepository>
    let now: @Sendable () -> Date
    let logger: Logger

    init(
        context: any UnitOfWorkContext,
        subscriptionRepositoryFactory: @escaping RepositoryFactory<any SubscriptionRepository>,
        now: @escaping @Sendable () -> Date = { .now },
        logger: Logger
    ) {
        self.context = context
        self.subscriptionRepositoryFactory = subscriptionRepositoryFactory
        self.now = now
        self.logger = logger
    }

    func execute(params: Params) async throws -> ExpirationOutcome {
        let repository = subscriptionRepositoryFactory(context)
        guard let subscription = try await repository.fetch(accountId: params.accountId, id: params.subscriptionId) else {
            logger.warning("Subscription vanished before the expiration check", metadata: [
                "accountId": .string(params.accountId), "subscriptionId": .string(params.subscriptionId.rawValue)
            ])
            return .unchanged
        }
        let outcome = try subscription.expireIfNeeded(now: now())
        switch outcome {
        case .expired:
            try await repository.update(entity: subscription)
        case .expiring:
            await context.collector.capture(subscription.pullEvents())
        case .unchanged:
            break
        }
        return outcome
    }
}
