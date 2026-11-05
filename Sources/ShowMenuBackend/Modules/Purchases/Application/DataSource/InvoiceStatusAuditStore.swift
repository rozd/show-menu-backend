import Foundation

/// Appends the audit trail `invoices/{invoiceId}/statuses/{auto-id}`: one document per
/// accepted LiqPay callback, holding the decoded payload as-is (the old extension's shape).
protocol InvoiceStatusAuditStore: Sendable {

    /// Writes a new document with a generated id. `rawPayload` is the callback's decoded
    /// JSON object. A write, so it runs after the unit of work's reads.
    func append(invoiceId: String, rawPayload: String) async throws
}
