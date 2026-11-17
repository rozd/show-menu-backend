import Foundation

struct UserMapper: Mapper, Sendable {
    typealias Entity = User
    typealias Model = UserModel
    typealias DTO = UserDTO

    init() {}

    func toModel(entity: User) -> UserModel {
        UserModel(
            id: entity.id.rawValue,
            email: entity.email,
            phone: entity.phone,
            username: entity.username,
            displayName: entity.displayName,
            photoURL: entity.photoURL,
            emailVerified: entity.emailVerified,
            phoneVerified: entity.phoneVerified,
            disabled: entity.disabled,
            roles: entity.roles.map(\.rawValue).sorted(),
            version: entity.version.versionInt,
            createdAt: entity.createdAt
        )
    }

    func toEntity(model: UserModel) throws -> User {
        User(
            id: User.Id(rawValue: model.id),
            email: model.email,
            phone: model.phone,
            username: model.username,
            displayName: model.displayName,
            photoURL: model.photoURL,
            emailVerified: model.emailVerified ?? false,
            phoneVerified: model.phoneVerified ?? false,
            disabled: model.disabled ?? false,
            roles: Set((model.roles ?? []).map(Role.init(rawValue:))),
            version: Version(versionInt: model.version),
            createdAt: model.createdAt
        )
    }

    func toDTO(entity: User) -> UserDTO {
        let formatter = ISO8601DateFormatter()
        return UserDTO(
            id: entity.id.rawValue,
            email: entity.email,
            phone: entity.phone,
            username: entity.username,
            displayName: entity.displayName,
            photoURL: entity.photoURL,
            emailVerified: entity.emailVerified,
            phoneVerified: entity.phoneVerified,
            disabled: entity.disabled,
            roles: entity.roles.map(\.rawValue).sorted(),
            version: entity.version.rawValue,
            createdAt: entity.createdAt.map { formatter.string(from: $0) }
        )
    }

    func toDTO(model: UserModel) -> UserDTO {
        let formatter = ISO8601DateFormatter()
        return UserDTO(
            id: model.id,
            email: model.email,
            phone: model.phone,
            username: model.username,
            displayName: model.displayName,
            photoURL: model.photoURL,
            emailVerified: model.emailVerified ?? false,
            phoneVerified: model.phoneVerified ?? false,
            disabled: model.disabled ?? false,
            roles: (model.roles ?? []).sorted(),
            version: Version(versionInt: model.version).rawValue,
            createdAt: model.createdAt.map { formatter.string(from: $0) }
        )
    }
}
