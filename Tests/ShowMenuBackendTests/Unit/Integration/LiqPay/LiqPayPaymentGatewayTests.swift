import Crypto
import Foundation
import LiqPayClient
import Testing
@testable import ShowMenuBackend

@Suite("LiqPayPaymentGateway")
struct LiqPayPaymentGatewayTests {

    private struct SUT {
        let gateway: LiqPayPaymentGateway
        let checkout: StubCheckoutTransport
        let api: StubAPITransport
    }

    private func makeSUT(
        configuration: LiqPayGatewayConfiguration = LiqPayFixtures.configuration(),
        checkoutScript: [StubCheckoutTransport.Step] = [StubCheckoutTransport.redirect()],
        apiBody: String = "{}",
        apiError: (any Error)? = nil
    ) -> SUT {
        let checkout = StubCheckoutTransport(checkoutScript)
        let api = StubAPITransport(body: apiBody, error: apiError)
        let gateway = LiqPayPaymentGateway(
            configuration: configuration,
            apiTransport: api,
            checkoutTransport: checkout,
            retryPolicy: .liqPay(backoff: .immediate),
            now: { LiqPayFixtures.fixedNow }
        )
        return SUT(gateway: gateway, checkout: checkout, api: api)
    }

    // MARK: - Signing

    @Test("signing vector: fixed key + data gives the known signature, matching base64(sha1(priv+data+priv))")
    func signingVector() {
        let data = "eyJhIjoxfQ=="
        let signature = LiqPaySigner.sign(privateKey: PrivateKey("test_private_key"), data: data)
        #expect(signature == "+1fEPP8xrG2r5VyMOLVFt64MAhY=")

        let material = Data(("test_private_key" + data + "test_private_key").utf8)
        #expect(signature == Data(Insecure.SHA1.hash(data: material)).base64EncodedString())
    }

    // MARK: - Envelope

    @Test("pay envelope shape; signature verifies against the emitted bytes")
    func payEnvelope() async throws {
        let sut = makeSUT(configuration: LiqPayFixtures.configuration(resultURL: "https://example.test/done"))
        _ = try await sut.gateway.checkout(LiqPayFixtures.request())

        let form = try #require(sut.checkout.calls.first?.form)
        let data = try #require(form["data"])
        let signature = try #require(form["signature"])
        #expect(LiqPaySigner.verify(privateKey: PrivateKey(LiqPayFixtures.privateKey), data: data, signature: signature))

        let json = try LiqPayFixtures.decode(data)
        #expect(json["action"] as? String == "pay")
        #expect(json["version"] as? Int == 3)
        #expect(json["public_key"] as? String == LiqPayFixtures.publicKey)
        #expect(json["order_id"] as? String == "inv-1")
        #expect(json["currency"] as? String == "UAH")
        #expect(json["description"] as? String == "Order #o-1")
        #expect(json["server_url"] as? String == LiqPayFixtures.callbackURL)
        #expect(json["result_url"] as? String == "https://example.test/done")
        #expect(json["language"] as? String == "en")
        #expect(json["subscribe"] == nil)
        #expect(json["subscribe_periodicity"] == nil)
        #expect(json["subscribe_date_start"] == nil)

        // 19.99 stays 19.99 (no binary-float tail).
        let raw = String(decoding: try #require(Data(base64Encoded: data)), as: UTF8.self)
        #expect(raw.contains("\"amount\":19.99"))
        // Posted to the checkout endpoint.
        #expect(sut.checkout.calls.first?.url.absoluteString == "https://www.liqpay.ua/api/3/checkout")
    }

    @Test("request result_url and language win over defaults; nil optionals are omitted")
    func requestOverrides() async throws {
        let sut = makeSUT(configuration: LiqPayFixtures.configuration(resultURL: "https://example.test/default"))
        _ = try await sut.gateway.checkout(LiqPayFixtures.request(resultURL: "https://example.test/mine", language: "uk"))
        let json = try LiqPayFixtures.decode(try #require(sut.checkout.calls.first?.form["data"]))
        #expect(json["result_url"] as? String == "https://example.test/mine")
        #expect(json["language"] as? String == "uk")

        let bare = makeSUT()
        _ = try await bare.gateway.checkout(LiqPayFixtures.request())
        let bareJSON = try LiqPayFixtures.decode(try #require(bare.checkout.calls.first?.form["data"]))
        #expect(bareJSON["result_url"] == nil)
    }

    @Test("subscribe envelope per duration, with the fixed-clock subscribe_date_start",
          arguments: [
            (SubscriptionDuration.daily, "day"), (.weekly, "week"), (.monthly, "month"), (.yearly, "year"),
          ])
    func subscribeEnvelope(duration: SubscriptionDuration, periodicity: String) async throws {
        let sut = makeSUT()
        _ = try await sut.gateway.checkout(LiqPayFixtures.request(subscription: duration))
        let form = try #require(sut.checkout.calls.first?.form)
        let json = try LiqPayFixtures.decode(try #require(form["data"]))
        #expect(json["action"] as? String == "subscribe")
        #expect(json["subscribe"] as? String == "1")
        #expect(json["subscribe_periodicity"] as? String == periodicity)
        #expect(json["subscribe_date_start"] as? String == "2023-11-14 22:13:20")
        #expect(LiqPaySigner.verify(
            privateKey: PrivateKey(LiqPayFixtures.privateKey),
            data: try #require(form["data"]), signature: try #require(form["signature"])
        ))
    }

    @Test("missing callback URL is notConfigured and makes no call")
    func missingCallbackURL() async {
        let sut = makeSUT(configuration: LiqPayFixtures.configuration(callbackURL: nil))
        await #expect(throws: PaymentGatewayError.notConfigured) {
            _ = try await sut.gateway.checkout(LiqPayFixtures.request())
        }
        #expect(sut.checkout.callCount == 0)
    }

    @Test("LIQPAY_API_URL base drives the checkout and request endpoints")
    func customBaseURL() async throws {
        let base = URL(string: "https://sandbox.example.test/api")!
        let sut = makeSUT(configuration: LiqPayFixtures.configuration(apiBaseURL: base))
        _ = try await sut.gateway.checkout(LiqPayFixtures.request())
        #expect(sut.checkout.calls.first?.url.absoluteString == "https://sandbox.example.test/api/3/checkout")
        #expect(sut.gateway.client.configuration.endpoint.absoluteString == "https://sandbox.example.test/api/request")
    }

    // MARK: - Checkout transport outcomes

    @Test("302 + Location returns the payment page URL")
    func redirectLocation() async throws {
        let sut = makeSUT(checkoutScript: [StubCheckoutTransport.redirect("https://pay.example.test/p/1")])
        let url = try await sut.gateway.checkout(LiqPayFixtures.request())
        #expect(url.absoluteString == "https://pay.example.test/p/1")
    }

    @Test("302 without Location is unexpectedResponse and not retried")
    func redirectWithoutLocation() async {
        let sut = makeSUT(checkoutScript: [StubCheckoutTransport.redirect(nil)])
        await #expect(throws: PaymentGatewayError.self) {
            _ = try await sut.gateway.checkout(LiqPayFixtures.request())
        }
        #expect(sut.checkout.callCount == 1)
    }

    @Test("200 is unexpectedResponse with status and body preview")
    func okIsUnexpected() async {
        let sut = makeSUT(checkoutScript: [StubCheckoutTransport.status(200, body: "<html>oops</html>")])
        do {
            _ = try await sut.gateway.checkout(LiqPayFixtures.request())
            Issue.record("expected a throw")
        } catch PaymentGatewayError.unexpectedResponse(let message) {
            #expect(message.contains("200"))
            #expect(message.contains("<html>oops</html>"))
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(sut.checkout.callCount == 1)
    }

    @Test("503 then 302 is retried to success")
    func transientThenSuccess() async throws {
        let sut = makeSUT(checkoutScript: [StubCheckoutTransport.status(503), StubCheckoutTransport.redirect()])
        let url = try await sut.gateway.checkout(LiqPayFixtures.request())
        #expect(url.absoluteString == "https://pay.example.test/page")
        #expect(sut.checkout.callCount == 2)
    }

    @Test("connection failure is retried then surfaces as transport")
    func transportFailureRetried() async {
        let sut = makeSUT(checkoutScript: [.failure(StubNetworkError())])
        do {
            _ = try await sut.gateway.checkout(LiqPayFixtures.request())
            Issue.record("expected a throw")
        } catch PaymentGatewayError.transport {
            // expected
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(sut.checkout.callCount == 3)
    }

    @Test("400 is not retried")
    func clientErrorNotRetried() async {
        let sut = makeSUT(checkoutScript: [StubCheckoutTransport.status(400, body: "bad")])
        await #expect(throws: PaymentGatewayError.self) {
            _ = try await sut.gateway.checkout(LiqPayFixtures.request())
        }
        #expect(sut.checkout.callCount == 1)
    }

    // MARK: - Form encoding

    @Test("form body percent-encodes everything outside the unreserved set")
    func formEncoding() {
        let body = AsyncHTTPClientLiqPayCheckoutTransport.formEncode([
            "signature": "a+b/c==", "data": "x y&z=~-._é",
        ])
        #expect(body == "data=x%20y%26z%3D~-._%C3%A9&signature=a%2Bb%2Fc%3D%3D")
    }

    // MARK: - Status

    @Test("status maps fields; err_code wins over code")
    func statusMapping() async throws {
        let sut = makeSUT(apiBody: """
            {"status":"failure","action":"pay","order_id":"inv-1","payment_id":42,"transaction_id":7,
             "amount":19.99,"currency":"UAH","err_code":"E1","code":"C1","err_description":"declined"}
            """)
        let status = try await sut.gateway.status(orderId: "inv-1")
        #expect(status.orderId == "inv-1")
        #expect(status.status == "failure")
        #expect(status.action == "pay")
        #expect(status.paymentId == "42")
        #expect(status.transactionId == "7")
        #expect(status.amount == 19.99)
        #expect(status.currency == "UAH")
        #expect(status.errorCode == "E1")
        #expect(status.errorDescription == "declined")
        #expect(status.rawPayload == nil)
        #expect(sut.api.requests.first?.endpoint.absoluteString == "https://www.liqpay.ua/api/request")
    }

    @Test("status falls back to code when err_code is absent, and to result when status is absent")
    func statusFallbacks() async throws {
        let sut = makeSUT(apiBody: #"{"result":"error","code":"C1"}"#)
        let status = try await sut.gateway.status(orderId: "inv-1")
        #expect(status.errorCode == "C1")
        #expect(status.status == "error")
    }

    @Test("status with an undecodable response body is unexpectedResponse (502), not invalidPayload")
    func statusUndecodableBody() async {
        let sut = makeSUT(apiBody: "<html>502 Bad Gateway</html>")
        do {
            _ = try await sut.gateway.status(orderId: "inv-1")
            Issue.record("expected a throw")
        } catch PaymentGatewayError.unexpectedResponse {
            // expected
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(sut.api.requests.count == 1)
    }

    @Test("status transport failure is retried then maps to transport")
    func statusTransportFailure() async {
        let sut = makeSUT(apiError: StubNetworkError())
        do {
            _ = try await sut.gateway.status(orderId: "inv-1")
            Issue.record("expected a throw")
        } catch PaymentGatewayError.transport {
            // expected
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(sut.api.requests.count == 3)
    }

    // MARK: - Callback

    @Test("decodeCallback verifies, decodes and preserves the raw payload")
    func decodeValid() throws {
        let json = #"{"status":"subscribed","order_id":"inv-1","action":"subscribe","payment_id":9}"#
        let signed = LiqPayFixtures.callback(json: json)
        let status = try makeSUT().gateway.decodeCallback(data: signed.data, signature: signed.signature)
        #expect(status.status == "subscribed")
        #expect(status.orderId == "inv-1")
        #expect(status.paymentId == "9")
        #expect(status.rawPayload == json)
    }

    @Test("decodeCallback rejects a bad signature")
    func decodeBadSignature() {
        let signed = LiqPayFixtures.callback(json: #"{"status":"success"}"#, privateKey: "someone_elses_key")
        #expect(throws: PaymentGatewayError.invalidSignature) {
            _ = try makeSUT().gateway.decodeCallback(data: signed.data, signature: signed.signature)
        }
    }

    @Test("decodeCallback: validly signed garbage is invalidPayload")
    func decodeGarbage() {
        let signed = LiqPayFixtures.callback(json: "not json at all")
        #expect(throws: PaymentGatewayError.invalidPayload("not json at all")) {
            _ = try makeSUT().gateway.decodeCallback(data: signed.data, signature: signed.signature)
        }
    }
}
