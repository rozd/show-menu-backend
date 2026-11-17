/// Describes a data query with filters, ordering, and optional limit.
/// Storage-agnostic — no dependency on any particular persistence backend.
struct DataSourceQuery: Sendable {
    var filters: [DataSourceFilter]
    var orders: [DataSourceOrder]
    var limit: Int?

    init(
        filters: [DataSourceFilter] = [],
        orders: [DataSourceOrder] = [],
        limit: Int? = nil
    ) {
        self.filters = filters
        self.orders = orders
        self.limit = limit
    }
}
