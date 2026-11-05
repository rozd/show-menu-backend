import Foundation
@testable import VaporFirebaseBackendApp

/// A minimal `Principal` test double used by authorization unit tests.
struct StubPrincipal: Principal {
    let id: String
    let roles: Set<Role>

    init(id: String = "stub", roles: Set<Role> = []) {
        self.id = id
        self.roles = roles
    }
}
