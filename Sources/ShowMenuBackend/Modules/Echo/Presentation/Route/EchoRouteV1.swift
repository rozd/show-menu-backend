import Vapor

/// Presentation-only module: liveness-style endpoints under `/api/v1/echo`.
/// Mirrors the Node `echo` contract (`hello` → JSON string, `version` → text).
struct EchoRouteV1: RouteCollection {

    /// Overridable for tests; defaults to the process environment.
    private let buildInfo: @Sendable () -> String

    init(buildInfo: @escaping @Sendable () -> String = { Environment.buildInfo }) {
        self.buildInfo = buildInfo
    }

    func boot(routes: any RoutesBuilder) throws {
        let echo = routes.grouped("v1", "echo")
        echo.get("hello") { _ async throws -> Response in
            // A JSON string literal, as Node's `res.json("…")` produced.
            let body = try JSONEncoder().encode("Hello from ShowMenuBackend!")
            var headers = HTTPHeaders()
            headers.contentType = .json
            return Response(status: .ok, headers: headers, body: .init(data: body))
        }
        let buildInfo = self.buildInfo
        echo.get("version") { _ async -> String in
            buildInfo()
        }
    }
}
