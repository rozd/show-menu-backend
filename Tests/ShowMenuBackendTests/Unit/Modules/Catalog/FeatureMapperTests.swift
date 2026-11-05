import Foundation
import Testing
import FirestoreAPI
@testable import ShowMenuBackend

/// Contract tests against the Firestore document Node writes to `features/{id}`
/// (`FeatureMapper.toPersistence`): `{id, createdAt, updatedAt, category, name,
/// description}` with Timestamps and an explicit `description: null`.
@Suite("Feature mapper (Node document shape)")
struct FeatureMapperTests {
    let mapper = FeatureMapper()

    private let created = Timestamp(seconds: 1_767_225_600, nanos: 123_000_000) // 2026-01-01T00:00:00.123Z
    private let updated = Timestamp(seconds: 1_767_229_200, nanos: 5_000_000)

    private func nodeDocument(description: Any) -> [String: Any] {
        [
            "id": "feature-0a1b2c3d-0000-4000-8000-000000000001",
            "category": "ai",
            "name": ["en": "AI Menu Generator", "uk": "Генератор меню ШІ"],
            "description": description,
            "createdAt": created,
            "updatedAt": updated,
        ]
    }

    @Test("decodes a Node document (with description) and maps to entity + response")
    func decodeNodeDocument() throws {
        let model = try FirestoreDecoder().decode(
            FeatureModel.self,
            from: nodeDocument(description: ["en": "Desc"])
        )
        let feature = try mapper.toEntity(model: model)
        #expect(feature.id.rawValue == "feature-0a1b2c3d-0000-4000-8000-000000000001")
        #expect(feature.category == .ai)
        #expect(feature.version == .none) // absent `version` adopts lazily (D6)
        #expect(feature.createdAt.timeIntervalSince1970 == 1_767_225_600.123)

        let dto = mapper.toDTO(entity: feature)
        #expect(dto.createdAt == "2026-01-01T00:00:00.123Z")
        #expect(dto.updatedAt == "2026-01-01T01:00:00.005Z")
        #expect(dto.description == ["en": "Desc"])
    }

    @Test("a Node document with description: null decodes to nil and the response omits it")
    func decodeNullDescription() throws {
        let model = try FirestoreDecoder().decode(FeatureModel.self, from: nodeDocument(description: NSNull()))
        let feature = try mapper.toEntity(model: model)
        #expect(feature.description == nil)

        let json = try String(decoding: JSONEncoder().encode(mapper.toDTO(entity: feature)), as: UTF8.self)
        #expect(!json.contains("description"))
    }

    @Test("encodes the same fields as Node, writing description as explicit null")
    func encodeMatchesNode() throws {
        let feature = Feature(
            id: .init(rawValue: "feature-0a1b2c3d-0000-4000-8000-000000000001"),
            category: .technicalSupport,
            name: try LocalizedString(["en": "Support"]),
            description: nil,
            createdAt: created.asDate,
            updatedAt: updated.asDate
        )
        let encoded = try FirestoreEncoder().encode(mapper.toModel(entity: feature))

        // `version` is additive and omitted until the first versioned write.
        #expect(Set(encoded.keys) == ["id", "category", "name", "description", "createdAt", "updatedAt"] as Set<String>)
        #expect(encoded["id"] as? String == "feature-0a1b2c3d-0000-4000-8000-000000000001")
        #expect(encoded["category"] as? String == "technicalSupport")
        #expect(encoded["name"] as? [String: String] == ["en": "Support"])
        #expect(encoded["description"] is NSNull)
        #expect((encoded["createdAt"] as? Timestamp) == created)
        #expect((encoded["updatedAt"] as? Timestamp) == updated)
    }

    @Test("round trip preserves sub-second timestamps and description")
    func roundTrip() throws {
        let original = try Feature.create(
            category: .ai,
            name: LocalizedString(["en": "A"]),
            description: LocalizedString(["en": "B"]),
            now: Date(timeIntervalSince1970: 1_767_225_600.123)
        )
        let encoded = try FirestoreEncoder().encode(mapper.toModel(entity: original))
        let decoded = try FirestoreDecoder().decode(FeatureModel.self, from: encoded)
        let restored = try mapper.toEntity(model: decoded)
        #expect(restored.id == original.id)
        #expect(restored.description == original.description)
        #expect(abs(restored.createdAt.timeIntervalSince(original.createdAt)) < 0.001)
    }

    @Test("a millisecond-aligned Node timestamp survives Date and back unchanged")
    func millisecondTimestampIsStable() {
        #expect(Timestamp(exact: created.asDate) == created)
        #expect(Timestamp(exact: updated.asDate) == updated)
    }
}
