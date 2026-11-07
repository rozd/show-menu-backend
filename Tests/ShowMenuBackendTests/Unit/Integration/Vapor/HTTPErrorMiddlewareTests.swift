import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import Vapor
import VaporTesting
@testable import ShowMenuBackend

@Suite("HTTP error mapping and envelope")
struct HTTPErrorMiddlewareTests {

    private struct SomeDomainError: DomainError {}
    private struct SomeValidationError: ValidationError {}
    private struct Unknown: Error {}
    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    @Test("mapping table", arguments: [
        (ApplicationError.notFound(entity: "Feature", id: Feature.Id(rawValue: "x")) as any Error, 404, "not_found"),
        (ApplicationError.invalidInput(reason: "bad") as any Error, 422, "validation_failed"),
        (SomeValidationError() as any Error, 422, "validation_failed"),
        (SomeDomainError() as any Error, 409, "domain_rule_violation"),
        (ConcurrencyError.versionConflict(entity: "Feature", id: "1", expected: .none, actual: .none) as any Error, 409, "version_conflict"),
        (AuthorizationError.denied(reason: "no") as any Error, 403, "forbidden"),
        (AuthorizationError.missingPrincipal as any Error, 401, "unauthorized"),
        (IdempotencyError.malformedKey("k") as any Error, 400, "idempotency_key_invalid"),
        (IdempotencyError.requestInProgress(key: "k") as any Error, 409, "request_in_progress"),
        (IdempotencyError.fingerprintMismatch(key: "k") as any Error, 422, "idempotency_key_reused"),
        (IdempotencyError.corruptRecord(id: "i") as any Error, 500, "internal_error"),
        (FirestoreError.documentNotFound as any Error, 404, "not_found"),
        (FirestoreError.documentAlreadyExists as any Error, 409, "conflict"),
        (FirestoreError.serviceUnavailable as any Error, 503, "service_unavailable"),
        (FirestoreError.requestFailed(statusCode: 3, message: "secret") as any Error, 500, "internal_error"),
        (Abort(.preconditionFailed) as any Error, 412, "precondition_failed"),
        (Abort(.notFound) as any Error, 404, "not_found"),
        (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x")) as any Error, 400, "bad_request"),
        (Unknown() as any Error, 500, "internal_error"),
    ])
    func mapping(error: any Error, status: Int, code: String) {
        let m = HTTPErrorMapping.map(error)
        #expect(m.status.code == UInt(status))
        #expect(m.code == code)
    }

    // MARK: Generated server (`ServerError`) unwrapping

    /// What the generated server throws: the real error wrapped with the request context.
    private func serverError(wrapping error: any Error, status: HTTPResponse.Status = .internalServerError) -> ServerError {
        ServerError(
            operationID: "op",
            request: HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/v1/x"),
            requestBody: nil,
            requestMetadata: .init(),
            causeDescription: "Test cause",
            underlyingError: error,
            httpStatus: status,
            httpHeaderFields: [:],
            httpBody: nil
        )
    }

    /// Stands in for the runtime's `internal` `RuntimeError` (missing body / bad parameter).
    private struct RuntimeLike: Error, HTTPResponseConvertible {
        var httpStatus: HTTPResponse.Status { .badRequest }
        var httpHeaderFields: HTTPFields { [:] }
        var httpBody: HTTPBody? { nil }
    }

    @Test("a ServerError wrapping a DecodingError is a 400 bad_request")
    func serverErrorDecoding() {
        let wrapped = serverError(wrapping: DecodingError.keyNotFound(
            AnyCodingKey("name"), .init(codingPath: [], debugDescription: "x")
        ))
        let m = HTTPErrorMapping.map(wrapped)
        #expect(m.status == .badRequest)
        #expect(m.code == "bad_request")
        #expect(m.details?.first?.message == "Missing required field 'name'")
    }

    @Test("a ServerError wrapping a DomainError is a 409; other layers are unwrapped too")
    func serverErrorDomain() {
        #expect(HTTPErrorMapping.map(serverError(wrapping: SomeDomainError())).status == .conflict)
        #expect(HTTPErrorMapping.map(serverError(wrapping: SomeDomainError())).code == "domain_rule_violation")
        #expect(HTTPErrorMapping.map(serverError(wrapping: SomeValidationError())).status == .unprocessableEntity)
        #expect(HTTPErrorMapping.map(serverError(wrapping: ApplicationError.notFound(entity: "Plan", id: Plan.Id(rawValue: "p")))).code == "not_found")
        #expect(HTTPErrorMapping.map(serverError(wrapping: AuthorizationError.denied(reason: "no"))).status == .forbidden)
        #expect(HTTPErrorMapping.map(serverError(wrapping: Abort(.notFound), status: .notFound)).code == "not_found")
        // Nested.
        #expect(HTTPErrorMapping.map(serverError(wrapping: serverError(wrapping: SomeDomainError()))).status == .conflict)
    }

    @Test("a runtime-originated 4xx (missing body, bad parameter) is mapped by its status")
    func serverErrorRuntime() {
        let m = HTTPErrorMapping.map(serverError(wrapping: RuntimeLike(), status: .badRequest))
        #expect(m.status == .badRequest)
        #expect(m.code == "bad_request")
        #expect(m.message == "Test cause")
    }

    @Test("the logged form of a ServerError never contains request headers (bearer tokens)")
    func serverErrorLogDoesNotLeakCredentials() {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer super-secret-token"
        let error = ServerError(
            operationID: "listPlans",
            request: HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/v1/plans", headerFields: headers),
            requestBody: nil, requestMetadata: .init(),
            causeDescription: "c", underlyingError: Unknown()
        )
        let logged = HTTPErrorMiddleware.loggable(error)
        #expect(!logged.contains("super-secret-token"))
        #expect(logged.hasPrefix("listPlans:"))
    }

    @Test("a ServerError wrapping an unknown error stays a 500 that does not leak")
    func serverErrorUnknown() {
        let m = HTTPErrorMapping.map(serverError(wrapping: Unknown()))
        #expect(m.status == .internalServerError)
        #expect(m.message == "Internal server error")
    }

    @Test("internal errors never leak their description")
    func noLeak() {
        let m = HTTPErrorMapping.map(FirestoreError.requestFailed(statusCode: 3, message: "secret"))
        #expect(m.message == "Internal server error")
        #expect(HTTPErrorMapping.map(Unknown()).message == "Internal server error")
    }

    @Test("decoding error details carry the field path")
    func decodingDetails() throws {
        struct Body: Decodable { let name: String }
        do { _ = try JSONDecoder().decode(Body.self, from: Data("{}".utf8)) } catch {
            let m = HTTPErrorMapping.map(error)
            #expect(m.details?.first?.field == "name")
        }
    }

    private func withApp(_ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        app.useErrorEnvelope()
        app.get("boom") { _ async throws -> String in throw Unknown() }
        app.get("denied") { _ async throws -> String in throw AuthorizationError.denied(reason: "nope") }
        app.get("idem") { _ async throws -> String in throw IdempotencyError.requestInProgress(key: "k") }
        do { try await body(app) } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }

    private struct Hinted: DomainError, HTTPStatusHinted {
        var httpStatusHint: HTTPResponseStatus { .unprocessableEntity }
    }

    @Test("httpStatusHint overrides the DomainError default")
    func hint() {
        let m = HTTPErrorMapping.map(Hinted())
        #expect(m.status == .unprocessableEntity && m.code == "validation_failed")
    }

    @Test("order: trace → error envelope → others; default ErrorMiddleware removed")
    func order() async throws {
        let app = try await Application.make(.testing)
        // entrypoint adds trace at .beginning before configure()
        app.middleware.use(GoogleCloudPlatformTraceMiddleware(projectId: "p"), at: .beginning)
        app.middleware.use(IdempotencyKeyMiddleware())
        app.useErrorEnvelope()
        let chain = app.middleware.resolve()
        #expect(chain[0] is GoogleCloudPlatformTraceMiddleware)
        #expect(chain[1] is HTTPErrorMiddleware)
        #expect(chain.contains { $0 is IdempotencyKeyMiddleware })  // Vapor's RouteLoggingMiddleware default is kept
        #expect(!chain.contains { $0 is ErrorMiddleware })
        try await app.asyncShutdown()
    }

    @Test("unknown route returns the 404 envelope, as JSON")
    func unknownRoute() async throws {
        try await withApp { app in
            try await app.test(.GET, "nope") { res async throws in
                #expect(res.status == .notFound)
                #expect(res.headers.contentType == .json)
                let env = try res.content.decode(ErrorEnvelope.self)
                #expect(env.error.code == "not_found")
            }
        }
    }

    @Test("handlers' errors become envelopes; ErrorMiddleware is not stacked")
    func envelopes() async throws {
        try await withApp { app in
            #expect(!app.middleware.resolve().contains { $0 is ErrorMiddleware })
            try await app.test(.GET, "boom") { res async throws in
                #expect(res.status == .internalServerError)
                let env = try res.content.decode(ErrorEnvelope.self)
                #expect(env.error == .init(code: "internal_error", message: "Internal server error", details: nil))
            }
            try await app.test(.GET, "denied") { res async throws in
                #expect(res.status == .forbidden)
                #expect(try res.content.decode(ErrorEnvelope.self).error.message == "nope")
            }
            try await app.test(.GET, "idem") { res async throws in
                #expect(res.status == .conflict)
                #expect(try res.content.decode(ErrorEnvelope.self).error.code == "request_in_progress")
            }
        }
    }
}
