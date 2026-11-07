//
//  DDD+Vapor.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 10/18/25.
//

import Vapor

extension CommandMetadata {

    /// Request-free metadata for contract controllers: the trace id bound by the trace
    /// middleware (a fresh one when unbound) and the principal bound by
    /// `ContractAccessMiddleware` (nil on public operations).
    init() {
        self.init(
            correlationId: RequestContext.traceId ?? TraceID(),
            userId: RequestContext.principal?.id,
            timestamp: .now
        )
    }

}

extension CommandMetadata: Content {
    
}
