//
//  Passage+Vapor.swift
//  ShowMenuBackend
//
//  Wires Passage (authentication) over the app's shared `users` table in overlay mode.
//

import Crypto
import Fluent
import Passage
import PassageFluent
import Vapor

/// Configures Passage — the template's authentication layer, in overlay mode over
/// the app's shared `users` table.
///
/// **Architecture**: Passage and IAM are two Fluent lenses over a single `users` table
/// (overlay mode S1). Passage owns **authentication** — credentials, tokens, the
/// `/auth/*` routes — while the IAM module is the system of record for the business-side
/// `User` aggregate and every authorization decision. The two meet at exactly two seams:
/// `IAMProvisioningHooks` (Passage account lifecycle → IAM integration events) and
/// `ContractPrincipalMiddleware` (Passage bearer token → `RequestContext.principal`, via `PassagePrincipalResolver`).
///
/// **Removing authentication** is a code change, not a switch — a project built from
/// this template that does not need it deletes the Passage pieces:
/// 1. the `configurePassage` call in `configure.swift`;
/// 2. the middleware group in `routes.swift` (register the `/v1` collections on `app`
///    directly, and remove `import Passage`);
/// 3. this file, `Integration/Passage/`, `Modules/IAM/IAM+Passage.swift`;
/// 4. the `passage`, `passage-fluent` dependencies in `Package.swift`;
/// 5. `PassageAuthFlowTests` and `IAMProvisioningHooksTests`;
/// 6. the `AddUserAuthColumns` migration (or drop the columns `password_hash`, `phone`,
///    `username`, `phone_verified` by hand).
///
/// `RequestContext.principal` is then never populated and the PEPs fail closed, so wire
/// an alternative principal middleware before exercising protected flows.
///
/// **Store binding**: Overlay mode S1 injects `PassageUserRecord` (a Fluent model
/// conforming to `PassageUserModel`) into `PassageFluent.DatabaseStore`. Passage
/// migrations are **manually registered** — `registerMigrations: false` skips
/// Passage's default automatic registration, and we register its dependent tables
/// + the auth columns migration explicitly, all onto `DatabaseID.app`.
///
/// **Database:** Everything is on `DatabaseID.app` (the app's own database). Overlay
/// FKs require Passage's dependent tables to reference the same database as the users
/// table, so the old `passageDatabase` dependency is never restored.
///
/// Called from `configure(_:)` after `configureFluentStore` (which creates the `users`
/// table) and `configureIntegrationEvents`, and before `routes(_:)` (whose middleware
/// group assumes Passage is configured).
///
/// Environment:
///
/// | Variable | Meaning |
/// |---|---|
/// | `APP_ORIGIN` | Public origin used in Passage links; defaults to `http://localhost:<port>` |
/// | `JWKS` | Inline JWKS JSON with the token-signing key |
/// | `JWKS_FILE_PATH` | Path to a JWKS file; used when `JWKS` is unset |
///
/// With neither `JWKS` nor `JWKS_FILE_PATH` set, an **ephemeral** ES256 dev key is
/// generated at boot — every issued access token becomes invalid on restart, which is
/// fine for local development and wrong for anything else.
func configurePassage(_ app: Application) async throws {
    // S1 overlay: inject PassageUserRecord and skip automatic migration registration
    // so we can manually register all migrations to `.app` (the shared database).
    let store = DatabaseStore(
        app: app,
        db: app.deps.appDatabase,
        userModelType: PassageUserRecord.self,
        registerMigrations: false
    )

    // Register the auth columns migration (owned by Passage semantically, but a code-level
    // responsibility of this file to manage).
    app.migrations.add(AddUserAuthColumns(), to: .app)

    // Register all dependent migrations from PassageFluent.
    for migration in DatabaseStore.migrations(for: PassageUserRecord.self) {
        app.migrations.add(migration, to: .app)
    }

    try await app.passage.configure(
        services: .init(
            store: store,
            emailDelivery: nil,
            phoneDelivery: nil
        ),
        configuration: .init(
            origin: appOrigin(app),
            routes: .init(group: "auth"),
            tokens: .init(issuer: "show-menu-backend"),
            jwt: passageJWT(app)
        ),
        hooks: .init(
            account: IAMProvisioningHooks(channel: app.deps.integrationEventChannel)
        )
    )

    // Apply pending migrations if auto-migration is enabled. `autoMigrate()` is
    // application-wide — it prepares every registered database, the app's store
    // included — so it honours the same `DATABASE_AUTO_MIGRATE` contract as
    // `configureFluentStore`. Setting that to `false` means "I run `swift run Run
    // migrate` myself", and that command covers both Passage and app migrations;
    // without this guard, this call would quietly undo the operator's choice.
    if autoMigrateEnabled() {
        try await app.autoMigrate()
    }
}

// MARK: - Errors

/// Passage wiring problems, all fatal at startup — never at the first request.
enum PassageConfigurationError: Error, CustomStringConvertible {

    /// `APP_ORIGIN` was set but is not a parseable URL.
    case invalidOrigin(String)

    var description: String {
        switch self {
        case let .invalidOrigin(value):
            #"APP_ORIGIN "\#(value)" is not a valid URL."#
        }
    }
}

// MARK: - Origin

private func appOrigin(_ app: Application) throws -> URL {
    if let raw = Environment.get("APP_ORIGIN"), !raw.isEmpty {
        guard let url = URL(string: raw) else {
            throw PassageConfigurationError.invalidOrigin(raw)
        }
        return url
    }
    return URL(string: "http://localhost:\(app.http.server.configuration.port)")!
}

// MARK: - Token-Signing Keys

private func passageJWT(_ app: Application) throws -> Passage.Configuration.JWT {
    if Environment.get("JWKS")?.isEmpty == false {
        return .init(jwks: try .environment())
    }
    if Environment.get("JWKS_FILE_PATH")?.isEmpty == false {
        return .init(jwks: try .fileFromEnvironment())
    }
    app.logger.warning("Auth: no JWKS or JWKS_FILE_PATH set — using an ephemeral dev signing key; all access tokens become invalid on restart")
    return .init(jwks: .init(json: ephemeralJWKS()))
}

/// A freshly generated ES256 signing key as single-key JWKS JSON, so the
/// zero-configuration boot extends to authentication. Dev-only by construction:
/// the private key lives in process memory and is never persisted.
private func ephemeralJWKS() -> String {
    let key = P256.Signing.PrivateKey()
    // x963 representation is 0x04 || X || Y, 32 bytes each coordinate.
    let publicKey = key.publicKey.x963Representation
    let x = publicKey.dropFirst().prefix(32)
    let y = publicKey.suffix(32)
    return """
    {"keys":[{"kty":"EC","crv":"P-256","use":"sig","alg":"ES256","kid":"dev-ephemeral",\
    "x":"\(base64URL(x))","y":"\(base64URL(y))","d":"\(base64URL(key.rawRepresentation))"}]}
    """
}

private func base64URL(_ bytes: some Sequence<UInt8>) -> String {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
