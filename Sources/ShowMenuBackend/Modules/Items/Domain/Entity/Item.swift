import Foundation

final class Item: AggregateRoot, @unchecked Sendable {
    typealias Event = ItemEvent

    let id: Item.Id
    let events: DomainEventRecorder<Event> = .init()

    /// Opaque optimistic-concurrency token; set by the persistence layer on load
    /// and advanced on write. The domain never inspects or increments it.
    var version: Version = .none

    private(set) var name: String
    private(set) var description: String?
    private(set) var createdAt: Date?
    private(set) var updatedAt: Date?

    init(
        id: Item.Id,
        name: String,
        description: String? = nil,
        version: Version = .none,
        createdAt: Date? = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func update(name: String, description: String?) {
        self.name = name
        self.description = description
        self.updatedAt = .now
    }
}

extension Item {
    struct Id: EntityId {
        let rawValue: String
        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }
}

extension Item {
    enum Error: ValidationError {
        case emptyName

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "Item name must not be empty"
            }
        }
    }

    static func validate(name: String) throws {
        guard !name.isEmpty else {
            throw Item.Error.emptyName
        }
    }
}
