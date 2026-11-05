import Foundation

/// Product feature a subscription plan can grant (`features/{id}`).
///
/// Mirrors Node's `Feature` aggregate: `update` is a *partial* update — an absent
/// argument keeps the current value (Node: `props.x || this.x`), so a stored
/// `description` can be replaced but never cleared.
final class Feature: AggregateRoot, @unchecked Sendable {
    typealias Event = FeatureEvent

    let id: Feature.Id
    let events: DomainEventRecorder<Event> = .init()

    /// Opaque optimistic-concurrency token; set by the persistence layer on load
    /// and advanced on write. The domain never inspects or increments it.
    var version: Version = .none

    private(set) var category: FeatureCategory
    private(set) var name: LocalizedString
    private(set) var description: LocalizedString?
    private(set) var createdAt: Date
    private(set) var updatedAt: Date

    /// Rehydration initializer (no validation, no events): used by the mapper.
    init(
        id: Feature.Id,
        category: FeatureCategory,
        name: LocalizedString,
        description: LocalizedString? = nil,
        version: Version = .none,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.name = name
        self.description = description
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Creates a new feature and records the semantic `FeatureAdded` event.
    /// The lifecycle `created` event is recorded by the Repository on insert.
    static func create(
        category: FeatureCategory,
        name: LocalizedString,
        description: LocalizedString?,
        now: Date = .now
    ) throws -> Feature {
        try validate(name: name, description: description)
        let feature = Feature(
            id: .generate(),
            category: category,
            name: name,
            description: description,
            createdAt: now,
            updatedAt: now
        )
        feature.record(event: .featureAdded(aggregateId: feature.id))
        return feature
    }

    /// Partial update; `nil` keeps the current value. Records `FeatureUpdated`.
    func update(
        category: FeatureCategory? = nil,
        name: LocalizedString? = nil,
        description: LocalizedString? = nil,
        now: Date = .now
    ) throws {
        let newName = name ?? self.name
        let newDescription = description ?? self.description
        try Feature.validate(name: newName, description: newDescription)
        self.category = category ?? self.category
        self.name = newName
        self.description = newDescription
        self.updatedAt = now
        record(event: .featureModified(aggregateId: id))
    }
}

extension Feature {
    struct Id: PrefixedEntityId {
        static let prefix = "feature-"

        let rawValue: String
        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }
}

extension Feature {
    enum Error: ValidationError, LocalizedError, Equatable {
        case categoryRequired
        case invalidCategory(String)
        case nameRequired
        case blankName
        case blankDescription

        var errorDescription: String? {
            switch self {
            case .categoryRequired:
                return "Feature category is required"
            case .invalidCategory(let value):
                return "Feature category must be one of: \(FeatureCategory.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(value)')"
            case .nameRequired:
                return "Feature name is required"
            case .blankName:
                return "Feature name must not contain blank texts"
            case .blankDescription:
                return "Feature description must not contain blank texts"
            }
        }
    }

    /// Invariants: every localized text is non-blank (`LocalizedString` already
    /// guarantees at least one entry). Node had no validation (bug 12).
    static func validate(name: LocalizedString, description: LocalizedString?) throws {
        guard name.values.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw Error.blankName
        }
        if let description,
           !description.values.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw Error.blankDescription
        }
    }

    /// Parses raw request values (all optional so that a missing field is a
    /// domain `ValidationError` → 422, not a 400 decoding failure).
    static func parse(
        category: String?,
        name: [String: String]?,
        description: [String: String]?
    ) throws -> (category: FeatureCategory?, name: LocalizedString?, description: LocalizedString?) {
        let parsedCategory: FeatureCategory?
        if let category {
            guard let value = FeatureCategory(rawValue: category) else {
                throw Error.invalidCategory(category)
            }
            parsedCategory = value
        } else {
            parsedCategory = nil
        }
        return (
            parsedCategory,
            try name.map { try LocalizedString($0) },
            try description.map { try LocalizedString($0) }
        )
    }
}

enum FeatureCategory: String, Codable, Sendable, CaseIterable {
    case ai
    case technicalSupport
}
