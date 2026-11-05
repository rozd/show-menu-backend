import Foundation

/// An `EntityId` whose raw value is `<prefix><lowercase-uuid>` (`plan-…`,
/// `feature-…`, `order-…`, `invoice-…`), matching Node's `randomUUID()` ids.
protocol PrefixedEntityId: EntityId where RawValue == String {
    static var prefix: String { get }
}

extension PrefixedEntityId {
    static func generate() -> Self {
        Self(rawValue: PrefixedId.make(prefix: prefix))
    }
}

enum PrefixedId {
    static func make(prefix: String, uuid: UUID = UUID()) -> String {
        prefix + uuid.uuidString.lowercased()
    }
}
