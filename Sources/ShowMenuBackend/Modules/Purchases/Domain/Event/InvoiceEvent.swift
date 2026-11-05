import Foundation

enum InvoiceEventKind: String, LifecycleEventKind {
    // Lifecycle (infrastructure/audit): recorded by the Repository.
    case invoiceCreated = "created"
    case invoiceUpdated = "updated"
    case invoiceDeleted = "deleted"

    // Semantic (domain facts): recorded by the aggregate.
    case invoicePaid = "invoice.paid"
    case invoiceFailed = "invoice.failed"
    case invoiceCancelled = "invoice.cancelled"
    case invoiceRefunded = "invoice.refunded"
    /// A further payment arrived for an already-paid invoice (a subscription renewal, S13).
    case invoiceRenewed = "invoice.renewed"

    static let created: InvoiceEventKind = .invoiceCreated
    static let updated: InvoiceEventKind = .invoiceUpdated
    static let deleted: InvoiceEventKind = .invoiceDeleted
}

struct InvoiceEvent: DomainEvent {
    typealias AggregateId = Invoice.Id
    typealias Kind = InvoiceEventKind

    let id: UUID
    let aggregateId: Invoice.Id
    let occurredAt: Date
    let kind: InvoiceEventKind

    init(id: UUID, aggregateId: Invoice.Id, kind: InvoiceEventKind, occurredAt: Date) {
        self.id = id
        self.aggregateId = aggregateId
        self.kind = kind
        self.occurredAt = occurredAt
    }

    static func semantic(_ kind: InvoiceEventKind, aggregateId: Invoice.Id, occurredAt: Date = .now) -> InvoiceEvent {
        InvoiceEvent(id: UUID(), aggregateId: aggregateId, kind: kind, occurredAt: occurredAt)
    }
}
