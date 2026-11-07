import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import Testing
import Vapor
@testable import ShowMenuBackend

/// The access table is the one place stating how each contract operation is protected. These
/// tests pin the operation list (hard-coded, so a contract change must be acknowledged here),
/// the public set, fail-closed behaviour and the "handler error is never a 401" invariant.
@Suite("Contract access middleware")
struct ContractAccessMiddlewareTests {

    static let allOperationIDs: Set<String> = [
        "getHealth", "getVersion",
        "createFeature", "updateFeature",
        "listPlans", "createPlan", "getPlan", "updatePlan", "activatePlan", "deactivatePlan",
        "addPlanFeature", "removePlanFeature",
        "purchaseSubscription", "cancelPurchase", "cancelSubscription",
        "findUsers", "getUser",
        "handleLiqPayCallback", "checkExpiredSubscriptions", "handleEventarcEvent",
    ]

    private let logger = Logger(label: "test")

    private func makeSUT(
        scheduler: SchedulerAuthenticator? = nil,
        eventarc: EventarcAuthenticator? = nil,
        table: [String: Access] = ContractAccessMiddleware.table
    ) -> ContractAccessMiddleware {
        ContractAccessMiddleware(
            table: table,
            bearer: FirebaseBearerAuthenticator(verifier: ContractTestApp.unsignedVerifier(), logger: logger),
            scheduler: scheduler ?? SchedulerAuthenticator(apiKey: "key", oidc: nil, logger: logger),
            eventarc: eventarc ?? EventarcAuthenticator(oidc: nil, bypassInEmulator: false, logger: logger)
        )
    }

    private func request(bearer: String? = nil, apiKey: String? = nil) -> HTTPRequest {
        var headers = HTTPFields()
        if let bearer { headers[.authorization] = "Bearer \(bearer)" }
        if let apiKey { headers[SchedulerAuthenticator.apiKeyHeader] = apiKey }
        return HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/v1/x", headerFields: headers)
    }

    private func run(
        _ sut: ContractAccessMiddleware, _ operationID: String, _ request: HTTPRequest,
        next: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        _ = try await sut.intercept(request, body: nil, metadata: .init(), operationID: operationID) { _, _, _ in
            try await next()
            return (HTTPResponse(status: .ok), nil)
        }
    }

    /// The status the error envelope would answer for what `run` threw.
    private func status(
        _ sut: ContractAccessMiddleware, _ operationID: String, _ request: HTTPRequest
    ) async -> HTTPResponseStatus {
        do {
            try await run(sut, operationID, request)
            return .ok
        } catch {
            return HTTPErrorMapping.map(error).status
        }
    }

    // MARK: The table

    @Test("the table covers exactly the 20 contract operations")
    func tableCoversExactlyTheContract() {
        #expect(Set(ContractAccessMiddleware.table.keys) == Self.allOperationIDs)
        #expect(Self.allOperationIDs.count == 20)
    }

    @Test("the public operations are exactly health, version and the LiqPay callback")
    func publicSet() {
        let publicOperations = Set(ContractAccessMiddleware.table.filter { $0.value == .public }.keys)
        #expect(publicOperations == ["getHealth", "getVersion", "handleLiqPayCallback"])
    }

    @Test("access levels: ten admin Catalog ops, five authenticated, scheduler and eventarc")
    func accessLevels() {
        let table = ContractAccessMiddleware.table
        let admin: Set = [
            "createFeature", "updateFeature", "listPlans", "createPlan", "getPlan", "updatePlan",
            "activatePlan", "deactivatePlan", "addPlanFeature", "removePlanFeature",
        ]
        #expect(Set(table.filter { $0.value == .admin }.keys) == admin)
        #expect(Set(table.filter { $0.value == .authenticated }.keys) == [
            "purchaseSubscription", "cancelPurchase", "cancelSubscription", "findUsers", "getUser",
        ])
        #expect(table["checkExpiredSubscriptions"] == .scheduler)
        #expect(table["handleEventarcEvent"] == .eventarc)
    }

    // MARK: Behaviour

    @Test("an unknown operation fails closed (401), even with a valid admin token")
    func unknownOperationFailsClosed() async throws {
        let sut = makeSUT()
        let token = try ContractTestApp.unsignedToken(admin: true)
        #expect(await status(sut, "somethingNew", request(bearer: token)) == .unauthorized)
        #expect(await status(sut, "somethingNew", request()) == .unauthorized)
    }

    @Test("public operations need no credentials")
    func publicOperations() async {
        let sut = makeSUT()
        for operation in ["getHealth", "getVersion", "handleLiqPayCallback"] {
            #expect(await status(sut, operation, request()) == .ok, "\(operation)")
        }
    }

    @Test("authenticated operations: no token 401, any valid token passes")
    func authenticatedOperations() async throws {
        let sut = makeSUT()
        let token = try ContractTestApp.unsignedToken()
        #expect(await status(sut, "getUser", request()) == .unauthorized)
        #expect(await status(sut, "getUser", request(bearer: "garbage")) == .unauthorized)
        #expect(await status(sut, "getUser", request(bearer: token)) == .ok)
    }

    @Test("an admin operation without the admin claim is 403; with it, it passes")
    func adminOperations() async throws {
        let sut = makeSUT()
        let user = try ContractTestApp.unsignedToken(admin: false)
        let admin = try ContractTestApp.unsignedToken(admin: true)
        #expect(await status(sut, "createPlan", request()) == .unauthorized)
        #expect(await status(sut, "createPlan", request(bearer: user)) == .forbidden)
        #expect(await status(sut, "createPlan", request(bearer: admin)) == .ok)
    }

    @Test("the principal is bound for the handler only")
    func principalBinding() async throws {
        let sut = makeSUT()
        let seen = LockedBox<String?>(nil)
        try await run(sut, "getUser", request(bearer: try ContractTestApp.unsignedToken(sub: "uid-7"))) {
            seen.value = RequestContext.principal?.id
        }
        #expect(seen.value == "uid-7")
        #expect(RequestContext.principal == nil)
    }

    @Test("scheduler operation: API key or nothing; eventarc: no OIDC configured denies")
    func machineOperations() async {
        let sut = makeSUT()
        #expect(await status(sut, "checkExpiredSubscriptions", request()) == .unauthorized)
        #expect(await status(sut, "checkExpiredSubscriptions", request(apiKey: "wrong")) == .unauthorized)
        #expect(await status(sut, "checkExpiredSubscriptions", request(apiKey: "key")) == .ok)
        #expect(await status(sut, "handleEventarcEvent", request()) == .unauthorized)

        let bypass = makeSUT(eventarc: EventarcAuthenticator(oidc: nil, bypassInEmulator: true, logger: logger))
        #expect(await status(bypass, "handleEventarcEvent", request()) == .ok)
    }

    @Test("an error thrown by the handler propagates as itself, never as a 401")
    func handlerErrorIsNotConvertedTo401() async throws {
        let sut = makeSUT()
        struct JobFailure: Error, Equatable {}
        let admin = try ContractTestApp.unsignedToken(admin: true)
        let cases: [(String, HTTPRequest)] = [
            ("checkExpiredSubscriptions", request(apiKey: "key")),
            ("getUser", request(bearer: admin)),
            ("createPlan", request(bearer: admin)),
            ("handleEventarcEvent", request()),
            ("getHealth", request()),
        ]
        let sutWithBypass = makeSUT(eventarc: EventarcAuthenticator(oidc: nil, bypassInEmulator: true, logger: logger))
        for (operation, req) in cases {
            let middleware = operation == "handleEventarcEvent" ? sutWithBypass : sut
            do {
                try await run(middleware, operation, req) { throw JobFailure() }
                Issue.record("\(operation): expected the handler error to propagate")
            } catch is JobFailure {
                // propagated unchanged
            }
        }
    }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
