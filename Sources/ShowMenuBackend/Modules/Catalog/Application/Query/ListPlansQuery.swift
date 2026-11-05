import Foundation

/// Admin list of every plan. No filters or paging: the catalog is small and
/// Flutter streams the whole collection too.
struct ListPlansQuery: Query {
}
