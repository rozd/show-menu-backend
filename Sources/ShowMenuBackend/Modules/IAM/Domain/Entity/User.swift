import Foundation

final class User: AggregateRoot, @unchecked Sendable {
    typealias Event = UserEvent

    let id: User.Id
    let events: DomainEventRecorder<Event> = .init()

    /// Opaque optimistic-concurrency token; set by the persistence layer on load
    /// and advanced on write. The domain never inspects or increments it.
    var version: Version = .none

    private(set) var email: String?
    private(set) var phone: String?
    private(set) var username: String?
    private(set) var displayName: String?
    private(set) var photoURL: String?
    private(set) var emailVerified: Bool
    private(set) var phoneVerified: Bool
    private(set) var disabled: Bool
    /// Coarse-grained authorization roles held by this user, resolved into
    /// `Principal.roles` at the request boundary. Empty for a fresh account;
    /// concrete values (e.g. `.admin`) are assigned out of band.
    private(set) var roles: Set<Role>
    private(set) var createdAt: Date?

    init(
        id: User.Id,
        email: String? = nil,
        phone: String? = nil,
        username: String? = nil,
        displayName: String? = nil,
        photoURL: String? = nil,
        emailVerified: Bool = false,
        phoneVerified: Bool = false,
        disabled: Bool = false,
        roles: Set<Role> = [],
        version: Version = .none,
        createdAt: Date? = .now
    ) {
        self.id = id
        self.email = email
        self.phone = phone
        self.username = username
        self.displayName = displayName
        self.photoURL = photoURL
        self.emailVerified = emailVerified
        self.phoneVerified = phoneVerified
        self.disabled = disabled
        self.roles = roles
        self.version = version
        self.createdAt = createdAt
    }
}

extension User {
    struct Id: EntityId {
        let rawValue: String
        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }
}

extension User {
    enum Error: ValidationError {
        case emptyId

        var errorDescription: String? {
            switch self {
            case .emptyId:
                return "User ID must not be empty"
            }
        }
    }

    static func validate(id: String) throws {
        guard !id.isEmpty else {
            throw User.Error.emptyId
        }
    }
}
