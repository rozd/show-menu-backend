import Foundation
import Logging
import NIOCore
import NIOPosix
import Fluent
import FluentPostgresDriver
@testable import ShowMenuBackend

/// A minimal Postgres-shaped dialect, so the SQL the adapter emits serializes the
/// way it would against the real driver (`"` identifiers, `$N` placeholders,
/// `RETURNING` and standard upsert support).
struct StubSQLDialect: SQLDialect {
    var name: String { "stub-postgres" }
    var identifierQuote: any SQLExpression { SQLRaw("\"") }
    var literalStringQuote: any SQLExpression { SQLRaw("'") }

    func bindPlaceholder(at position: Int) -> any SQLExpression {
        SQLRaw("$\(position)")
    }

    var supportsReturning: Bool { true }
    var upsertSyntax: SQLUpsertSyntax { .standard }
    var enumSyntax: SQLEnumSyntax { .typeName }
    var supportsIfExists: Bool { true }
    var supportsAutoIncrement: Bool { true }
    var autoIncrementClause: any SQLExpression { SQLRaw("SERIAL") }
    var supportsDropBehavior: Bool { true }

    func literalBoolean(_ value: Bool) -> any SQLExpression {
        SQLRaw(value ? "TRUE" : "FALSE")
    }
}

/// A fake database that records the SQL it is asked to run and replays scripted
/// rows back, so the Fluent adapter can be driven **without a Postgres server**.
///
/// It conforms to *both* `SQLDatabase` (the layer the generic data sources bind
/// to) and Fluent's `Database` (what `FluentTransaction` carries) — that pairing
/// is what makes an end-to-end `FluentUserDataSource` test possible at all.
///
/// Scripting is per call: `enqueue(rows:)` adds one *response*, and each `execute`
/// pops the next one. That ordering is what lets a check-and-set test say "the
/// conditional UPDATE matched nothing, and the follow-up read then found version
/// 7" — the two statements need different answers.
final class StubSQLDatabase: SQLDatabase, @unchecked Sendable {

    private let lock = NSLock()
    private var _executed: [Statement] = []
    private var responses: [[StubSQLRow]] = []

    /// One recorded statement: the serialized SQL plus its bound values.
    struct Statement: Sendable {
        let sql: String
        let binds: [String]
    }

    /// Every statement executed, in order.
    var executed: [Statement] {
        lock.withLock { _executed }
    }

    /// The SQL of every statement executed, in order.
    var sql: [String] {
        executed.map(\.sql)
    }

    // MARK: - SQLDatabase

    let logger: Logger
    let eventLoop: any EventLoop
    let version: (any SQLDatabaseReportedVersion)? = nil
    let dialect: any SQLDialect = StubSQLDialect()
    var queryLogLevel: Logger.Level? { .debug }

    init(logger: Logger = Logger(label: "test.stub-sql")) {
        self.logger = logger
        self.eventLoop = MultiThreadedEventLoopGroup.singleton.any()
    }

    func execute(
        sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> ()
    ) -> EventLoopFuture<Void> {
        var serializer = SQLSerializer(database: self)
        query.serialize(to: &serializer)

        let rows: [StubSQLRow] = lock.withLock {
            _executed.append(
                Statement(sql: serializer.sql, binds: serializer.binds.map { String(describing: $0) })
            )
            return responses.isEmpty ? [] : responses.removeFirst()
        }
        rows.forEach(onRow)

        return eventLoop.makeSucceededFuture(())
    }

    // MARK: - Scripting

    /// Queue the rows the *next* unscripted `execute` should return. Calls with no
    /// queued response return no rows.
    func enqueue(rows: [StubSQLRow]) {
        lock.withLock { responses.append(rows) }
    }

    /// Queue an empty response — e.g. a check-and-set whose predicate matched nothing.
    func enqueueNoRows() {
        enqueue(rows: [])
    }

    func reset() {
        lock.withLock {
            _executed.removeAll()
            responses.removeAll()
        }
    }

    /// Serializes an expression the way this database would, for asserting on the
    /// output of the pure translation helpers.
    func serialize(_ expression: any SQLExpression) -> Statement {
        var serializer = SQLSerializer(database: self)
        expression.serialize(to: &serializer)
        return Statement(sql: serializer.sql, binds: serializer.binds.map { String(describing: $0) })
    }
}

// MARK: - Fluent Database conformance

/// Never used: the stub is only ever asked for SQL. `makeDriver` exists to satisfy
/// `DatabaseContext`, which every Fluent `Database` must carry.
struct StubDatabaseConfiguration: DatabaseConfiguration {
    var middleware: [any AnyModelMiddleware] = []

    func makeDriver(for databases: Databases) -> any DatabaseDriver {
        fatalError("StubSQLDatabase does not create drivers")
    }
}

extension StubSQLDatabase: Fluent.Database {

    var context: DatabaseContext {
        DatabaseContext(
            configuration: StubDatabaseConfiguration(),
            logger: logger,
            eventLoop: eventLoop
        )
    }

    /// The ORM query path is not exercised by these tests — the module data sources
    /// bind at the SQL layer. Reaching this is a test bug, not a store condition.
    func execute(
        query: DatabaseQuery,
        onOutput: @escaping @Sendable (any DatabaseOutput) -> ()
    ) -> EventLoopFuture<Void> {
        eventLoop.makeFailedFuture(StubDatabaseError.ormPathNotStubbed(String(describing: query)))
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        eventLoop.makeFailedFuture(StubDatabaseError.ormPathNotStubbed(String(describing: schema)))
    }

    func execute(enum e: DatabaseEnum) -> EventLoopFuture<Void> {
        eventLoop.makeFailedFuture(StubDatabaseError.ormPathNotStubbed(String(describing: e)))
    }

    var inTransaction: Bool { false }

    func transaction<T>(
        _ closure: @escaping @Sendable (any Fluent.Database) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        closure(self)
    }

    func withConnection<T>(
        _ closure: @escaping @Sendable (any Fluent.Database) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        closure(self)
    }
}

// MARK: - Row

/// A dictionary-backed `SQLRow`. Values are stored as their Swift types and handed
/// back by cast, which is enough for the model shapes this template stores.
struct StubSQLRow: SQLRow {
    private let values: [String: (any Sendable)?]

    init(_ values: [String: (any Sendable)?] = [:]) {
        self.values = values
    }

    var allColumns: [String] { Array(values.keys) }

    func contains(column: String) -> Bool {
        values.keys.contains(column)
    }

    func decodeNil(column: String) throws -> Bool {
        guard let value = values[column] else { return true }
        return value == nil
    }

    func decode<T: Decodable>(column: String, as type: T.Type) throws -> T {
        guard let stored = values[column] else {
            throw StubDatabaseError.columnNotFound(column)
        }

        // An absent value satisfies an optional column and nothing else.
        guard let value = stored else {
            guard let optional = (T.self as? any ExpressibleByNilLiteral.Type) else {
                throw StubDatabaseError.decodingFailed(column: column, type: "\(T.self)")
            }
            return optional.init(nilLiteral: ()) as! T
        }

        if let typed = value as? T {
            return typed
        }
        // A non-optional value satisfying an optional column (`Int` → `Int?`).
        if let wrapped = wrapInOptional(value, as: T.self) {
            return wrapped
        }
        throw StubDatabaseError.decodingFailed(column: column, type: "\(T.self)")
    }

    private func wrapInOptional<T>(_ value: any Sendable, as type: T.Type) -> T? {
        switch T.self {
        case is String?.Type: return (value as? String).map { $0 as Any } as? T
        case is Int?.Type: return (value as? Int).map { $0 as Any } as? T
        case is Bool?.Type: return (value as? Bool).map { $0 as Any } as? T
        case is Date?.Type: return (value as? Date).map { $0 as Any } as? T
        case is Data?.Type: return (value as? Data).map { $0 as Any } as? T
        case is UUID?.Type: return (value as? UUID).map { $0 as Any } as? T
        default: return nil
        }
    }
}

/// Failures raised by the stub itself — always a test bug, never a store condition.
enum StubDatabaseError: Error, CustomStringConvertible {
    case columnNotFound(String)
    case decodingFailed(column: String, type: String)
    case ormPathNotStubbed(String)

    var description: String {
        switch self {
        case let .columnNotFound(column):
            return "Column not found in stub row: \(column)"
        case let .decodingFailed(column, type):
            return "Failed to decode column '\(column)' as \(type)"
        case let .ormPathNotStubbed(detail):
            return "StubSQLDatabase was asked to run a Fluent ORM query, which these tests do not stub: \(detail)"
        }
    }
}
