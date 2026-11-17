/// Data sources that support querying opt in by conforming to this protocol.
/// Refines DataSource with a query method.
protocol QueryableDataSource<Model>: DataSource {
    func query(_ query: DataSourceQuery) async throws -> QueryResult<Model>
}
