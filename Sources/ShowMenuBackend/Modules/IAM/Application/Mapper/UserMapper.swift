import Foundation
import FirestoreAPI

struct UserMapper: Mapper, Sendable {
    typealias Entity = User
    typealias Model = UserModel
    typealias DTO = UserDTO

    init() {}

    func toModel(entity: User) -> UserModel {
        UserModel(
            id: entity.id.rawValue,
            email: entity.email,
            name: entity.name,
            avatarURL: entity.avatarURL,
            accounts: entity.accounts,
            // Not in Node's schema: only written when it matters.
            disabled: entity.disabled ? true : nil,
            version: entity.version.versionInt,
            createdAt: Timestamp(exact: entity.createdAt),
            updatedAt: Timestamp(exact: entity.updatedAt)
        )
    }

    func toEntity(model: UserModel) throws -> User {
        let createdAt = model.createdAt?.asDate ?? .now
        return User(
            id: User.Id(rawValue: model.id),
            email: model.email,
            name: model.name,
            avatarURL: model.avatarURL,
            accounts: model.accounts ?? [],
            disabled: model.disabled ?? false,
            version: Version(versionInt: model.version),
            createdAt: createdAt,
            updatedAt: model.updatedAt?.asDate ?? createdAt
        )
    }

    func toDTO(entity: User) -> UserDTO {
        UserDTO(
            id: entity.id.rawValue,
            email: entity.email,
            name: entity.name,
            avatarURL: entity.avatarURL,
            accounts: entity.accounts,
            version: entity.version.rawValue,
            createdAt: entity.createdAt.jsISOString,
            updatedAt: entity.updatedAt.jsISOString
        )
    }

    func toDTO(model: UserModel) -> UserDTO {
        UserDTO(
            id: model.id,
            email: model.email,
            name: model.name,
            avatarURL: model.avatarURL,
            accounts: model.accounts ?? [],
            version: Version(versionInt: model.version).rawValue,
            createdAt: model.createdAt.map { $0.asDate.jsISOString },
            updatedAt: model.updatedAt.map { $0.asDate.jsISOString }
        )
    }
}
