//
//  Store.swift
//  ShowMenuBackend
//
//  Failures in wiring the app's persistence.
//

// MARK: - Errors

/// Store wiring problems, all fatal at startup — never at the first request.
enum StoreConfigurationError: Error, CustomStringConvertible {

    /// Postgres connection details were half-supplied.
    case missingConnectionDetails

    /// `Outbox.collection` was changed away from the table the Fluent adapter's
    /// migration creates. A Fluent model's table name is static, so the two would
    /// silently address different tables.
    case outboxTableMismatch(configured: String, required: String)

    var description: String {
        switch self {
        case .missingConnectionDetails:
            return """
                DATABASE_HOST is set but DATABASE_USERNAME is not. Supply the rest of the \
                Postgres connection details (DATABASE_PORT/DATABASE_USERNAME/DATABASE_PASSWORD/DATABASE_NAME), \
                use DATABASE_URL instead, or unset DATABASE_HOST to run on the default in-memory SQLite database.
                """
        case let .outboxTableMismatch(configured, required):
            return """
                Outbox.collection is "\(configured)" but the Fluent adapter's outbox table is "\(required)". \
                A Fluent model's table name is static — change OutboxMessageRecord.schema and its migration \
                together, or leave Outbox.collection at the default.
                """
        }
    }
}
