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
            displayName: entity.displayName,
            photoURL: entity.photoURL,
            emailVerified: entity.emailVerified,
            disabled: entity.disabled,
            version: entity.version.versionInt,
            createdAt: entity.createdAt
        )
    }

    func toEntity(model: UserModel) throws -> User {
        User(
            id: User.Id(rawValue: model.id),
            email: model.email,
            displayName: model.displayName,
            photoURL: model.photoURL,
            emailVerified: model.emailVerified ?? false,
            disabled: model.disabled ?? false,
            version: Version(versionInt: model.version),
            createdAt: model.createdAt
        )
    }

    func toDTO(entity: User) -> UserDTO {
        let formatter = ISO8601DateFormatter()
        return UserDTO(
            id: entity.id.rawValue,
            email: entity.email,
            displayName: entity.displayName,
            photoURL: entity.photoURL,
            emailVerified: entity.emailVerified,
            disabled: entity.disabled,
            version: entity.version.rawValue,
            createdAt: entity.createdAt.map { formatter.string(from: $0) }
        )
    }

    func toDTO(model: UserModel) -> UserDTO {
        let formatter = ISO8601DateFormatter()
        return UserDTO(
            id: model.id,
            email: model.email,
            displayName: model.displayName,
            photoURL: model.photoURL,
            emailVerified: model.emailVerified ?? false,
            disabled: model.disabled ?? false,
            version: Version(versionInt: model.version).rawValue,
            createdAt: model.createdAt.map { formatter.string(from: $0) }
        )
    }
}
