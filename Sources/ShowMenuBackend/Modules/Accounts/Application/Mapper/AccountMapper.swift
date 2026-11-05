import Foundation

/// Read-only mapper for `accounts/{id}`. Accounts are written by the client, so
/// there is no `toModel`/`toDTO` direction (and hence no `Mapper` conformance).
struct AccountMapper: Sendable {

    init() {}

    /// A document without a usable `creator` cannot be linked to anyone.
    func toEntity(model: AccountModel) throws -> Account {
        guard let creator = model.creator, !creator.isEmpty else {
            throw MappingError.missingRequiredField(field: "creator")
        }
        return Account(id: model.id, name: model.name, creator: creator)
    }
}
