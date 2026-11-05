import Foundation

struct ItemMapper: Mapper, Sendable {
    typealias Entity = Item
    typealias Model = ItemModel
    typealias DTO = ItemDTO

    init() {}

    func toModel(entity: Item) -> ItemModel {
        ItemModel(
            id: entity.id.rawValue,
            name: entity.name,
            description: entity.description,
            version: entity.version.versionInt,
            createdAt: .init(entity.createdAt),
            updatedAt: .init(entity.updatedAt),
        )
    }

    func toEntity(model: ItemModel) throws -> Item {
        Item(
            id: Item.Id(rawValue: model.id),
            name: model.name,
            description: model.description,
            version: Version(versionInt: model.version),
            createdAt: .init(model.createdAt),
            updatedAt: .init(model.updatedAt),
        )
    }

    func toDTO(entity: Item) -> ItemDTO {
        let formatter = ISO8601DateFormatter()
        return ItemDTO(
            id: entity.id.rawValue,
            name: entity.name,
            description: entity.description,
            version: entity.version.rawValue,
            createdAt: entity.createdAt.map { formatter.string(from: $0) },
            updatedAt: entity.updatedAt.map { formatter.string(from: $0) },
        )
    }

    func toDTO(model: ItemModel) -> ItemDTO {
        let formatter = ISO8601DateFormatter()
        return ItemDTO(
            id: model.id,
            name: model.name,
            description: model.description,
            version: Version(versionInt: model.version).rawValue,
            createdAt: Date(model.createdAt).map { formatter.string(from: $0) },
            updatedAt: Date(model.updatedAt).map { formatter.string(from: $0) },
        )
    }
}
