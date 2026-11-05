import Foundation
import Testing
import Vapor
import FirestoreAPI
@testable import ShowMenuBackend

/// Roadmap S15 "Done": seeded subscriptions (expired / expiring / still valid) and a paid invoice
/// whose subscription was lost are processed by `POST /api/v1/subscriptions/jobs/check-expired`
/// against the running stack (emulator mode: the scheduler auth is bypassed), and a second call
/// changes nothing.
///
/// Same gating as ``LiqPayCallbackE2EIntegrationTests``: skipped unless `SHOWMENU_E2E_BASE_URL`
/// and the emulator variables are set.
///
/// ```
/// make emulators        # terminal 1
/// make run-local        # terminal 2
/// SHOWMENU_E2E_BASE_URL=http://127.0.0.1:8080 GCP_PROJECT_ID=show-menu-dev \
///   FIRESTORE_EMULATOR_HOST=127.0.0.1:9002 swift test --filter SubscriptionExpirationE2EIntegrationTests
/// ```
///
/// The job scans every account, so the summary counts are asserted as lower bounds (documents of
/// other tests may be in the emulator); the seeded documents themselves are asserted exactly.
@Suite("Subscription expiration job — end to end on the emulator")
struct SubscriptionExpirationE2EIntegrationTests {

    private static var baseURL: String? { Environment.get("SHOWMENU_E2E_BASE_URL") }
    private static var isAvailable: Bool { EmulatorFirestoreHelper.isAvailable && baseURL != nil }

    private func b64url(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

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

    private struct Summary: Decodable {
        let scanned: Int, expired: Int, expiring: Int, reconciled: Int
    }

    @Test(.enabled(if: SubscriptionExpirationE2EIntegrationTests.isAvailable))
    func jobExpiresWarnsReconcilesAndRerunsCleanly() async throws {
        let base = try #require(Self.baseURL)
        let firestore = try EmulatorFirestoreHelper.makeFirestore()
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }

        let suffix = EmulatorFirestoreHelper.uniqueId().lowercased()
        let planId = "plan-e2e-exp-\(suffix)", accountId = "account-e2e-exp-\(suffix)", uid = "uid-e2e-exp-\(suffix)"
        let now = Date()
        let stamp = Timestamp(exact: now)

        func data(_ path: String) async throws -> [String: Any]? {
            try await firestore.document(path).getDocument(firestore: firestore).data()
        }
        func seed(_ name: String, status: String, expiresIn offset: TimeInterval) async throws -> String {
            let id = "sub:e2e-\(suffix)-\(name)"
            let started = Timestamp(exact: now.addingTimeInterval(-40 * 86_400))
            try await firestore.document("accounts/\(accountId)/subscriptions/\(id)").setData([
                "id": id, "createdAt": started, "updatedAt": started, "planId": planId,
                "orderId": "order-e2e-\(suffix)-\(name)", "accountId": accountId, "status": status,
                "startedAt": started, "expiresAt": Timestamp(exact: now.addingTimeInterval(offset)),
                "suspensionReason": NSNull(), "cancellationReason": NSNull(),
            ] as [String: Any], firestore: firestore)
            return id
        }
        func runJob() async throws -> Summary {
            let response = try await app.client.post(URI(string: "\(base)/api/v1/subscriptions/jobs/check-expired"))
            #expect(response.status == .ok)
            let body = try #require(response.body)
            return try JSONDecoder().decode(Summary.self, from: Data(buffer: body))
        }
        /// The fields a re-run must not touch.
        func fingerprint(_ path: String) async throws -> String {
            let doc = try #require(try await data(path), "\(path) should exist")
            let version = (doc["version"] as? Int).map(String.init) ?? (doc["version"] as? Int64).map(String.init) ?? "-"
            let updated = (doc["updatedAt"] as? Timestamp)?.asDate.timeIntervalSince1970 ?? 0
            let expires = (doc["expiresAt"] as? Timestamp)?.asDate.timeIntervalSince1970 ?? 0
            return "\(doc["status"] as? String ?? "?")|\(version)|\(updated)|\(expires)"
        }

        // The account, the plan, and one real purchase that is paid via a signed callback.
        try await firestore.document("plans/\(planId)").setData([
            "id": planId, "SKU": "E2E-EXP-\(suffix)", "name": ["en": "E2E"], "description": ["en": "E2E"],
            "isActive": true, "createdAt": stamp, "updatedAt": stamp,
            "prices": [["duration": "monthly", "price": [
                "amount": 100, "currency": ["name": "USD", "symbol": "$", "base": 100, "digits": 2] as [String: Any],
            ] as [String: Any]] as [String: Any]],
            "features": [["featureId": "feature-e2e", "quota": ["unit": "count", "limit": 100] as [String: Any]] as [String: Any]],
        ] as [String: Any], firestore: firestore)
        try await firestore.document("accounts/\(accountId)").setData([
            "name": "E2E", "creator": uid, "createdAt": stamp, "updatedAt": stamp,
        ] as [String: Any], firestore: firestore)

        let purchase = try await app.client.post(URI(string: "\(base)/api/v1/accounts/\(accountId)/purchases")) { req in
            req.headers.bearerAuthorization = .init(token: token(uid: uid, email: "\(uid)@example.com"))
            req.headers.contentType = .json
            req.body = ByteBuffer(string: """
            {"planId":"\(planId)","price":{"duration":"monthly","price":{"amount":100,"currencyName":"USD","currencySymbol":"$","currencyBase":100,"currencyDigits":2}}}
            """)
        }
        #expect(purchase.status == .ok)
        let invoiceId = try #require(purchase.body.map { String(buffer: $0) })
        let signed = LiqPayFixtures.callback(
            json: #"{"order_id":"\#(invoiceId)","status":"success","payment_id":3001,"transaction_id":3001}"#,
            privateKey: FakePaymentGateway.emulatorPrivateKey
        )
        let callback = try await app.client.post(URI(string: "\(base)/api/v1/payments/liqpay/callback")) { req in
            req.headers.contentType = .urlEncodedForm
            req.body = formEncoded([("data", signed.data), ("signature", signed.signature)])
        }
        #expect(callback.status == .ok)
        let orderId = try #require(try await data("invoices/\(invoiceId)")?["orderId"] as? String)
        let reconciledPath = "accounts/\(accountId)/subscriptions/sub:\(orderId.dropFirst("order-".count))"
        #expect(try await data(reconciledPath)?["status"] as? String == "active")

        // Simulate the crash window: the invoice is paid but its subscription was never written.
        try await firestore.document(reconciledPath).delete(firestore: firestore)
        #expect(try await data(reconciledPath) == nil)

        // Seeded subscriptions around the windows.
        let expired = try await seed("expired", status: "active", expiresIn: -3 * 86_400)
        let expiring = try await seed("expiring", status: "active", expiresIn: -3_600)
        let dueSoon = try await seed("duesoon", status: "active", expiresIn: 12 * 3_600)
        let valid = try await seed("valid", status: "active", expiresIn: 20 * 86_400)
        let suspended = try await seed("suspended", status: "suspended", expiresIn: -5 * 86_400)
        func path(_ id: String) -> String { "accounts/\(accountId)/subscriptions/\(id)" }

        let untouchedBefore = [
            expiring: try await fingerprint(path(expiring)),
            dueSoon: try await fingerprint(path(dueSoon)),
            valid: try await fingerprint(path(valid)),
            suspended: try await fingerprint(path(suspended)),
        ]

        // First run.
        let first = try await runJob()
        #expect(first.expired >= 1 && first.expiring >= 1 && first.reconciled >= 1)
        #expect(first.scanned >= 3) // expired + expiring + dueSoon (valid and suspended are not scanned)

        let expiredDoc = try #require(try await data(path(expired)))
        #expect(expiredDoc["status"] as? String == "expired")
        #expect((expiredDoc["updatedAt"] as? Timestamp)?.asDate ?? .distantPast > now.addingTimeInterval(-5))
        for (id, before) in untouchedBefore {
            #expect(try await fingerprint(path(id)) == before, "\(id) must not be written by the job")
        }

        let recreated = try #require(try await data(reconciledPath), "the lost subscription must be recreated")
        #expect(recreated["status"] as? String == "active")
        #expect(recreated["planId"] as? String == planId && recreated["orderId"] as? String == orderId)
        #expect(recreated["accountId"] as? String == accountId)
        #expect(recreated["lastPaymentRef"] as? String == "3001")

        // Second run: nothing left to expire or reconcile, and no document changes.
        let settled = [expired, expiring, dueSoon, valid, suspended].map(path) + [reconciledPath]
        var afterFirst: [String: String] = [:]
        for p in settled { afterFirst[p] = try await fingerprint(p) }

        let second = try await runJob()
        #expect(second.expired == 0 && second.reconciled == 0)
        #expect(second.expiring >= 1) // the warning window is stateless: it repeats, writing nothing
        for p in settled {
            #expect(try await fingerprint(p) == afterFirst[p], "\(p) changed on the re-run")
        }
    }
}
