//
//  Mapper.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 9/13/25.
//

protocol Mapper<Entity, Model, DTO>: Sendable {
    associatedtype Entity
    associatedtype Model
    associatedtype DTO

    init()

    func toModel(entity: Entity) -> Model
    func toEntity(model: Model) throws -> Entity
    func toDTO(entity: Entity) -> DTO
    func toDTO(model: Model) -> DTO
}
