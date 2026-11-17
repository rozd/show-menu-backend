//
//  FluentStoreError.swift
//  ShowMenuBackend
//
//  Store-level failures of the Fluent adapter.
//

/// Failures raised by the Fluent adapter itself.
///
/// Deliberately *not* used for optimistic-concurrency conflicts: those surface as
/// `ConcurrencyError.versionConflict` so the edge maps them to `409`/`412` exactly
/// (see ``FluentDataSource``).
enum FluentStoreError: Error, Sendable, CustomStringConvertible {

    /// The configured Fluent driver is not SQL-backed, so the generic data sources
    /// (which bind at the SQL layer) cannot run against it.
    case notSQLDatabase(driver: String)

    /// A unique/primary-key constraint rejected an insert.
    case alreadyExists(table: String, id: String)

    /// A check-and-set targeted a row that is not there.
    case notFound(table: String, id: String)

    /// A row could not be decoded into the requested model — a schema/migration
    /// mismatch — a row whose shape no longer matches its store model.
    case decodingFailed(table: String, id: String?, underlying: any Error)

    /// A stored concurrency token is not the integer counter this binding expects
    /// (see ``VersionedModel``) — corrupt data or a token minted by another store.
    case malformedVersion(table: String, id: String, token: String)

    var description: String {
        switch self {
        case let .notSQLDatabase(driver):
            return "Fluent driver \(driver) is not an SQLDatabase; the Fluent data sources require a SQL store"
        case let .alreadyExists(table, id):
            return "Row already exists: \(table)/\(id)"
        case let .notFound(table, id):
            return "Row not found: \(table)/\(id)"
        case let .decodingFailed(table, id, underlying):
            return "Failed to decode row \(table)/\(id ?? "<unknown>"): \(underlying)"
        case let .malformedVersion(table, id, token):
            return "Row \(table)/\(id) carries a non-integer version token: \(token)"
        }
    }
}

/// A query the Fluent adapter cannot honour.
///
/// Raised instead of quietly degrading, for the same reason
/// exists for one reason: a filter that is silently dropped returns
/// *unfiltered* rows, which looks like a working read while leaking data the
/// caller never asked for.
enum FluentQueryError: Error, Sendable, CustomStringConvertible {

    /// An operator that takes a list (`in`, `notIn`) was given a scalar.
    case listOperandExpected(field: String, op: String)

    /// An element of a list operand is not encodable as a bound parameter.
    case unbindableOperand(field: String, type: String)

    /// A dotted path (`owner.id`) addresses a field *inside* a document; a
    /// relational column holds a scalar.
    case nestedField(field: String)

    var description: String {
        switch self {
        case let .listOperandExpected(field, op):
            return "Filter `\(field) \(op)` requires an array operand"
        case let .unbindableOperand(field, type):
            return "Filter operand for `\(field)` has type \(type), which cannot be bound as a SQL parameter"
        case let .nestedField(field):
            return """
                Field path `\(field)` is nested, which the Fluent adapter cannot address: a relational column \
                holds a scalar. Flatten the field into its own column, or model it as a related table.
                """
        }
    }
}
