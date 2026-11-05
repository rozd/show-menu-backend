import Foundation

/// A page of items.
///
/// Conforms to ``PagedQuery`` so the pagination travels *with* the query rather
/// than as loose handler arguments. There is no search: Firestore has no
/// substring match. `ListItemsQueryHandler` answers it through
/// `DataSourceQuery` (`createdAt` DESC + limit + offset) plus
/// `QueryableDataSource.countAll()`.
struct ListItemsQuery: PagedQuery {

    let pagination: OffsetPagination

    init(pagination: OffsetPagination = .default) {
        self.pagination = pagination
    }
}

extension OffsetPagination {

    /// The first page at the default size. Page bounds are enforced at the edge
    /// (`ItemController.listItems`), which is where a client's numbers arrive.
    static let `default` = OffsetPagination(offset: 0, limit: 20)
}
