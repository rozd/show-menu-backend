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

    /// Default payer-facing language.
    static let defaultLanguage = "en"

    /// Builds and signs the envelope.
    /// - Parameters:
    ///   - serverURL: where LiqPay POSTs the result (`server_url`).
    ///   - defaultResultURL: used when the request carries no `resultURL`.
    static func make(
        request: CheckoutRequest,
        credentials: LiqPayCredentials,
        serverURL: String,
        defaultResultURL: String?
    ) throws -> LiqPayCheckoutEnvelope {
        // The amount is the exact decimal rendering of the minor units, so 1999 is
        // 19.99 and never 19.989999...
        guard let amount = Decimal(string: request.money.decimalString, locale: Locale(identifier: "en_US_POSIX")) else {
            throw PaymentGatewayError.invalidPayload("Unrepresentable amount \(request.money.decimalString)")
        }

        let action: String
        let subscribe: String?
        let periodicity: String?
        let dateStart: String?
        switch request.kind {
        case .oneOff:
            action = "pay"
            subscribe = nil
            periodicity = nil
            dateStart = nil
        case let .monthlySubscription(startDate):
            action = "subscribe"
            subscribe = "1"
            periodicity = "month"
            dateStart = formatStart(startDate)
        }

        let payload = Payload(
            version: apiVersion,
            publicKey: credentials.publicKey.rawValue,
            action: action,
            amount: amount,
            currency: request.money.currency,
            description: request.description,
            orderId: request.orderId,
            serverURL: serverURL,
            resultURL: request.resultURL ?? defaultResultURL,
            language: request.language ?? defaultLanguage,
            subscribe: subscribe,
            subscribePeriodicity: periodicity,
            subscribeDateStart: dateStart
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
