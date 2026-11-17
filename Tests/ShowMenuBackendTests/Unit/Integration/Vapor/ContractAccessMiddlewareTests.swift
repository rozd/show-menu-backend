import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import Vapor
@testable import ShowMenuBackend

/// The access table is the one place stating how each contract operation is protected. These
/// tests pin the production table (nothing but health and version is reachable yet), the
/// fail-closed behaviour and the "handler error is never a 401" invariant.
@Suite("Contract access middleware")
struct ContractAccessMiddlewareTests {

    private let request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/v1/x")

    private func run(
        _ sut: ContractAccessMiddleware, _ operationID: String,
        next: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        _ = try await sut.intercept(request, body: nil, metadata: .init(), operationID: operationID) { _, _, _ in
            try await next()
            return (HTTPResponse(status: .ok), nil)
        }
    }

    /// The status the error envelope would answer for what `run` threw.
    private func status(
        _ sut: ContractAccessMiddleware, _ operationID: String, principal: (any Principal)? = nil
    ) async -> HTTPResponseStatus {
        await RequestContext.$principal.withValue(principal) {
            do {
                try await run(sut, operationID)
                return .ok
            } catch {
                return HTTPErrorMapping.map(error).status
            }
        }
    }

    private let table: [String: Access] = ["open": .public, "mine": .authenticated, "ops": .admin]

    @Test("the production table is exactly getHealth and getVersion, both public")
    func productionTable() {
        #expect(ContractAccessMiddleware.table == ["getHealth": .public, "getVersion": .public])
    }

    @Test("an unlisted operation fails closed (401), even for an admin")
    func unlistedFailsClosed() async {
        let sut = ContractAccessMiddleware(table: table)
        let admin = StubPrincipal(roles: [.admin])
        #expect(await status(sut, "somethingNew") == .unauthorized)
        #expect(await status(sut, "somethingNew", principal: admin) == .unauthorized)
        // The default (production) table does not list a real but unimplemented operation.
        #expect(await status(ContractAccessMiddleware(), "getCurrentOwner", principal: admin) == .unauthorized)
    }

    @Test("public needs no principal")
    func publicOperation() async {
        #expect(await status(ContractAccessMiddleware(table: table), "open") == .ok)
    }

    @Test("authenticated: no principal 401, any principal passes")
    func authenticated() async {
        let sut = ContractAccessMiddleware(table: table)
        #expect(await status(sut, "mine") == .unauthorized)
        #expect(await status(sut, "mine", principal: StubPrincipal()) == .ok)
    }

    @Test("admin: no principal 401, without the role 403 (Admin role required), with it passes")
    func admin() async {
        let sut = ContractAccessMiddleware(table: table)
        #expect(await status(sut, "ops") == .unauthorized)
        #expect(await status(sut, "ops", principal: StubPrincipal()) == .forbidden)
        #expect(await status(sut, "ops", principal: StubPrincipal(roles: [.admin])) == .ok)
        do {
            try await RequestContext.$principal.withValue(StubPrincipal()) { try await run(sut, "ops") }
            Issue.record("expected a denial")
        } catch {
            #expect(error as? AuthorizationError == .denied(reason: "Admin role required"))
        }
    }

    @Test("the handler sees the principal the request carried")
    func principalPassesThrough() async throws {
        let sut = ContractAccessMiddleware(table: table)
        let seen = LockedBox<String?>(nil)
        try await RequestContext.$principal.withValue(StubPrincipal(id: "u-7")) {
            try await run(sut, "mine") { seen.value = RequestContext.principal?.id }
        }
        #expect(seen.value == "u-7")
    }

    @Test("an error thrown by the handler propagates as itself, never as a 401")
    func handlerErrorPropagates() async {
        struct Failure: Error, Equatable {}
        let sut = ContractAccessMiddleware(table: table)
        let admin = StubPrincipal(roles: [.admin])
        for operation in ["open", "mine", "ops"] {
            await RequestContext.$principal.withValue(admin) {
                do {
                    try await run(sut, operation) { throw Failure() }
                    Issue.record("\(operation): expected the handler error to propagate")
                } catch is Failure {
                    // propagated unchanged
                } catch {
                    Issue.record("\(operation): \(error)")
                }
            }
        }
    }
}
