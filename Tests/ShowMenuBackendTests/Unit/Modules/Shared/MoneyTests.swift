import Foundation
import Testing
@testable import ShowMenuBackend

@Suite("Money")
struct MoneyTests {

    @Test("valid amount and currency")
    func valid() throws {
        let money = try Money(amount: 0, currency: "UAH")
        #expect(money.amount == 0)
        #expect(money.currency == "UAH")
    }

    @Test("negative amount is rejected")
    func negative() {
        #expect(throws: Money.Error.negativeAmount) { try Money(amount: -1, currency: "UAH") }
    }

    @Test("currency must be three uppercase letters", arguments: ["", "UA", "UAHH", "uah", "U1H", "ЮАН"])
    func badCurrency(code: String) {
        #expect(throws: Money.Error.invalidCurrency(code)) { try Money(amount: 1, currency: code) }
    }

    @Test("decimal string uses 2 fraction digits",
          arguments: [(Int64(39000), "390.00"), (5, "0.05"), (0, "0.00"), (1999, "19.99"), (100, "1.00"), (10, "0.10")])
    func decimal(minor: Int64, expected: String) throws {
        #expect(try Money(amount: minor, currency: "UAH").decimalString == expected)
    }

    @Test("Codable round trip, and decoding validates")
    func codable() throws {
        let money = try Money(amount: 1999, currency: "UAH")
        let data = try JSONEncoder().encode(money)
        #expect(try JSONDecoder().decode(Money.self, from: data) == money)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Money.self, from: Data(#"{"amount":-5,"currency":"UAH"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Money.self, from: Data(#"{"amount":5,"currency":"uah"}"#.utf8))
        }
    }
}
