/// Describes a data query with filters, ordering, and optional limit/offset.
/// Storage-agnostic — no dependency on Firestore or any backend.
struct DataSourceQuery: Sendable {
    var filters: [DataSourceFilter]
    var orders: [DataSourceOrder]
    var limit: Int?
    /// Skip this many results after ordering. Firestore bills skipped documents
    /// as reads, so prefer cursor pagination for deep paging.
    var offset: Int?

    init(
        filters: [DataSourceFilter] = [],
        orders: [DataSourceOrder] = [],
        limit: Int? = nil,
        offset: Int? = nil
    ) {
        self.filters = filters
        self.orders = orders
        self.limit = limit
        self.offset = offset
    }
}
