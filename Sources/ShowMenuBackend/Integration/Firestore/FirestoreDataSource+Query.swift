import FirestoreAPI
import Foundation

/// Default query implementation for all FirestoreDataSource conformers
/// that also conform to QueryableDataSource.
///
/// Translates DataSourceQuery → FirebaseAPI Query → gRPC execution.
extension FirestoreDataSource where Self: QueryableDataSource {

    func query(_ query: DataSourceQuery) async throws -> QueryResult<Model> {
        logger.debug("Querying collection", metadata: [
            "collection": .string(collectionPath),
            "filterCount": .string(String(query.filters.count))
        ])
        do {
            let collection = transaction.collection(collectionPath)
            var firestoreQuery: FirestoreAPI.Query?

            // Apply filters
            for filter in query.filters {
                if let q = firestoreQuery {
                    firestoreQuery = applyFilter(filter, toQuery: q)
                } else {
                    firestoreQuery = applyFilter(filter, toCollection: collection)
                }
            }

            // Apply ordering
            for order in query.orders {
                let descending = order.direction == .descending
                if let q = firestoreQuery {
                    firestoreQuery = q.order(by: order.field, descending: descending)
                } else {
                    firestoreQuery = collection.order(by: order.field, descending: descending)
                }
            }

            // Apply limit
            if let limit = query.limit {
                if let q = firestoreQuery {
                    firestoreQuery = q.limit(to: limit)
                } else {
                    firestoreQuery = collection.limit(to: limit)
                }
            }

            // Apply offset (after limit, mirroring the limit block). A bare
            // collection has no `offset`, so start from an empty-predicate Query.
            if let offset = query.offset {
                firestoreQuery = (firestoreQuery ?? collection.and([])).offset(offset)
            }

            // Execute and decode
            let items: [Model]
            if let firestoreQuery {
                items = try await transaction.getDocuments(Model.self, query: firestoreQuery)
            } else {
                items = try await transaction.getDocuments(Model.self, collection: collection)
            }
            return QueryResult(items: items)
        } catch let error as FirestoreError {
            throw error
        } catch {
            let mapped = FirestoreError.from(grpcError: error)
            logger.error("Firestore query failed", metadata: [
                "collection": .string(collectionPath),
                "errorType": .string(String(reflecting: type(of: error))),
                "errorDetail": .string(String(reflecting: error)),
                "errorDescription": .string(error.localizedDescription),
                "mappedError": .string(String(describing: mapped)),
                "mappedDescription": .string(mapped.errorDescription ?? "")
            ])
            throw mapped
        }
    }

    func countAll() async throws -> Int {
        logger.debug("Counting collection", metadata: [
            "collection": .string(collectionPath)
        ])
        do {
            return try await transaction.count(transaction.collection(collectionPath))
        } catch let error as FirestoreError {
            throw error
        } catch {
            let mapped = FirestoreError.from(grpcError: error)
            logger.error("Firestore count failed", metadata: [
                "collection": .string(collectionPath),
                "errorType": .string(String(reflecting: type(of: error))),
                "errorDetail": .string(String(reflecting: error)),
                "mappedError": .string(String(describing: mapped)),
                "mappedDescription": .string(mapped.errorDescription ?? "")
            ])
            throw mapped
        }
    }

    // MARK: - Private Helpers

    private func applyFilter(
        _ filter: DataSourceFilter,
        toQuery query: FirestoreAPI.Query
    ) -> FirestoreAPI.Query {
        let value = convertToAny(filter.value)
        switch filter.op {
        case .equal:
            return query.`where`(field: filter.field, isEqualTo: value)
        case .notEqual:
            return query.`where`(field: filter.field, isNotEqualTo: value)
        case .lessThan:
            return query.`where`(field: filter.field, isLessThan: value)
        case .lessThanOrEqual:
            return query.`where`(field: filter.field, isLessThanOrEqualTo: value)
        case .greaterThan:
            return query.`where`(field: filter.field, isGreaterThan: value)
        case .greaterThanOrEqual:
            return query.`where`(field: filter.field, isGreaterThanOrEqualTo: value)
        case .in:
            return query.`where`(field: filter.field, in: value as? [Any] ?? [value])
        case .notIn:
            return query.`where`(field: filter.field, notIn: value as? [Any] ?? [value])
        case .arrayContains:
            return query.`where`(field: filter.field, arrayContains: value)
        case .arrayContainsAny:
            return query.`where`(field: filter.field, arrayContainsAny: value as? [Any] ?? [value])
        }
    }

    private func applyFilter(
        _ filter: DataSourceFilter,
        toCollection collection: FirestoreAPI.CollectionReference
    ) -> FirestoreAPI.Query {
        let value = convertToAny(filter.value)
        switch filter.op {
        case .equal:
            return collection.`where`(field: filter.field, isEqualTo: value)
        case .notEqual:
            return collection.`where`(field: filter.field, isNotEqualTo: value)
        case .lessThan:
            return collection.`where`(field: filter.field, isLessThan: value)
        case .lessThanOrEqual:
            return collection.`where`(field: filter.field, isLessThanOrEqualTo: value)
        case .greaterThan:
            return collection.`where`(field: filter.field, isGreaterThan: value)
        case .greaterThanOrEqual:
            return collection.`where`(field: filter.field, isGreaterThanOrEqualTo: value)
        case .in:
            return collection.`where`(field: filter.field, in: value as? [Any] ?? [value])
        case .notIn:
            return collection.`where`(field: filter.field, notIn: value as? [Any] ?? [value])
        case .arrayContains:
            return collection.`where`(field: filter.field, arrayContains: value)
        case .arrayContainsAny:
            return collection.`where`(field: filter.field, arrayContainsAny: value as? [Any] ?? [value])
        }
    }

    private func convertToAny(_ value: any Sendable & Encodable) -> Any {
        switch value {
        case let v as String: return v
        case let v as Int: return v
        case let v as Double: return v
        case let v as Bool: return v
        case let v as Date: return v
        case let v as [any Sendable & Encodable]:
            return v.map { convertToAny($0) }
        default:
            // JSON round-trip fallback for other Encodable types
            guard let data = try? JSONEncoder().encode(value),
                  let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
                return "\(value)"
            }
            return jsonObject
        }
    }
}
