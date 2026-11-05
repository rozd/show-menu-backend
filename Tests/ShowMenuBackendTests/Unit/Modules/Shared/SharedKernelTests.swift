import Foundation
import Testing
import FirestoreAPI
@testable import ShowMenuBackend

@Suite("Shared kernel")
struct SharedKernelTests {

    private func roundTrip<T: Codable>(_ v: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(v))
    }
    private func json(_ v: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as! [String: Any]
    }

    @Test("LocalizedString encodes as a plain map and rejects empty")
    func localized() throws {
        let s = try LocalizedString(["en": "Hi", "uk": "Привіт"])
        #expect(try json(s) as? [String: String] == ["en": "Hi", "uk": "Привіт"])
        #expect(try roundTrip(s) == s)
        #expect(throws: LocalizedString.Error.empty) { try LocalizedString([:]) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LocalizedString.self, from: Data("{}".utf8)) }
    }

    @Test("Currency writes explicit nulls and requires a name")
    func currency() throws {
        let c = try Currency(name: "UAH")
        let obj = try json(c)
        #expect(Set(obj.keys) == ["symbol", "name", "base", "digits"])
        #expect(obj["symbol"] is NSNull)
        #expect(try roundTrip(c) == c)
        let decoded = try JSONDecoder().decode(Currency.self, from: Data(#"{"name":"USD","symbol":"$"}"#.utf8))
        #expect(decoded.symbol == "$" && decoded.base == nil)
        #expect(throws: Currency.Error.nameRequired) { try Currency(name: "") }
    }

    @Test("Price allows zero, rejects negative")
    func price() throws {
        let c = try Currency(name: "UAH")
        _ = try Price(currency: c, amount: 0)
        #expect(throws: Price.Error.negativeAmount) { try Price(currency: c, amount: -1) }
        #expect(try roundTrip(Price(currency: c, amount: 9.5)).amount == 9.5)
    }

    @Test("SubscriptionDuration raw values and add(to:)")
    func duration() throws {
        #expect(SubscriptionDuration.allCases.map(\.rawValue) == ["daily", "weekly", "monthly", "yearly"])
        let jan31 = ISO8601DateFormatter().date(from: "2024-01-31T10:00:00Z")!
        let fmt = ISO8601DateFormatter()
        #expect(fmt.string(from: SubscriptionDuration.daily.add(to: jan31)) == "2024-02-01T10:00:00Z")
        #expect(fmt.string(from: SubscriptionDuration.weekly.add(to: jan31)) == "2024-02-07T10:00:00Z")
        #expect(fmt.string(from: SubscriptionDuration.monthly.add(to: jan31)) == "2024-02-29T10:00:00Z")
        #expect(fmt.string(from: SubscriptionDuration.yearly.add(to: jan31)) == "2025-01-31T10:00:00Z")
    }

    @Test("PrefixedId produces prefix + lowercase uuid")
    func prefixed() {
        struct PlanId: PrefixedEntityId {
            static let prefix = "plan-"
            let rawValue: String
        }
        let id = PlanId.generate().rawValue
        #expect(id.hasPrefix("plan-"))
        let rest = String(id.dropFirst(5))
        #expect(UUID(uuidString: rest) != nil)
        #expect(rest == rest.lowercased())
    }

    @Test("Timestamp helpers are lossless")
    func timestamps() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.25)
        let ts = Timestamp(exact: date)
        #expect(ts.seconds == 1_700_000_000)
        #expect(ts.nanos == 250_000_000)
        #expect(ts.asDate == date)
        let neg = Timestamp(exact: Date(timeIntervalSince1970: -1.5))
        #expect(neg.seconds == -2 && neg.nanos == 500_000_000)
    }

    @Test("PriceDTO validates and converts both ways")
    func priceDTO() throws {
        let dto = PriceDTO(currencyName: "UAH", amount: 10)
        let price = try dto.toPrice()
        #expect(PriceDTO(price) == dto)
        #expect(throws: PriceDTO.Error.currencyNameTooShort) { try PriceDTO(currencyName: "U", amount: 1).validate() }
        #expect(throws: PriceDTO.Error.amountNotPositive) { try PriceDTO(currencyName: "UAH", amount: 0).validate() }
        let decoded = try JSONDecoder().decode(PriceDTO.self, from: Data(#"{"currencyName":"UAH","amount":3}"#.utf8))
        #expect(decoded.currencyBase == nil)
    }
}
