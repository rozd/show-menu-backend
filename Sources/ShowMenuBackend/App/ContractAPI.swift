import OpenAPIRuntime
import OpenAPIVapor
import ShowMenuContracts
import Vapor

/// The server-side realization of the wire contract: the one type that conforms to the
/// generated `APIProtocol`, and the only way an HTTP route exists in this backend (Passage's
/// own `/auth/*` and `/me` routes aside, see `docs/conventions/WireContract.md`).
///
/// `openapi.yaml` (the `show-menu-contracts` package) generates a *single* `APIProtocol`
/// listing every operation and a *single* `registerHandlers`, so one conformer implements the
/// whole document. Operations that have no implementation yet live in
/// `ContractAPI+NotImplemented.swift` and answer `501 not_implemented`; implement one by moving
/// it into its own `ContractAPI+<Module>.swift`, forwarding to a plain controller, and adding it
/// to ``ContractAccessMiddleware/table``.
///
/// No route is registered by hand: a route that is not an operation in the spec does not
/// exist (unknown paths are a plain 404).
struct ContractAPI: APIProtocol {

    /// Each operation resolves what it needs from `app.deps`.
    let app: Application
}

extension Application {

    /// Registers every operation in the wire contract onto `self`, under `/api`.
    ///
    /// `registerHandlers` derives each route's method and path from `openapi.yaml` (paths are
    /// `/v1/...`; the `/api` prefix is the transport group).
    ///
    /// The route group carries two Vapor middlewares that run before the generated route:
    /// ``OptionalPassageBearerAuthenticator`` (validates a bearer token if one is sent, never
    /// rejects) and ``ContractPrincipalMiddleware`` (binds `RequestContext.principal`). They are
    /// Vapor middlewares because the OpenAPI `ServerMiddleware` below only sees
    /// `HTTPTypes.HTTPRequest`, not the Vapor `Request` Passage authenticates on.
    ///
    /// OpenAPI middlewares, outermost first:
    /// 1. ``IgnoreAcceptHeaderMiddleware``: `Accept` is not negotiated (the generated 406
    ///    fires after the handler ran, i.e. after side effects).
    /// 2. ``EmptyRequestBodyMiddleware``: a zero-length body is "no body" (optional bodies).
    /// 3. ``ContractAccessMiddleware``: per-operation access (public / authenticated / admin),
    ///    failing closed for an unlisted operation.
    ///
    /// Dates travel as ISO-8601 with milliseconds; JSON is compact with sorted keys.
    ///
    /// - Parameter accessTable: the operationID → access table; tests inject their own.
    func registerContractHandlers(accessTable: [String: Access] = ContractAccessMiddleware.table) throws {
        try ContractAPI(app: self).registerHandlers(
            on: VaporTransport(
                routesBuilder: grouped("api").grouped(
                    OptionalPassageBearerAuthenticator(),
                    ContractPrincipalMiddleware()
                )
            ),
            configuration: .init(
                dateTranscoder: .iso8601WithFractionalSeconds,
                jsonEncodingOptions: [.sortedKeys]
            ),
            middlewares: [
                IgnoreAcceptHeaderMiddleware(),
                EmptyRequestBodyMiddleware(),
                ContractAccessMiddleware(table: accessTable),
            ]
        )
    }
}
