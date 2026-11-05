//
//  DDD+Vapor.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 10/18/25.
//

import Vapor

extension CommandMetadata {

    init(req: Request) {
        self.init(
            correlationId: TraceID(stringLiteral: req.id),
            // Bound by `FirebaseAuthMiddleware`; nil on public routes.
            userId: RequestContext.principal?.id,
            timestamp: .now
        )
    }

}

extension CommandMetadata: Content {
    
}
