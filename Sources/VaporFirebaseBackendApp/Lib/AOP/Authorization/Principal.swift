//
//  Principal.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 6/14/26.
//

/// The actor an authorization decision is made *about*.
///
/// `Principal` is the minimal security-identity abstraction the authorization
/// layer needs: a stable `id` and the `roles` the actor holds. Security identity
/// lives here (and in the Application layer) — never in the domain model.
///
/// The presence of a `Principal` is what distinguishes an ``Ability`` (principal-aware
/// authorization) from a business `Policy` (actor-free domain logic).
protocol Principal: Sendable {
    var id: String { get }
    var roles: Set<Role> { get }
}

/// A coarse-grained authorization role held by a ``Principal``.
///
/// `Lib` defines only the *type*; concrete role values (e.g. `.admin`) are declared
/// by the modules that use them, keeping business semantics out of `Lib`.
struct Role: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}
