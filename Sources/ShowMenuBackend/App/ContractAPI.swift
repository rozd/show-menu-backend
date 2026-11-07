import OpenAPIRuntime
import OpenAPIVapor
import ShowMenuContracts
import Vapor

/// The server-side realization of the wire contract: the one type that conforms to the
/// generated `APIProtocol`, and the only way an HTTP route exists in this backend.
///
/// **Why one type and not one per module.** `openapi.yaml` (the `show-menu-contracts` package)
/// generates a *single* `APIProtocol` listing every operation, and a *single*
/// `registerHandlers` that registers all of them against one transport. A conformer must
/// therefore implement the whole document, and two conformers would each register every
/// route. The unit of conformance is the contract, not the module.
///
/// **The contract is central, the operations are local** — the same split
/// `Application.Dependencies` uses. This type is declared here once and never reopened; each
/// module satisfies its own operations from
/// `Modules/<Module>/Presentation/ContractAPI+<Module>.swift`, forwarding to that module's
/// controller. A module that never writes its file shows up as a build error naming the
/// operation the document promised and nobody implemented.
///
/// No route is registered by hand (no route collections, no inline closures): a route that is
/// not an operation in the spec does not exist (unknown paths are a plain 404).
struct ContractAPI: APIProtocol {

    /// Held rather than injecting each module's handlers here, which would make this file grow
    /// a line per module. Each operation resolves what it needs from `app.deps`.
    let app: Application
}

extension Application {

    /// Registers every operation in the wire contract onto `self`, under `/api`.
    ///
    /// `registerHandlers` derives each route's method and path from `openapi.yaml` (paths are
    /// `/v1/...`; the `/api` prefix is the transport group), so nothing here spells a
    /// contract route.
    ///
    /// Middlewares, outermost first:
    /// 1. ``IgnoreAcceptHeaderMiddleware``: `Accept` is not negotiated (the generated 406
    ///    fires after the handler ran, i.e. after side effects).
    /// 2. ``EmptyRequestBodyMiddleware``: a zero-length body is "no body" (optional bodies).
    /// 3. ``ContractAccessMiddleware``: per-operation authentication (public / Firebase
    ///    bearer / admin / scheduler / eventarc), failing closed for an unlisted operation.
    ///
    /// Dates travel as ISO-8601 with milliseconds (the JS `toISOString()` form); JSON is
    /// compact (not the runtime's pretty-printed default) like the Vapor encoder it replaces.
    func registerContractHandlers() throws {
        try ContractAPI(app: self).registerHandlers(
            on: VaporTransport(routesBuilder: grouped("api")),
            configuration: .init(
                dateTranscoder: .iso8601WithFractionalSeconds,
                jsonEncodingOptions: [.sortedKeys]
            ),
            middlewares: [
                IgnoreAcceptHeaderMiddleware(),
                EmptyRequestBodyMiddleware(),
                ContractAccessMiddleware(
                    bearer: firebaseBearerAuthenticator,
                    scheduler: schedulerAuthenticator,
                    eventarc: eventarcAuthenticator
                ),
            ]
        )
    }
}
