import Foundation
import ShowMenuContracts

/// IAM's mapping from `UserDTO` to the generated wire `User`. Absent optionals stay absent
/// (omitted on the wire, never `null`). An unparseable stored date throws
/// ``InvalidDateStringError`` (a data-integrity fault, 500).
enum IAMWireMapper {

    static func wire(_ dto: UserDTO) throws -> Components.Schemas.User {
        .init(
            id: dto.id,
            email: dto.email,
            name: dto.name,
            avatarURL: dto.avatarURL,
            accounts: dto.accounts,
            version: dto.version,
            createdAt: try dto.createdAt.map(Date.parseISOOrThrow),
            updatedAt: try dto.updatedAt.map(Date.parseISOOrThrow)
        )
    }
}
