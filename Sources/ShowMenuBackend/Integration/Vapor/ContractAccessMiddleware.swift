import HTTPTypes
import OpenAPIRuntime
import ShowMenuContracts
import Vapor

/// How a contract operation is protected. Stated once, per operation, in
/// ``ContractAccessMiddleware/table``.
enum Access: Sendable, Equatable {
    /// No credentials required.
    case `public`
    /// A valid Passage access token for an account IAM knows (401 otherwise).
    case authenticated
    /// A valid Passage access token whose account holds the `admin` role (403 otherwise).
    case admin
}

/// The single place that gates contract operations: it looks up the `operationID` in a
/// table and applies that access level before the handler runs. The principal itself is bound
/// earlier by ``ContractPrincipalMiddleware`` (a Vapor middleware: this one only sees
/// `HTTPTypes` and reads `RequestContext.principal`). The use-case PEPs, which fail closed on
/// an unset principal, remain the backstop.
///
/// **Unknown operation, fails closed.** An operation missing from the table throws
/// `AuthorizationError.missingPrincipal` (401 `unauthorized`), so a contract bump that adds an
/// operation but forgets this table is never silently public. Operations are added to the
/// table when they are implemented, not before.
///
/// `next` is never called inside a `do/catch`: an error thrown by the handler propagates as
/// itself.
struct ContractAccessMiddleware: ServerMiddleware {

    /// `operationID` → access. Keyed on the generated `Operations.X.id` constants, so a
    /// renamed operation is a compile error.
    static let table: [String: Access] = [
        Operations.GetHealth.id: .public,
        Operations.GetVersion.id: .public,
    ]

    let table: [String: Access]

    init(table: [String: Access] = ContractAccessMiddleware.table) {
        self.table = table
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
            break
        case .authenticated:
            guard RequestContext.principal != nil else {
                throw AuthorizationError.missingPrincipal
            }
        case .admin:
            guard let principal = RequestContext.principal else {
                throw AuthorizationError.missingPrincipal
            }
            guard principal.roles.contains(.admin) else {
                throw AuthorizationError.denied(reason: "Admin role required")
            }
        }
        return try await next(request, body, metadata)
    }
}
