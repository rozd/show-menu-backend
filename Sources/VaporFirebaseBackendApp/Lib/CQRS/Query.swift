//
//  Query.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 10/21/25.
//

import Foundation

protocol Query: Sendable, Codable {

}

protocol PagedQuery: Query {
    associatedtype QueryPagination: Pagination

    var pagination: QueryPagination { get }
}


// MARK: - Pagination

/// `Codable` because a ``PagedQuery`` is, and a query carries its pagination —
/// so a paged query stays serializable end to end (replay, logging, a queued
/// read).
protocol Pagination: Sendable, Codable {

}

struct CursorPagination: Pagination {
    let before: String?
    let after: String?
    let limit: Int?
}

struct OffsetPagination: Pagination {
    let offset: Int
    let limit: Int
}

struct PagePagination: Pagination {
    let page: Int
    let perPage: Int
}

struct DateRangePagination: Pagination {
    let since: Date?
    let until: Date?
    let limit: Int?
}

struct TimestampPagination: Pagination {
    let timestamp: Date
    let limit: Int?
}
