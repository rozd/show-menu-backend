//
//  FluentDataSource+Query.swift
//  ShowMenuBackend
//
//  Translation of the store-agnostic query language into SQL.
//

import Foundation
import Logging
import FluentPostgresDriver

// MARK: - Query

/// Default ``QueryableDataSource/query(_:)`` for every Fluent data source.
///
/// The predicate is *pushed down*: filters become a `WHERE` clause, orders an
/// `ORDER BY`, and the limit a `LIMIT`, so the database does the work and only
/// matching rows cross the wire.
///
/// This covers the simple reads. Anything the DSL cannot express — search,
/// `OFFSET`, a total alongside a page, joins, aggregates — is a hand-written SQL
/// read on the module's own port, bound with a hand-written statement over
/// `transaction.sql`.
extension FluentDataSource {

    func query(_ query: DataSourceQuery) async throws -> QueryResult<Model> {
        logger.debug("Querying table", metadata: [
            "table": .string(table),
            "filterCount": .string(String(query.filters.count))
        ])

        var builder = try sql
            .select()
            .column(SQLLiteral.all)
            .from(table)

        // Filters — every one must match (AND semantics, as in DataSourceQuery).
        for filter in query.filters {
            builder = builder.where(try FluentPredicate.expression(for: filter))
        }

        for order in query.orders {
            builder = builder.orderBy(
                try FluentCoding.column(for: order.field),
                order.direction == .ascending ? SQLDirection.ascending : SQLDirection.descending
            )
        }

        if let limit = query.limit {
            builder = builder.limit(limit)
        }

        let rows = try await builder.all()
        let items = try rows.map { row in
            try FluentCoding.decode(Model.self, from: row, table: table)
        }
        return QueryResult(items: items)
    }
}

// MARK: - Predicate Translation

/// Translates a store-agnostic ``DataSourceFilter`` into a SQL predicate.
///
/// Kept as a pure function over expressions (rather than folded into the query
/// builder) so the translation is unit-testable without a live database — the
/// emitted SQL is asserted directly in the test suite.
///
/// Every ``DataSourceFilter/Operator`` translates: the DSL is deliberately kept
/// to what SQL can push down. What it cannot express — a dotted path addressing
/// a field *inside* a value — is **rejected**, never silently dropped: a dropped
/// filter returns unfiltered rows, which looks like a working read while leaking
/// data the caller never asked for.
enum FluentPredicate {

    static func expression(for filter: DataSourceFilter) throws -> any SQLExpression {
        let column = try FluentCoding.column(for: filter.field)

        switch filter.op {
        case .equal:
            return SQLBinaryExpression(column, .equal, SQLBind(filter.value))
        case .notEqual:
            return SQLBinaryExpression(column, .notEqual, SQLBind(filter.value))
        case .lessThan:
            return SQLBinaryExpression(column, .lessThan, SQLBind(filter.value))
        case .lessThanOrEqual:
            return SQLBinaryExpression(column, .lessThanOrEqual, SQLBind(filter.value))
        case .greaterThan:
            return SQLBinaryExpression(column, .greaterThan, SQLBind(filter.value))
        case .greaterThanOrEqual:
            return SQLBinaryExpression(column, .greaterThanOrEqual, SQLBind(filter.value))
        case .in:
            return SQLBinaryExpression(column, .in, try list(filter, op: "in"))
        case .notIn:
            return SQLBinaryExpression(column, .notIn, try list(filter, op: "notIn"))
        }
    }

    /// Binds a list operand as `(?, ?, …)`.
    ///
    /// `DataSourceFilter.value` is a single existential, so the array is opened
    /// reflectively — that keeps *any* element type working (the alternative, a
    /// ladder of `as? [String]` / `as? [Int]` casts, silently fails to match the
    /// element type nobody thought of).
    private static func list(_ filter: DataSourceFilter, op: String) throws -> any SQLExpression {
        let mirror = Mirror(reflecting: filter.value)
        guard mirror.displayStyle == .collection else {
            throw FluentQueryError.listOperandExpected(field: filter.field, op: op)
        }
        let elements = try mirror.children.map { child -> any Encodable & Sendable in
            guard let element = child.value as? any Encodable else {
                throw FluentQueryError.unbindableOperand(
                    field: filter.field,
                    type: String(describing: type(of: child.value))
                )
            }
            return Operand(element)
        }
        return SQLBind.group(elements)
    }

    /// Wraps an element of a list operand so it can be bound.
    ///
    /// Two reasons this box exists: `Sendable` is a marker protocol and cannot be
    /// used in a conditional cast (so reflection can only recover `any Encodable`),
    /// and `SQLBind.group` needs a concrete `Encodable & Sendable`. The unchecked
    /// conformance is sound because the element came out of a
    /// `DataSourceFilter.value`, which *is* `Sendable`, and the box only ever
    /// forwards `encode(to:)`.
    private struct Operand: Encodable, @unchecked Sendable {
        let value: any Encodable

        init(_ value: any Encodable) {
            self.value = value
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }
}
