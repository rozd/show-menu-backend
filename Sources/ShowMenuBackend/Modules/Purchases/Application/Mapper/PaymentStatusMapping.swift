import Foundation

/// LiqPay status vocabulary -> our statuses (roadmap §7 S10 tables; the extension's
/// `translatePaymentStatusToCheckoutSessionStatus` and Node's `mapPaymentStatusFromLiqPayToApplication`).
enum PaymentStatusMapping {

    /// What the client sees: `success|subscribed -> success`, `error|failure -> failure`,
    /// `reversed|unsubscribed -> cancelled`, everything else (`processing`, `wait_*`, ...) `-> pending`.
    static func sessionStatus(for liqPayStatus: String) -> CheckoutSessionStatus {
        switch liqPayStatus {
        case "success", "subscribed": .success
        case "error", "failure": .failure
        case "reversed", "unsubscribed": .cancelled
        default: .pending
        }
    }

    /// The invoice status a callback asks for, `nil` for in-flight statuses (no transition):
    /// `success|subscribed -> paid`, `error|failure -> failed`, `reversed -> refunded`,
    /// `unsubscribed -> cancelled`.
    static func invoiceTarget(for liqPayStatus: String) -> InvoiceStatus? {
        switch liqPayStatus {
        case "success", "subscribed": .paid
        case "error", "failure": .failed
        case "reversed": .refunded
        case "unsubscribed": .cancelled
        default: nil
        }
    }
}
