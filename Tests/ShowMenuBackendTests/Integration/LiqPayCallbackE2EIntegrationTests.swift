import Foundation
import Testing
import Vapor
import FirestoreAPI
@testable import ShowMenuBackend

/// Roadmap S13 "Done": a purchase is created over HTTP, then a callback **signed with the
/// Fake gateway's emulator test keypair** (`sandbox_showmenu_emulator_*`) is posted to the
/// running stack, and the invoice, order, session and audit documents are asserted in the
/// Firestore emulator.
///
/// Needs the whole local stack, so it is skipped unless `SHOWMENU_E2E_BASE_URL` is set (in
/// addition to the emulator variables of `EmulatorFirestoreHelper`):
///
/// ```
/// make emulators        # terminal 1
/// make run-local        # terminal 2  (Vapor on :8080; emulator => FakePaymentGateway + test keypair)
/// SHOWMENU_E2E_BASE_URL=http://127.0.0.1:8080 GCP_PROJECT_ID=show-menu-dev \
///   FIRESTORE_EMULATOR_HOST=127.0.0.1:9002 swift test --filter LiqPayCallbackE2EIntegrationTests
/// ```
///
/// Do not set `LIQPAY_PRIVATE_KEY` for the server: the test signs with the fixed emulator key.
@Suite("LiqPay callback — end to end on the emulator")
struct LiqPayCallbackE2EIntegrationTests {

    private static var baseURL: String? { Environment.get("SHOWMENU_E2E_BASE_URL") }
    private static var isAvailable: Bool { EmulatorFirestoreHelper.isAvailable && baseURL != nil }

    private func b64url(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// An unsigned emulator ID token (accepted only in emulator mode).
    private func token(uid: String, email: String) -> String {
        let project = Environment.get("GCP_PROJECT_ID") ?? "show-menu-dev"
        let now = Int(Date().timeIntervalSince1970)
        let body = #"{"iss":"https://securetoken.google.com/\#(project)","aud":"\#(project)","sub":"\#(uid)","email":"\#(email)","iat":\#(now - 5),"auth_time":\#(now - 5),"exp":\#(now + 3600)}"#
        return "\(b64url(#"{"alg":"none","typ":"JWT"}"#)).\(b64url(body))."
    }

    private func formEncoded(_ fields: [(String, String)]) -> ByteBuffer {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return ByteBuffer(string: fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&"))
    }

    @Test(.enabled(if: LiqPayCallbackE2EIntegrationTests.isAvailable))
    func signedCallbackDrivesInvoiceOrderSessionAndAudit() async throws {
        let base = try #require(Self.baseURL)
        let firestore = try EmulatorFirestoreHelper.makeFirestore()
        let direct = FirestoreTransaction.direct(firestore: firestore)
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }

        let suffix = EmulatorFirestoreHelper.uniqueId().lowercased()
        let planId = "plan-e2e-\(suffix)", accountId = "account-e2e-\(suffix)", uid = "uid-e2e-\(suffix)"
        let now = Timestamp(exact: Date())

        // Seed what a client / the admin API would have created: an active plan and the account.
        try await firestore.document("plans/\(planId)").setData([
            "id": planId, "SKU": "E2E-\(suffix)", "name": ["en": "E2E"], "description": ["en": "E2E"],
            "isActive": true, "createdAt": now, "updatedAt": now,
            "prices": [["duration": "monthly", "price": [
                "amount": 100, "currency": ["name": "USD", "symbol": "$", "base": 100, "digits": 2] as [String: Any],
            ] as [String: Any]] as [String: Any]],
            "features": [["featureId": "feature-e2e", "quota": ["unit": "count", "limit": 100] as [String: Any]] as [String: Any]],
        ] as [String: Any], firestore: firestore)
        try await firestore.document("accounts/\(accountId)").setData([
            "name": "E2E", "creator": uid, "createdAt": now, "updatedAt": now,
        ] as [String: Any], firestore: firestore)

        // 1. Purchase over HTTP.
        let purchase = try await app.client.post(URI(string: "\(base)/api/v1/accounts/\(accountId)/purchases")) { req in
            req.headers.bearerAuthorization = .init(token: token(uid: uid, email: "\(uid)@example.com"))
            req.headers.contentType = .json
            req.body = ByteBuffer(string: """
            {"planId":"\(planId)","price":{"duration":"monthly","price":{"amount":100,"currencyName":"USD","currencySymbol":"$","currencyBase":100,"currencyDigits":2}}}
            """)
        }
        #expect(purchase.status == .ok)
        let invoiceId = try #require(purchase.body.map { String(buffer: $0) })
        #expect(invoiceId.hasPrefix("invoice-"))

        func data(_ path: String) async throws -> [String: Any] {
            let snapshot = try await firestore.document(path).getDocument(firestore: firestore)
            return try #require(snapshot.data(), "\(path) should exist")
        }
        func auditDocs() async throws -> [[String: Any]] {
            let query = direct.collection("invoices/\(invoiceId)/statuses").and([])
            return try await direct.get(query: query).documents.compactMap { $0.data() }
        }
        func post(_ payload: String, privateKey: String = FakePaymentGateway.emulatorPrivateKey) async throws -> ClientResponse {
            let signed = LiqPayFixtures.callback(json: payload, privateKey: privateKey)
            return try await app.client.post(URI(string: "\(base)/api/v1/payments/liqpay/callback")) { req in
                req.headers.contentType = .urlEncodedForm
                req.body = formEncoded([("data", signed.data), ("signature", signed.signature)])
            }
        }

        let invoice0 = try await data("invoices/\(invoiceId)")
        let orderId = try #require(invoice0["orderId"] as? String)
        #expect(invoice0["status"] as? String == "pending")
        #expect(try await data("accounts/\(accountId)/orders/\(orderId)")["status"] as? String == "created")
        #expect(try await data("accounts/\(accountId)/checkout-sessions/\(invoiceId)")["status"] as? String == "pending")

        // 2. A forged callback is rejected and changes nothing.
        let forged = try await post(
            #"{"order_id":"\#(invoiceId)","status":"success","payment_id":1}"#, privateKey: "someone_elses_key"
        )
        #expect(forged.status == .unauthorized)
        #expect(try await data("invoices/\(invoiceId)")["status"] as? String == "pending")

        // 3. The signed `success` callback.
        let success = #"{"order_id":"\#(invoiceId)","status":"success","payment_id":424242,"transaction_id":424242,"amount":100,"currency":"USD","action":"pay","info":"e2e"}"#
        let first = try await post(success)
        #expect(first.status == .ok)
        #expect(first.body.map { String(buffer: $0) } == "OK")

        let invoice = try await data("invoices/\(invoiceId)")
        #expect(invoice["status"] as? String == "paid")
        #expect(invoice["transactionId"] as? String == "424242")
        #expect(try await data("accounts/\(accountId)/orders/\(orderId)")["status"] as? String == "completed")
        let session = try await data("accounts/\(accountId)/checkout-sessions/\(invoiceId)")
        #expect(session["status"] as? String == "success")
        #expect(session["transactionId"] as? String == "424242")
        #expect(session["errorCode"] is NSNull)
        #expect((session["paymentPageURL"] as? String)?.contains("/3/checkout") == true)

        // Audit trail: the raw payload, once.
        var audit = try await auditDocs()
        #expect(audit.count == 1)
        #expect(audit.first?["status"] as? String == "success")
        #expect(audit.first?["order_id"] as? String == invoiceId)
        // JSON integers stay integers (`integerValue`), not doubles; the client may surface Int or Int64.
        let paymentId = audit.first?["payment_id"]
        #expect(paymentId is Int || paymentId is Int64)
        #expect((paymentId as? Int64) ?? (paymentId as? Int).map(Int64.init) == 424242)

        // 4. LiqPay retries the same callback: 200, nothing doubled (inbox).
        let retry = try await post(success)
        #expect(retry.status == .ok)
        audit = try await auditDocs()
        #expect(audit.count == 1)

        // 5. Renewal (same order_id, new payment): still 200, identity moves, audit grows.
        let renewal = try await post(
            #"{"order_id":"\#(invoiceId)","status":"success","payment_id":434343,"transaction_id":434343,"action":"regular"}"#
        )
        #expect(renewal.status == .ok)
        #expect(try await data("invoices/\(invoiceId)")["transactionId"] as? String == "434343")
        #expect(try await data("invoices/\(invoiceId)")["status"] as? String == "paid")
        #expect(try await auditDocs().count == 2)

        // 6. A late failure after payment is acknowledged and changes nothing.
        let late = try await post(#"{"order_id":"\#(invoiceId)","status":"failure","payment_id":999,"err_code":"x"}"#)
        #expect(late.status == .ok)
        #expect(try await data("invoices/\(invoiceId)")["status"] as? String == "paid")
        #expect(try await data("accounts/\(accountId)/checkout-sessions/\(invoiceId)")["status"] as? String == "success")

        // 7. An unknown invoice is acknowledged too.
        let unknown = try await post(#"{"order_id":"invoice-e2e-unknown-\#(suffix)","status":"success","payment_id":5}"#)
        #expect(unknown.status == .ok)
    }
}
