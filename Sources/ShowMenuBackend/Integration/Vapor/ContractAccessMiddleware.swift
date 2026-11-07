import HTTPTypes
import OpenAPIRuntime
import ShowMenuContracts
import Vapor

/// How a contract operation is protected. Stated once, per operation, in
/// ``ContractAccessMiddleware/table``.
enum Access: Sendable, Equatable {
    /// No credentials (the operation's own payload, e.g. a signature, is its authentication).
    case `public`
    /// A valid Firebase ID token (401).
    case authenticated
    /// A valid Firebase ID token carrying the `admin` claim (403 otherwise).
    case admin
    /// Cloud Scheduler: Google OIDC token or `X-Api-Key`.
    case scheduler
    /// Eventarc forwarders: Google OIDC token.
    case eventarc
}

/// The single place that authenticates contract operations: it looks up the
/// `operationID` in an exhaustive table and applies that access level before the
/// handler runs. Handlers need not re-check authentication; the use-case PEPs, which
/// fail closed on an unset `RequestContext.principal`, are the backstop.
///
/// **Unknown operation → fails closed.** An operation missing from the table throws
/// `AuthorizationError.missingPrincipal` (401 `unauthorized`), so a contract bump that adds
/// an operation but forgets this table is never silently public.
///
/// **Authentication is finished before `next` is called** and `next` is never called inside
/// a `do/catch`: an error thrown by the handler propagates as itself (commit b249fdc fixed a
/// scheduler job error being turned into a 401).
struct ContractAccessMiddleware: ServerMiddleware {

    /// `operationID` → access. Keyed on the generated `Operations.X.id` constants, so a
    /// renamed operation is a compile error.
    static let table: [String: Access] = [
        Operations.GetHealth.id: .public,
        Operations.GetVersion.id: .public,
        Operations.HandleLiqPayCallback.id: .public,

        Operations.CreateFeature.id: .admin,
        Operations.UpdateFeature.id: .admin,
        Operations.ListPlans.id: .admin,
        Operations.CreatePlan.id: .admin,
        Operations.GetPlan.id: .admin,
        Operations.UpdatePlan.id: .admin,
        Operations.ActivatePlan.id: .admin,
        Operations.DeactivatePlan.id: .admin,
        Operations.AddPlanFeature.id: .admin,
        Operations.RemovePlanFeature.id: .admin,

        Operations.PurchaseSubscription.id: .authenticated,
        Operations.CancelPurchase.id: .authenticated,
        Operations.CancelSubscription.id: .authenticated,
        Operations.FindUsers.id: .authenticated,
        Operations.GetUser.id: .authenticated,

        Operations.CheckExpiredSubscriptions.id: .scheduler,
        Operations.HandleEventarcEvent.id: .eventarc,
    ]

    let table: [String: Access]
    let bearer: FirebaseBearerAuthenticator
    let scheduler: SchedulerAuthenticator
    let eventarc: EventarcAuthenticator

    init(
        table: [String: Access] = ContractAccessMiddleware.table,
        bearer: FirebaseBearerAuthenticator,
        scheduler: SchedulerAuthenticator,
        eventarc: EventarcAuthenticator
    ) {
        self.table = table
        self.bearer = bearer
        self.scheduler = scheduler
        self.eventarc = eventarc
    }

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard let access = table[operationID] else {
            throw AuthorizationError.missingPrincipal
        }

        switch access {
        case .public:
            return try await next(request, body, metadata)

        case .authenticated, .admin:
            let principal = try await bearer.authenticate(headers: request.headerFields)
            if access == .admin, !principal.roles.contains(.admin) {
                throw AuthorizationError.denied(reason: "Admin role required")
            }
            return try await RequestContext.$principal.withValue(principal) {
                try await next(request, body, metadata)
            }

        case .scheduler:
            try await scheduler.authenticate(headers: request.headerFields)
            return try await next(request, body, metadata)

        case .eventarc:
            try await eventarc.authenticate(headers: request.headerFields)
            return try await next(request, body, metadata)
        }
    }
}
