//
//  QueryHandler.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 10/22/25.
//

protocol QueryHandler: Sendable {
    associatedtype Params: Query
    associatedtype Result: Sendable

    func handle(_ query: Params) async throws -> Result
}
