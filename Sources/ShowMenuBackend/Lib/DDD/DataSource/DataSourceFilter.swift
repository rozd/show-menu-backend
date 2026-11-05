/// A single filter condition on a document field.
struct DataSourceFilter: Sendable {
    enum Operator: Sendable {
        case equal
        case notEqual
        case lessThan
        case lessThanOrEqual
        case greaterThan
        case greaterThanOrEqual
        case `in`
        case notIn
        case arrayContains
        case arrayContainsAny
    }

    let field: String
    let op: Operator
    let value: any Sendable & Encodable
}
