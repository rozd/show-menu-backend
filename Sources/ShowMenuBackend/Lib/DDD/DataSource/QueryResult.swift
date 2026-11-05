/// Generic result container for query results.
struct QueryResult<Model: Sendable>: Sendable {
    let items: [Model]
}
