import Foundation
import Crypto

/// A stable `IntegrationEvent.id` for a LiqPay callback, so the inbox
/// (`InboxedCommandHandler`, keyed on `RequestContext.integrationEventId`) recognises a
/// redelivery. Same construction as `CloudEventsHeaders.integrationEventId`: LiqPay has no
/// delivery id, so the identity is `(order_id, status, payment_id)`; a retry carries exactly
/// the same triple, a distinct payment or a status change does not.
enum LiqPayCallbackEventId {

    /// Name-based: SHA-256 over `order_id` U+0000 `status` U+0000 `payment_id` (empty when
    /// absent), truncated to 128 bits and stamped as an RFC 9562 version-8 UUID with the
    /// RFC 4122 variant.
    static func derive(orderId: String, status: String, paymentId: String?) -> UUID {
        let name = "\(orderId)\u{0}\(status)\u{0}\(paymentId ?? "")"
        let digest = Array(SHA256.hash(data: Data(name.utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80 // version 8
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
