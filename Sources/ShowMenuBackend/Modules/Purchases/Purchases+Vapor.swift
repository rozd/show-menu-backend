import Vapor

/// Edge status hints for gateway failures (the domain stays HTTP-free; see
/// `docs/conventions/HTTPErrors.md`).
extension PaymentGatewayError: HTTPStatusHinted {
    var httpStatusHint: HTTPResponseStatus {
        switch self {
        case .notConfigured: .serviceUnavailable
        case .invalidSignature: .unauthorized
        case .invalidPayload: .badRequest
        case .transport, .unexpectedResponse: .badGateway
        }
    }
}
