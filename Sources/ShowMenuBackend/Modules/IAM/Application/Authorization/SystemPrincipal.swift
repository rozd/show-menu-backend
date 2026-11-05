//
//  SystemPrincipal.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 6/14/26.
//

/// The trusted internal actor for system-initiated work that originates outside
/// any end-user request — e.g. reconciling the local `User` record in response to
/// a Firebase Auth deletion webhook.
///
/// It holds the administrator role so such flows pass *through* the normal
/// authorization rules rather than bypassing them. In a multi-module system this
/// would live in a shared identity area; it sits in IAM here because IAM is the
/// only module wiring authorization in this template.
struct SystemPrincipal: Principal {
    let id: String
    let roles: Set<Role>

    init(id: String = "system") {
        self.id = id
        self.roles = [.admin]
    }
}
