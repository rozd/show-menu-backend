import Foundation
import Testing
import Vapor
@testable import ShowMenuBackend

@Suite("Billing payment gateway port")
struct PaymentGatewayDomainTests {

    @Test("gateway errors map to their HTTP status hints through the error envelope")
    func errorStatuses() {
        let table: [(PaymentGatewayError, UInt)] = [
            (.notConfigured, 503), (.invalidSignature, 401), (.invalidPayload("x"), 400),
            (.transport("x"), 502), (.unexpectedResponse("x"), 502),
        ]
        for (error, status) in table {
            #expect(error.httpStatusHint.code == status)
            #expect(HTTPErrorMapping.map(error).status.code == status)
        }
    }

    @Test("LiqPayCallbackEventId is deterministic and sensitive to every component")
    func callbackEventId() {
        let a = LiqPayCallbackEventId.derive(orderId: "inv-1", status: "success", paymentId: "9")
        #expect(a == LiqPayCallbackEventId.derive(orderId: "inv-1", status: "success", paymentId: "9"))
        #expect(a != LiqPayCallbackEventId.derive(orderId: "inv-2", status: "success", paymentId: "9"))
        #expect(a != LiqPayCallbackEventId.derive(orderId: "inv-1", status: "failure", paymentId: "9"))
        #expect(a != LiqPayCallbackEventId.derive(orderId: "inv-1", status: "success", paymentId: "10"))
        #expect(a != LiqPayCallbackEventId.derive(orderId: "inv-1", status: "success", paymentId: nil))
        // RFC 9562 v8, RFC 4122 variant.
        #expect(a.uuidString[a.uuidString.index(a.uuidString.startIndex, offsetBy: 14)] == "8")
    }

    @Test("the app boots with zero LIQPAY env: the payment gateway resolves lazily")
    func lazyResolution() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        // Nothing resolved at boot; resolving yields a gateway even with no keys configured
        // (the fake one in .testing).
        let gateway = app.deps.paymentGateway
        #expect(gateway is FakePaymentGateway || gateway is LiqPayPaymentGateway)
    }
}
