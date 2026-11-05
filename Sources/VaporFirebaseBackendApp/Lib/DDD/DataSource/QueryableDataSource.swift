/// Data sources that support querying opt in by conforming to this protocol.
/// Refines DataSource with a query method.
protocol QueryableDataSource<Model>: DataSource {
    func query(_ query: DataSourceQuery) async throws -> QueryResult<Model>

    /// The total number of models in the data source's collection — **unfiltered**
    /// and independent of any `DataSourceQuery`. It is a separate read and is not
    /// atomic with a `query(_:)` call. Named `countAll` precisely because it
    /// takes no filters.
    func countAll() async throws -> Int
}
