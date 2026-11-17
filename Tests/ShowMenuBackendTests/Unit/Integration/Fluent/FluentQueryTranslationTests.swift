import Foundation
import Testing
import Logging
@testable import ShowMenuBackend

/// Translation of the store-agnostic query language into SQL.
///
/// Every case asserts the *emitted SQL*, not merely that translation didn't throw:
/// a predicate that compiles but addresses the wrong column, or binds the wrong
/// number of parameters, is exactly the bug this layer can have.
@Suite("Fluent Query Translation")
struct FluentQueryTranslationTests {

    private let db = StubSQLDatabase()

    private func sql(_ field: String, _ op: DataSourceFilter.Operator, _ value: any Sendable & Encodable) throws -> StubSQLDatabase.Statement {
        db.serialize(try FluentPredicate.expression(for: DataSourceFilter(field: field, op: op, value: value)))
    }

    // MARK: - Comparison operators

    @Test("comparison operators map to their SQL spelling, with one bound parameter")
    func comparisonOperators() throws {
        #expect(try sql("name", .equal, "Widget").sql == #""name" = $1"#)
        #expect(try sql("name", .notEqual, "Widget").sql == #""name" <> $1"#)
        #expect(try sql("version", .lessThan, 5).sql == #""version" < $1"#)
        #expect(try sql("version", .lessThanOrEqual, 5).sql == #""version" <= $1"#)
        #expect(try sql("version", .greaterThan, 3).sql == #""version" > $1"#)
        #expect(try sql("version", .greaterThanOrEqual, 3).sql == #""version" >= $1"#)

        #expect(try sql("name", .equal, "Widget").binds == ["Widget"])
    }

    @Test("a camelCase field addresses its snake_case column")
    func fieldNameIsConvertedToColumn() throws {
        // The filter names a *model* key; the column is what the encoder wrote.
        // Divergence here would silently filter on a column that does not exist.
        #expect(try sql("createdAt", .greaterThan, Date(timeIntervalSince1970: 0)).sql == #""created_at" > $1"#)
        #expect(try sql("displayName", .equal, "Ada").sql == #""display_name" = $1"#)
    }

    // MARK: - List operators

    @Test("in / notIn bind one parameter per element")
    func listOperators() throws {
        let inList = try sql("id", .in, ["i1", "i2", "i3"])
        #expect(inList.sql == #""id" IN ($1, $2, $3)"#)
        // One bind per element, each carrying its own value. (List elements travel
        // wrapped in the adapter's `Operand` box — it encodes transparently to the
        // element, which is why the description mentions it.)
        #expect(inList.binds.count == 3)
        #expect(inList.binds[0].contains("i1"))
        #expect(inList.binds[2].contains("i3"))

        let notInList = try sql("id", .notIn, ["i1", "i2"])
        #expect(notInList.sql == #""id" NOT IN ($1, $2)"#)
        #expect(notInList.binds.count == 2)
    }

    @Test("a list operator holds for element types beyond String")
    func listOperandOfOtherElementTypes() throws {
        // The operand is opened reflectively rather than cast against a fixed
        // ladder of array types, so an unforeseen element type still binds.
        #expect(try sql("version", .in, [1, 2, 3]).binds.count == 3)
    }

    @Test("a scalar handed to a list operator is rejected")
    func scalarListOperandThrows() {
        #expect(throws: FluentQueryError.self) { try sql("id", .in, "scalar") }
        #expect(throws: FluentQueryError.self) { try sql("id", .notIn, "scalar") }
    }

    // MARK: - Refusals

    @Test("a nested field path is refused — a column holds a scalar")
    func nestedFieldThrows() {
        #expect(throws: FluentQueryError.self) { try sql("owner.id", .equal, "u1") }
    }

    // MARK: - Whole-query assembly

    @Test("filters, orders and limit are pushed down into one SELECT")
    func queryPushesEverythingDown() async throws {
        let db = StubSQLDatabase()
        let ds = FluentUserDataSource(
            transaction: .direct(database: db),
            logger: Logger(label: "test", factory: { _ in CapturingLogHandler() })
        )
        db.enqueue(rows: [StubSQLRow([
            "id": "i1", "display_name": "Widget", "email": nil,
            "version": 1, "created_at": nil
        ])])

        let result = try await ds.query(DataSourceQuery(
            filters: [DataSourceFilter(field: "displayName", op: .equal, value: "Widget")],
            orders: [DataSourceOrder(field: "createdAt", direction: .descending)],
            limit: 10
        ))

        #expect(result.items.count == 1)
        #expect(result.items.first?.id == "i1")

        let statement = try #require(db.executed.first)
        #expect(statement.sql.contains(#"FROM "users""#))
        #expect(statement.sql.contains(#"WHERE "display_name" = $1"#))
        #expect(statement.sql.contains(#"ORDER BY "created_at" DESC"#))
        #expect(statement.sql.contains("LIMIT 10"))
    }

    @Test("a refused filter fails the query instead of returning everything")
    func refusedFilterFailsTheQuery() async throws {
        let db = StubSQLDatabase()
        let ds = FluentUserDataSource(
            transaction: .direct(database: db),
            logger: Logger(label: "test", factory: { _ in CapturingLogHandler() })
        )

        // A dropped filter returns *unfiltered* rows — a working-looking read that
        // leaks data the caller never asked for. Refusing is the whole point.
        await #expect(throws: FluentQueryError.self) {
            _ = try await ds.query(DataSourceQuery(
                filters: [DataSourceFilter(field: "owner.id", op: .equal, value: "u1")]
            ))
        }
        #expect(db.executed.isEmpty, "nothing may reach the database once a filter is refused")
    }
}
