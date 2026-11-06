import Vapor

/// Presentation-only module: liveness-style endpoints under `/api/v1/echo`.
/// Mirrors the Node `echo` contract (`hello` → JSON string, `version` → text).
struct EchoRouteV1: RouteCollection {

    /// Overridable for tests; defaults to the process environment.
    private let buildInfo: @Sendable () -> String

    init(buildInfo: @escaping @Sendable () -> String = { Environment.buildInfo }) {
        self.buildInfo = buildInfo
    }

    /// The Node router answers every one of these verbs on each echo route.
    private static let methods: [HTTPMethod] = [.GET, .POST, .PUT, .PATCH, .DELETE]

    func boot(routes: any RoutesBuilder) throws {
        let echo = routes.grouped("v1", "echo")
        let buildInfo = self.buildInfo
        for method in Self.methods {
            echo.on(method, "hello") { _ async throws -> Response in
                try Self.jsonString("Hello from ShowMenuBackend!")
            }
            // Echoes the raw request body back as a JSON string (empty when there is none).
            echo.on(method, "echo", body: .collect(maxSize: "1mb")) { req async throws -> Response in
                try Self.jsonString(req.body.string ?? "")
            }
            echo.on(method, "version") { _ async -> String in
                buildInfo()
            }
        }
        // `/echo/environment` is intentionally not ported: it dumped process.env publicly.
    }

    /// A JSON string literal, as Node's `res.json("…")` produced.
    private static func jsonString(_ value: String) throws -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode(value)))
    }
}
