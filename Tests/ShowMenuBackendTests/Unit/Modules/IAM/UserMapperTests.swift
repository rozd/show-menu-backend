import Foundation
import Testing
@testable import ShowMenuBackend

/// Round-trip tests for `UserMapper`, focused on the `roles` field: it crosses
/// three representations (`Set<Role>` on the entity, sorted `[String]` on the
/// model and DTO) and an absent model field must map to an empty set — the
/// no-data-migration posture shared with `version`.
@Suite("User Mapper")
struct UserMapperTests {

    private let mapper = UserMapper()

    @Test("roles round-trip entity → model → entity")
    func rolesRoundTrip() throws {
        let entity = User(
            id: User.Id(rawValue: "u1"),
            email: "a@b.c",
            roles: [Role(rawValue: "support"), .admin]
        )

        let model = mapper.toModel(entity: entity)
        #expect(model.roles == ["admin", "support"])

        let restored = try mapper.toEntity(model: model)
        #expect(restored.roles == [.admin, Role(rawValue: "support")])
    }

    @Test("absent model roles decode as an empty role set")
    func absentRoles() throws {
        let model = UserModel(id: "u1", roles: nil)
        let entity = try mapper.toEntity(model: model)
        #expect(entity.roles.isEmpty)

        let dto = mapper.toDTO(model: model)
        #expect(dto.roles.isEmpty)
    }

    @Test("DTO carries sorted roles from both entity and model")
    func dtoCarriesRoles() {
        let entity = User(
            id: User.Id(rawValue: "u1"),
            roles: [Role(rawValue: "b"), Role(rawValue: "a")]
        )
        #expect(mapper.toDTO(entity: entity).roles == ["a", "b"])

        let model = UserModel(id: "u1", roles: ["b", "a"])
        #expect(mapper.toDTO(model: model).roles == ["a", "b"])
    }
}
