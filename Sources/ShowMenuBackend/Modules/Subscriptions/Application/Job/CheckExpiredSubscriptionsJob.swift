import Foundation
import Logging

/// What one run of the daily job did. Also the JSON body of the endpoint.
struct ExpirationSummary: Codable, Sendable, Equatable {
    /// Active subscriptions with `expiresAt <= now + 1 day` that the scan returned.
    let scanned: Int
    /// Moved `active -> expired` (`expiresAt <= now - 1 day`).
    let expired: Int
    /// Raised `subscription.expiring` (`now - 1 day < expiresAt <= now`).
    let expiring: Int
    /// Paid invoices that had no subscription and got one.
    let reconciled: Int
}

/// The daily scheduler job (Node `onCheckExpiredSubscriptions`, `0 0 * * *` UTC): expire and
/// warn, then reconcile.
///
/// Not a `CommandHandler`: it spans many units of work. Every subscription / invoice is processed
/// in its **own** unit of work (fixes Node's single transaction over every account, roadmap bug
/// 11), so the 500-write cap cannot bite, and a failure on one item (optimistic-concurrency
/// conflict with a concurrent LiqPay callback, a transient Firestore error, an invalid
/// transition) is logged and skipped instead of failing the run. Re-running is idempotent:
/// expired subscriptions leave the scan, and the reconcile pass only creates what is missing.
///
/// Bounds (documented limits): at most ``scanLimit`` subscriptions and ``reconcileLimit`` invoices
/// per run, the reconcile pass only looks at invoices updated within ``reconcileWindow``.
/// Whatever does not fit is picked up by the next run (oldest `expiresAt` first for expiry).
struct CheckExpiredSubscriptionsJob: Sendable {
    static let defaultScanLimit = 1_000
    static let defaultReconcileLimit = 500
    /// Invoices older than this are not reconciled by default.
    static let defaultReconcileWindow: TimeInterval = 7 * 86_400
    static let day: TimeInterval = 86_400

    let unitOfWork: any UnitOfWork
    let subscriptions: any ExpiringSubscriptionSource
    let invoices: any PaidInvoiceSource
    let expireUseCaseFactory: UseCaseFactory<ExpireSubscriptionUseCase>
    let reconcileUseCaseFactory: UseCaseFactory<ReconcileSubscriptionUseCase>
    let now: @Sendable () -> Date
    let scanLimit: Int
    let reconcileLimit: Int
    let reconcileWindow: TimeInterval
    let logger: Logger

    init(
        unitOfWork: any UnitOfWork,
        subscriptions: any ExpiringSubscriptionSource,
        invoices: any PaidInvoiceSource,
        expireUseCaseFactory: @escaping UseCaseFactory<ExpireSubscriptionUseCase>,
        reconcileUseCaseFactory: @escaping UseCaseFactory<ReconcileSubscriptionUseCase>,
        now: @escaping @Sendable () -> Date = { .now },
        scanLimit: Int = defaultScanLimit,
        reconcileLimit: Int = defaultReconcileLimit,
        reconcileWindow: TimeInterval = defaultReconcileWindow,
        logger: Logger
    ) {
        self.unitOfWork = unitOfWork
        self.subscriptions = subscriptions
        self.invoices = invoices
        self.expireUseCaseFactory = expireUseCaseFactory
        self.reconcileUseCaseFactory = reconcileUseCaseFactory
        self.now = now
        self.scanLimit = scanLimit
        self.reconcileLimit = reconcileLimit
        self.reconcileWindow = reconcileWindow
        self.logger = logger
    }

    /// - Parameter reconcileWindow: overrides the default look-back of the reconcile pass.
    func run(reconcileWindow override: TimeInterval? = nil) async throws -> ExpirationSummary {
        let moment = now()
        var expired = 0
        var expiring = 0

        // Expiry: the scan is `expiresAt <= now + 1 day`; only `<= now` needs work (the rest of the
        // scan, `(now, now + 1 day]`, is counted but untouched, as in Node).
        let found = try await subscriptions.activeSubscriptions(
            expiringBy: moment.addingTimeInterval(Self.day), limit: scanLimit
        )
        if found.count >= scanLimit {
            logger.warning("Expiration scan hit its limit; the rest is handled by the next run", metadata: [
                "limit": .stringConvertible(scanLimit)
            ])
        }
        for reference in found where reference.expiresAt <= moment {
            do {
                let factory = expireUseCaseFactory
                let outcome = try await unitOfWork.execute { ctx in
                    try await factory(ctx).execute(params: .init(
                        accountId: reference.accountId, subscriptionId: reference.id
                    ))
                }
                switch outcome {
                case .expired: expired += 1
                case .expiring: expiring += 1
                case .unchanged: break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Typically a ConcurrencyError (a callback renewed it meanwhile): next run re-evaluates.
                logger.warning("Subscription skipped by the expiration job", metadata: [
                    "accountId": .string(reference.accountId),
                    "subscriptionId": .string(reference.id.rawValue),
                    "error": .string("\(error)"),
                ])
            }
        }

        let reconciled = try await reconcile(window: override ?? reconcileWindow, moment: moment)

        let summary = ExpirationSummary(
            scanned: found.count, expired: expired, expiring: expiring, reconciled: reconciled
        )
        logger.info("Expiration job finished", metadata: [
            "scanned": .stringConvertible(summary.scanned), "expired": .stringConvertible(summary.expired),
            "expiring": .stringConvertible(summary.expiring), "reconciled": .stringConvertible(summary.reconciled),
        ])
        return summary
    }

    private func reconcile(window: TimeInterval, moment: Date) async throws -> Int {
        let candidates = try await invoices.paidInvoices(
            updatedSince: moment.addingTimeInterval(-window), limit: reconcileLimit
        )
        if candidates.count >= reconcileLimit {
            logger.warning("Reconcile scan hit its limit; older invoices are not examined this run", metadata: [
                "limit": .stringConvertible(reconcileLimit)
            ])
        }
        var reconciled = 0
        for invoiceId in candidates {
            do {
                let factory = reconcileUseCaseFactory
                let created = try await unitOfWork.execute { ctx in
                    try await factory(ctx).execute(params: .init(invoiceId: invoiceId))
                }
                if created { reconciled += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning("Invoice skipped by the reconcile pass", metadata: [
                    "invoiceId": .string(invoiceId.rawValue), "error": .string("\(error)"),
                ])
            }
        }
        return reconciled
    }
}
