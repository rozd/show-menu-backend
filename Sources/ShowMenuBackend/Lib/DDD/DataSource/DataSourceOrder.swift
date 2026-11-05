/// Sort criterion for query results.
struct DataSourceOrder: Sendable {
    enum Direction: Sendable {
        case ascending
        case descending
    }

    let field: String
    let direction: Direction
}
