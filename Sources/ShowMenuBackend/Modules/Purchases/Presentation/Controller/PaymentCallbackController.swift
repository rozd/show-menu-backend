import Vapor

/// `POST /api/v1/payments/liqpay/callback`: public, signature-verified. Answers 200 `OK`.
///
/// * `data` missing or empty -> 400; `signature` missing or empty -> 401.
/// * Bad signature -> 401, malformed payload (bad base64 / JSON, no `order_id`) -> 400, from
///   the gateway's ``PaymentGatewayError`` hints (`Purchases+Vapor.swift`).
/// * Everything else is acknowledged with 200 (unknown invoice, invalid transition,
///   duplicate), because LiqPay retries every non-2xx.
struct PaymentCallbackController: Sendable {

    let gateway: any PaymentGateway
    let handler: HandleLiqPayCallbackCommandHandler

    @Sendable
    func liqpayCallback(req: Request) async throws -> String {
        let envelope: LiqPayCallbackEnvelope
        do {
            envelope = try req.content.decode(LiqPayCallbackEnvelope.self)
        } catch {
            throw Abort(.badRequest, reason: "Invalid callback body")
        }
        guard let data = envelope.data, !data.isEmpty else {
            throw Abort(.badRequest, reason: "Missing data")
        }
        guard let signature = envelope.signature, !signature.isEmpty else {
            throw Abort(.unauthorized, reason: "Missing signature")
        }

        // Verifies the signature (always) and decodes; throws `PaymentGatewayError`.
        let status = try gateway.decodeCallback(data: data, signature: signature)
        guard let payload = HandleLiqPayCallbackCommand.Payload(status: status) else {
            req.logger.warning("LiqPay callback without order_id rejected")
            throw Abort(.badRequest, reason: "Missing order_id")
        }

        req.logger.info("LiqPay callback received", metadata: [
            "orderId": .string(payload.orderId), "status": .string(payload.status)
        ])

        // A stable id per (order_id, status, payment_id): the inbox keys on it.
        let eventId = LiqPayCallbackEventId.derive(
            orderId: payload.orderId, status: payload.status, paymentId: payload.paymentId
        )
        let command = HandleLiqPayCallbackCommand(payload: payload, metadata: CommandMetadata(req: req))
        try await RequestContext.$integrationEventId.withValue(eventId) {
            try await handler.handle(command)
        }
        return "OK"
    }
}
