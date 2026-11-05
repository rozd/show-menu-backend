import Foundation
import LiqPayClient
import Testing
@testable import ShowMenuBackend

@Suite("FakePaymentGateway")
struct FakePaymentGatewayTests {

    private func makeSUT(configuration: LiqPayGatewayConfiguration = LiqPayFixtures.configuration()) -> FakePaymentGateway {
        FakePaymentGateway(configuration: configuration, now: { LiqPayFixtures.fixedNow })
    }

    @Test("checkout is deterministic and carries the real signed envelope")
    func checkoutDeterministic() async throws {
        let sut = makeSUT()
        let first = try await sut.checkout(LiqPayFixtures.request())
        let second = try await sut.checkout(LiqPayFixtures.request())
        #expect(first == second)

        let components = try #require(URLComponents(url: first, resolvingAgainstBaseURL: false))
        #expect(components.host == "www.liqpay.ua")
        #expect(components.path == "/api/3/checkout")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let data = try #require(items["data"])
        let signature = try #require(items["signature"])
        #expect(LiqPaySigner.verify(privateKey: PrivateKey(LiqPayFixtures.privateKey), data: data, signature: signature))
        #expect(try LiqPayFixtures.decode(data)["order_id"] as? String == "inv-1")
    }

    @Test("status is processing, with no network")
    func statusProcessing() async throws {
        let status = try await makeSUT().status(orderId: "inv-1")
        #expect(status.status == "processing")
        #expect(status.orderId == "inv-1")
    }

    @Test("decodeCallback does real verification")
    func decodeVerifies() throws {
        let sut = makeSUT()
        let good = LiqPayFixtures.callback(json: #"{"status":"success","order_id":"inv-1"}"#)
        #expect(try sut.decodeCallback(data: good.data, signature: good.signature).status == "success")

        let bad = LiqPayFixtures.callback(json: #"{"status":"success"}"#, privateKey: "wrong")
        #expect(throws: PaymentGatewayError.invalidSignature) {
            _ = try sut.decodeCallback(data: bad.data, signature: bad.signature)
        }
    }

    @Test("the emulator test keypair is sandbox and signs callbacks")
    func testKeypair() throws {
        let sut = makeSUT(configuration: FakePaymentGateway.testConfiguration())
        #expect(sut.isSandbox)
        let signed = LiqPayFixtures.callback(
            json: #"{"status":"success"}"#, privateKey: FakePaymentGateway.emulatorPrivateKey
        )
        #expect(try sut.decodeCallback(data: signed.data, signature: signed.signature).status == "success")
    }
}
