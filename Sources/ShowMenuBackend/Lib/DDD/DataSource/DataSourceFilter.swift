/// A single filter condition on a store field.
struct DataSourceFilter: Sendable {

    /// The comparisons the store-agnostic query language offers.
    ///
    /// Deliberately narrow: the DSL carries only what *every* binding can push
    /// down into the store, so a filter never silently degrades into an
    /// unfiltered read. Anything richer — array membership, joins, aggregates,
    /// full-text search — belongs in a hand-written SQL read on the module's own
    /// data source, where the dialect is visible and testable (see
    /// `Integration/Fluent/README.md`).
    enum Operator: Sendable {
        case equal
        case notEqual
        case lessThan
        case lessThanOrEqual
        case greaterThan
        case greaterThanOrEqual
        case `in`
        case notIn
    }

    let field: String
    let op: Operator
    let value: any Sendable & Encodable
}
