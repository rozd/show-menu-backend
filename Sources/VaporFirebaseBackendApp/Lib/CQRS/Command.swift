//
//  Command.swift
//  DualPricing
//
//  Created by Max Rozdobudko on 10/19/25.
//

import Foundation

protocol Command: Sendable {
    associatedtype Payload: Codable, Sendable

    var id: UUID { get }
    var metadata: CommandMetadata { get }
    var payload: Payload { get }
}

extension Command {
    var id: UUID { UUID() }
}

struct CommandMetadata: Codable, Sendable {
    let correlationId: TraceID
    let userId: String?
    let timestamp: Date

    init(correlationId: TraceID, userId: String?, timestamp: Date) {
        self.correlationId = correlationId
        self.userId = userId
        self.timestamp = timestamp
    }

    init(correlationId: TraceID, userId: String? = nil) {
        self.correlationId = correlationId
        self.userId = userId
        self.timestamp = .now
    }
}
