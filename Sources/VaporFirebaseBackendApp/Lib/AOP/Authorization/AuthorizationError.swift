//
//  AuthorizationError.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 6/14/26.
//

/// Error thrown by a Policy Enforcement Point when authorization fails.
///
/// `denied` carries the `reason` from the failing ``Decision``; `missingPrincipal`
/// is raised when no ``Principal`` is available to authorize against (fail-closed).
enum AuthorizationError: Error, Equatable {
    case denied(reason: String)
    case missingPrincipal
}
