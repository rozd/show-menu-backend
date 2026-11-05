import Foundation

final class User: AggregateRoot, @unchecked Sendable {
    typealias Event = UserEvent

    let id: User.Id
    let events: DomainEventRecorder<Event> = .init()

    /// Opaque optimistic-concurrency token; set by the persistence layer on load
    /// and advanced on write. The domain never inspects or increments it.
    var version: Version = .none

    private(set) var email: String?
    private(set) var name: String?
    private(set) var avatarURL: String?
    /// Ids of the accounts this user belongs to (`users/{uid}.accounts`, read by Flutter).
    private(set) var accounts: [String]
    /// Template-only moderation flag. Not part of Node's schema: persisted only when `true`.
    private(set) var disabled: Bool
    private(set) var createdAt: Date
    private(set) var updatedAt: Date

    init(
        id: User.Id,
        email: String? = nil,
        name: String? = nil,
        avatarURL: String? = nil,
        accounts: [String] = [],
        disabled: Bool = false,
        version: Version = .none,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.name = name
        self.avatarURL = avatarURL
        self.accounts = accounts
        self.disabled = disabled
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Links an account to this user. Idempotent: a duplicate is a no-op (no event,
    /// `updatedAt` kept). Records the semantic `user.account.added` event.
    func addAccount(_ accountId: String, now: Date = .now) {
        guard !accounts.contains(accountId) else { return }
        accounts.append(accountId)
        updatedAt = now
        record(event: .accountAdded(aggregateId: id))
    }

    /// Unlinks an account. Idempotent: an absent account is a no-op.
    func removeAccount(_ accountId: String, now: Date = .now) {
        guard accounts.contains(accountId) else { return }
        accounts.removeAll { $0 == accountId }
        updatedAt = now
        record(event: .accountRemoved(aggregateId: id))
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
