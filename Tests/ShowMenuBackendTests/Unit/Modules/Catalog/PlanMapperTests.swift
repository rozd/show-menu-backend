import Foundation
import Testing
import FirestoreAPI
@testable import ShowMenuBackend

/// Contract tests against the Firestore document Node writes to `plans/{id}`
/// (`PlanMapper.toPersistence`): `{id, SKU, createdAt, updatedAt, name, description,
/// isActive, prices[{price{currency{symbol,name,base,digits},amount},duration}],
/// features[{featureId, quota{unit,limit}}]}`. Flutter reads this directly
/// (`id`, `name`, `description`, `prices`, `isActive`).
@Suite("Plan mapper (Node document shape)")
struct PlanMapperTests {
    let mapper = PlanMapper()

    private let created = Timestamp(seconds: 1_767_225_600, nanos: 123_000_000) // 2026-01-01T00:00:00.123Z
    private let updated = Timestamp(seconds: 1_767_229_200, nanos: 5_000_000)

    /// What Node's admin SDK stores: integers for whole numbers, `null` for absent
    /// currency symbol/base/digits.
    private func nodeDocument(currency: [String: Any]? = nil) -> [String: Any] {
        [
            "id": "plan-0a1b2c3d-0000-4000-8000-000000000001",
            "SKU": "SKU-1700000000000",
            "createdAt": created,
            "updatedAt": updated,
            "name": ["en": "Pro Restaurant Plan", "uk": "План Про"],
            "description": ["en": "Full access"],
            "isActive": false,
            "prices": [
                [
                    "duration": "monthly",
                    "price": [
                        "currency": currency ?? ["symbol": "$", "name": "USD", "base": 100, "digits": 2],
                        "amount": 2900,
                    ] as [String: Any],
                ] as [String: Any],
            ],
            "features": [
                ["featureId": "feature-1", "quota": ["unit": "count", "limit": 100]] as [String: Any],
            ],
        ]
    }

    @Test("decodes a Node document into the entity and Node's PlanResponse")
    func decodeNodeDocument() throws {
        let model = try FirestoreDecoder().decode(PlanModel.self, from: nodeDocument())
        let plan = try mapper.toEntity(model: model)
        #expect(plan.SKU == "SKU-1700000000000")
        #expect(plan.version == .none) // absent `version` adopts lazily (D6)
        #expect(plan.isActive == false)
        #expect(plan.prices.first?.duration == .monthly)
        #expect(plan.prices.first?.price.amount == 2900)
        #expect(plan.prices.first?.price.currency.symbol == "$")
        #expect(plan.features.first?.featureId.rawValue == "feature-1")
        #expect(plan.features.first?.quota == FeatureQuota(unit: .count, limit: 100))

        let dto = mapper.toDTO(entity: plan)
        #expect(dto.createdAt == "2026-01-01T00:00:00.123Z")
        #expect(dto.updatedAt == "2026-01-01T01:00:00.005Z")
    }

    @Test("a Node document with null currency symbol/base/digits decodes")
    func decodeNullCurrencyDetails() throws {
        let doc = nodeDocument(currency: ["symbol": NSNull(), "name": "UAH", "base": NSNull(), "digits": NSNull()])
        let plan = try mapper.toEntity(model: FirestoreDecoder().decode(PlanModel.self, from: doc))
        let currency = try #require(plan.prices.first?.price.currency)
        #expect(currency.name == "UAH")
        #expect(currency.symbol == nil && currency.base == nil && currency.digits == nil)
    }

    @Test("the response keeps the nested prices[].price.currency{symbol,name,base,digits} shape")
    func responseShape() throws {
        let model = try FirestoreDecoder().decode(PlanModel.self, from: nodeDocument())
        let data = try JSONEncoder().encode(mapper.toDTO(model: model))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["id", "createdAt", "updatedAt", "SKU", "name", "description", "isActive", "prices", "features"])
        let price = try #require((json["prices"] as? [[String: Any]])?.first)
        #expect(price["duration"] as? String == "monthly")
        let inner = try #require(price["price"] as? [String: Any])
        #expect(inner["amount"] as? Double == 2900)
        let currency = try #require(inner["currency"] as? [String: Any])
        #expect(Set(currency.keys) == ["symbol", "name", "base", "digits"])
        #expect(currency["name"] as? String == "USD")
        let feature = try #require((json["features"] as? [[String: Any]])?.first)
        #expect(feature["featureId"] as? String == "feature-1")
        #expect((feature["quota"] as? [String: Any])?["unit"] as? String == "count")
    }

    @Test("encodes the same fields as Node, writing absent currency details as explicit null")
    func encodeMatchesNode() throws {
        let plan = Plan(
            id: .init(rawValue: "plan-0a1b2c3d-0000-4000-8000-000000000001"),
            SKU: "SKU-1",
            name: try LocalizedString(["en": "Pro"]),
            description: try LocalizedString(["en": "Desc"]),
            isActive: true,
            prices: [PlanPrice(price: try Price(currency: Currency(name: "UAH"), amount: 100), duration: .yearly)],
            features: [PlanFeature(featureId: .init(rawValue: "feature-1"), quota: FeatureQuota(unit: .level, limit: 2))],
            createdAt: created.asDate,
            updatedAt: updated.asDate
        )
        let encoded = try FirestoreEncoder().encode(mapper.toModel(entity: plan))

        // `version` is additive and omitted until the first versioned write.
        #expect(Set(encoded.keys) == ["id", "SKU", "name", "description", "isActive", "prices", "features", "createdAt", "updatedAt"] as Set<String>)
        #expect(encoded["id"] as? String == "plan-0a1b2c3d-0000-4000-8000-000000000001")
        #expect(encoded["SKU"] as? String == "SKU-1")
        #expect(encoded["isActive"] as? Bool == true)
        #expect((encoded["createdAt"] as? Timestamp) == created)
        #expect((encoded["updatedAt"] as? Timestamp) == updated)

        let prices = try #require(encoded["prices"] as? [[String: Any]])
        #expect(prices.count == 1)
        #expect(prices[0]["duration"] as? String == "yearly")
        let price = try #require(prices[0]["price"] as? [String: Any])
        #expect((price["amount"] as? NSNumber)?.doubleValue == 100)
        let currency = try #require(price["currency"] as? [String: Any])
        #expect(Set(currency.keys) == ["symbol", "name", "base", "digits"])
        #expect(currency["name"] as? String == "UAH")
        #expect(currency["symbol"] is NSNull)
        #expect(currency["base"] is NSNull)
        #expect(currency["digits"] is NSNull)

        let features = try #require(encoded["features"] as? [[String: Any]])
        #expect(features[0]["featureId"] as? String == "feature-1")
        let quota = try #require(features[0]["quota"] as? [String: Any])
        #expect(quota["unit"] as? String == "level")
        #expect((quota["limit"] as? NSNumber)?.doubleValue == 2)
    }

    @Test("round trip preserves everything, including sub-second timestamps")
    func roundTrip() throws {
        let original = try Plan.create(
            SKU: "SKU-RT",
            name: LocalizedString(["en": "A"]),
            description: LocalizedString(["en": "B"]),
            isActive: true,
            prices: [
                PlanPrice(price: try Price(currency: Currency(name: "USD", symbol: "$", base: 100, digits: 2), amount: 29.5), duration: .monthly),
                PlanPrice(price: try Price(currency: Currency(name: "USD"), amount: 295), duration: .yearly),
            ],
            features: [PlanFeature(featureId: .init(rawValue: "feature-9"), quota: FeatureQuota(unit: .duration, limit: 0))],
            now: Date(timeIntervalSince1970: 1_767_225_600.123)
        )
        let encoded = try FirestoreEncoder().encode(mapper.toModel(entity: original))
        let restored = try mapper.toEntity(model: FirestoreDecoder().decode(PlanModel.self, from: encoded))
        #expect(restored.id == original.id)
        #expect(restored.SKU == original.SKU)
        #expect(restored.prices == original.prices)
        #expect(restored.features == original.features)
        #expect(restored.name == original.name && restored.description == original.description)
        #expect(abs(restored.createdAt.timeIntervalSince(original.createdAt)) < 0.001)
    }

    // MARK: Numeric value kinds (Flutter casts `digits as int?`, `(amount as num).toInt()`)

    private func isInteger(_ value: Any?) -> Bool { value is Int || value is Int64 || value is Int32 }

    @Test("whole numbers are encoded as integers, fractions as doubles (JS number semantics)")
    func numericKinds() throws {
        func encode(amount: Double, limit: Double) throws -> [String: Any] {
            let plan = Plan(
                id: .init(rawValue: "plan-1"), SKU: "S",
                name: try LocalizedString(["en": "n"]), description: try LocalizedString(["en": "d"]),
                isActive: true,
                prices: [PlanPrice(
                    price: try Price(currency: Currency(name: "USD", symbol: "$", base: 100, digits: 2), amount: amount),
                    duration: .monthly
                )],
                features: [PlanFeature(featureId: .init(rawValue: "f"), quota: FeatureQuota(unit: .count, limit: limit))]
            )
            return try FirestoreEncoder().encode(mapper.toModel(entity: plan))
        }
        func fields(_ doc: [String: Any]) throws -> (currency: [String: Any], price: [String: Any], quota: [String: Any]) {
            let price = try #require(((doc["prices"] as? [[String: Any]])?.first?["price"]) as? [String: Any])
            let quota = try #require(((doc["features"] as? [[String: Any]])?.first?["quota"]) as? [String: Any])
            return (try #require(price["currency"] as? [String: Any]), price, quota)
        }

        let whole = try fields(encode(amount: 2900, limit: 100))
        #expect(isInteger(whole.currency["digits"]), "digits must be integerValue")
        #expect(isInteger(whole.currency["base"]), "base is an integer in Node-written data")
        #expect(isInteger(whole.price["amount"]), "whole amount is integerValue")
        #expect(isInteger(whole.quota["limit"]), "whole limit is integerValue")

        let fractional = try fields(encode(amount: 29.5, limit: 0.5))
        #expect(fractional.price["amount"] is Double)
        #expect(fractional.quota["limit"] is Double)
    }

    @Test("integer-valued Node numbers decode into the Double fields")
    func decodesIntegerNumbers() throws {
        let doc = nodeDocument() // amount: 2900, limit: 100 (Int literals), base/digits ints
        let model = try FirestoreDecoder().decode(PlanModel.self, from: doc)
        #expect(model.prices[0].price.amount == 2900)
        #expect(model.features[0].quota.limit == 100)
        #expect(model.prices[0].price.currency.digits == 2)
    }

    @Test("Int64-backed integerValues (what the Firestore client returns) decode too")
    func decodesInt64Numbers() throws {
        var doc = nodeDocument()
        var price = try #require((doc["prices"] as? [[String: Any]])?.first)
        var inner = try #require(price["price"] as? [String: Any])
        inner["amount"] = Int64(2900)
        price["price"] = inner
        doc["prices"] = [price]
        doc["features"] = [["featureId": "feature-1", "quota": ["unit": "count", "limit": Int64(100)]] as [String: Any]]
        let model = try FirestoreDecoder().decode(PlanModel.self, from: doc)
        #expect(model.prices[0].price.amount == 2900)
        #expect(model.features[0].quota.limit == 100)
    }
}
