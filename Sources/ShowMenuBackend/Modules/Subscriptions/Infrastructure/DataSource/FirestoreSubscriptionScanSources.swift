import FirestoreAPI
import Foundation

/// `ExpiringSubscriptionSource` over a Firestore **collection-group** query on `subscriptions`
/// (`FirestoreTransaction.collectionGroup`, public in the pinned client): one indexed query
/// across every `accounts/{id}/subscriptions`, instead of Node's scan of all accounts.
///
/// Needs the composite index `subscriptions` (`COLLECTION_GROUP`) on `status ASC, expiresAt ASC`
/// (`show-menu-firebase/firestore.indexes.json`); the emulator does not enforce it. Runs through
/// the transport it is given — a *direct* one, never a transaction (S05).
struct FirestoreExpiringSubscriptionSource: ExpiringSubscriptionSource {
    let directTransaction: @Sendable () -> FirestoreTransaction

    func activeSubscriptions(expiringBy cutoff: Date, limit: Int) async throws -> [SubscriptionReference] {
        let transaction = directTransaction()
        let query = transaction.collectionGroup("subscriptions")
            .where(field: "status", isEqualTo: SubscriptionStatus.active.rawValue)
            .where(field: "expiresAt", isLessThanOrEqualTo: cutoff)
            .order(by: "expiresAt")
            .limit(to: limit)
        do {
            return try await transaction.getDocuments(SubscriptionModel.self, query: query).map {
                SubscriptionReference(accountId: $0.accountId, id: .init(rawValue: $0.id), expiresAt: $0.expiresAt.asDate)
            }
        } catch let error as FirestoreError {
            throw error
        } catch {
            throw FirestoreError.from(grpcError: error)
        }
    }
}

/// `PaidInvoiceSource` over the top-level `invoices` collection. Needs the composite index
/// `invoices` (`COLLECTION`) on `status ASC, updatedAt DESC` (equality + range/order on different
/// fields); the emulator does not enforce it.
struct FirestorePaidInvoiceSource: PaidInvoiceSource {
    let dataSourceFactory: DataSourceFactory<InvoiceModel>
    let directTransaction: @Sendable () -> any Sendable

    func paidInvoices(updatedSince since: Date, limit: Int) async throws -> [Invoice.Id] {
        let result = try await dataSourceFactory("", directTransaction()).query(DataSourceQuery(
            filters: [
                DataSourceFilter(field: "status", op: .equal, value: InvoiceStatus.paid.rawValue),
                DataSourceFilter(field: "updatedAt", op: .greaterThanOrEqual, value: since),
            ],
            orders: [DataSourceOrder(field: "updatedAt", direction: .descending)],
            limit: limit
        ))
        return result.items.map { Invoice.Id(rawValue: $0.id) }
    }
}
