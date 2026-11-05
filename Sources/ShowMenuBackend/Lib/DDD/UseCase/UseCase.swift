//
//  UseCase.swift
//  DualPricing
//
//  Created by Max Rozdobudko on 9/13/25.
//

protocol UseCase: Sendable {
    associatedtype Params: Sendable
    associatedtype Result: Sendable

    func execute(params: Params) async throws -> Result
}
