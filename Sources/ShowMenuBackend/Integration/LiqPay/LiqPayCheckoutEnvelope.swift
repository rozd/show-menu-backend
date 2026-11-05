import Foundation
import LiqPayClient

/// The signed `data` + `signature` pair LiqPay's `/3/checkout` expects.
///
/// Mirrors the package's internal (non-public) envelope encoder: sorted-key JSON,
/// base64-encoded, so the exact bytes we sign are the exact bytes LiqPay re-signs.
struct LiqPayCheckoutEnvelope: Sendable, Equatable {
    let data: String
    let signature: String

    /// LiqPay API version; mirrors the package's internal `Client.apiVersion`.
    static let apiVersion = 3

    /// Default payer-facing language (the old Firebase extension defaulted to `en`).
    static let defaultLanguage = "en"

    /// Builds and signs the envelope.
    /// - Parameters:
    ///   - serverURL: where LiqPay POSTs the result (`server_url`).
    ///   - defaultResultURL: used when the request carries no `resultURL`.
    ///   - now: clock for `subscribe_date_start`.
    static func make(
        request: CheckoutRequest,
        credentials: LiqPayCredentials,
        serverURL: String,
        defaultResultURL: String?,
        now: Date
    ) throws -> LiqPayCheckoutEnvelope {
        // Shortest decimal form, so 19.99 does not become 19.989999...
        guard let amount = Decimal(string: "\(request.amount)") else {
            throw PaymentGatewayError.invalidPayload("Unrepresentable amount \(request.amount)")
        }

        let payload = Payload(
            version: apiVersion,
            publicKey: credentials.publicKey.rawValue,
            action: request.subscription == nil ? "pay" : "subscribe",
            amount: amount,
            currency: request.currency,
            description: request.description,
            orderId: request.orderId,
            serverURL: serverURL,
            resultURL: request.resultURL ?? defaultResultURL,
            language: request.language ?? defaultLanguage,
            subscribe: request.subscription == nil ? nil : "1",
            subscribePeriodicity: request.subscription.map(periodicity(for:)),
            subscribeDateStart: request.subscription == nil ? nil : formatStart(now)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: String
        do {
            data = try encoder.encode(payload).base64EncodedString()
        } catch {
            throw PaymentGatewayError.invalidPayload("Failed to encode checkout payload: \(error)")
        }
        let signature = LiqPaySigner.sign(privateKey: credentials.privateKey, data: data)
        return LiqPayCheckoutEnvelope(data: data, signature: signature)
    }

    /// LiqPay `subscribe_periodicity` vocabulary (the old extension's `annually`
    /// lookup was a bug: LiqPay's value is `year`).
    static func periodicity(for duration: SubscriptionDuration) -> String {
        switch duration {
        case .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        case .yearly: "year"
        }
    }

    /// `yyyy-MM-dd HH:mm:ss`, UTC.
    static func formatStart(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Optional fields use synthesized `encodeIfPresent`, so nil is omitted.
    private struct Payload: Encodable {
        let version: Int
        let publicKey: String
        let action: String
        let amount: Decimal
        let currency: String
        let description: String
        let orderId: String
        let serverURL: String
        let resultURL: String?
        let language: String?
        let subscribe: String?
        let subscribePeriodicity: String?
        let subscribeDateStart: String?

        enum CodingKeys: String, CodingKey {
            case version, action, amount, currency, description, language, subscribe
            case publicKey = "public_key"
            case orderId = "order_id"
            case serverURL = "server_url"
            case resultURL = "result_url"
            case subscribePeriodicity = "subscribe_periodicity"
            case subscribeDateStart = "subscribe_date_start"
        }
    }
}
