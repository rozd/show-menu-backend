import Foundation

/// A signature-verified LiqPay `server_url` callback, decoded at the edge. Inbox-keyed on
/// `(order_id, status, payment_id)` by the controller (see ``LiqPayCallbackEventId``).
struct HandleLiqPayCallbackCommand: Command {

    struct Payload: Sendable, Codable, Equatable {
        /// LiqPay `order_id`: our invoice id.
        let orderId: String
        /// LiqPay's raw status string (`success`, `subscribed`, `failure`, ...).
        let status: String
        let paymentId: String?
        let transactionId: String?
        let errorCode: String?
        let errorDescription: String?
        /// LiqPay `info`: stored as the session's `errorDetails`.
        let info: String?
        /// The decoded JSON payload, unchanged: stored as-is under `invoices/{id}/statuses`.
        let rawPayload: String

        /// The payment's identity for renewal detection: `transaction_id`, else `payment_id`.
        var paymentReference: String? { transactionId ?? paymentId }
    }

    let payload: Payload
    let metadata: CommandMetadata
}

extension HandleLiqPayCallbackCommand.Payload {

    /// Builds the payload from the gateway's decoded callback. `nil` when it lacks `order_id`.
    init?(status: PaymentStatus) {
        guard let orderId = status.orderId, !orderId.isEmpty else { return nil }
        let raw = status.rawPayload ?? "{}"
        self.init(
            orderId: orderId,
            status: status.status,
            paymentId: status.paymentId,
            transactionId: status.transactionId,
            errorCode: status.errorCode,
            errorDescription: status.errorDescription,
            info: Self.info(in: raw),
            rawPayload: raw
        )
    }

    private struct InfoProbe: Decodable { let info: String? }

    /// `PaymentStatus` has no `info`; read it from the raw payload (lenient: any other type is nil).
    private static func info(in rawPayload: String) -> String? {
        (try? JSONDecoder().decode(InfoProbe.self, from: Data(rawPayload.utf8)))?.info
    }
}
