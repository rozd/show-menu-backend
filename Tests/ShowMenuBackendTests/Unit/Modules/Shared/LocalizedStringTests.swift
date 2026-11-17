import Foundation
import Testing
@testable import ShowMenuBackend

@Suite("LocalizedString")
struct LocalizedStringTests {

    @Test("uk is required and must be non-empty")
    func ukRequired() throws {
        _ = try LocalizedString(["uk": "Привіт"])
        #expect(throws: LocalizedString.Error.ukrainianRequired) { try LocalizedString([:]) }
        #expect(throws: LocalizedString.Error.ukrainianRequired) { try LocalizedString(["en": "Hi"]) }
        #expect(throws: LocalizedString.Error.ukrainianRequired) { try LocalizedString(["uk": "", "en": "Hi"]) }
    }

    @Test("en and other languages are optional extras")
    func extras() throws {
        let s = try LocalizedString(["uk": "Привіт", "en": "Hi", "pl": "Cześć"])
        #expect(s.uk == "Привіт")
        #expect(s["en"] == "Hi")
        #expect(s["de"] == nil)
    }

    @Test("encodes as a plain map and round-trips")
    func codable() throws {
        let s = try LocalizedString(["uk": "Привіт", "en": "Hi"])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: String]
        #expect(object == ["uk": "Привіт", "en": "Hi"])
        #expect(try JSONDecoder().decode(LocalizedString.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test("decoding without uk fails")
    func decodeRejects() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LocalizedString.self, from: Data("{}".utf8)) }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LocalizedString.self, from: Data(#"{"en":"Hi"}"#.utf8))
        }
    }
}
