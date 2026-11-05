//
//  DDD+Vapor.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 10/18/25.
//

import Vapor

extension CommandMetadata {

    init(req: Request) {
        self.init(
            correlationId: TraceID(stringLiteral: req.id),
            userId: nil,
            timestamp: .now
        )
    }

}

extension CommandMetadata: Content {
    
}
