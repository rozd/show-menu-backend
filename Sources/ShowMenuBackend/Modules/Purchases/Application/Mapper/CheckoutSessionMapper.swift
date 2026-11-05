import Foundation

/// Not a `Mapper` conformance (no repository, no DTO): the session is a plain value whose
/// account comes from the document path (as with ``AccountMapper``).
struct CheckoutSessionMapper: Sendable {

    init() {}

    func toModel(entity: CheckoutSession) -> CheckoutSessionModel {
        CheckoutSessionModel(
            status: entity.status,
            invoiceId: entity.invoiceId.rawValue,
            orderId: entity.orderId?.rawValue,
            paymentPageURL: entity.paymentPageURL,
            transactionId: entity.transactionId,
            errorCode: entity.error?.code,
            errorMessage: entity.error?.message,
            errorDetails: entity.error?.details
        )
    }

    /// An error exists iff `errorCode` is a string (Flutter's rule).
    func toEntity(model: CheckoutSessionModel, accountId: String) -> CheckoutSession {
        CheckoutSession(
            invoiceId: Invoice.Id(rawValue: model.invoiceId),
            accountId: accountId,
            orderId: model.orderId.map { Order.Id(rawValue: $0) },
            status: model.status,
            paymentPageURL: model.paymentPageURL,
            transactionId: model.transactionId,
            error: model.errorCode.map {
                CheckoutSessionError(code: $0, message: model.errorMessage, details: model.errorDetails)
            }
        )
    }
}
