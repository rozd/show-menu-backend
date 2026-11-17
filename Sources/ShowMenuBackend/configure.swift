import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    if let port = Environment.get("PORT").flatMap(Int.init) {
        app.http.server.configuration.port = port
    }

    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))


    // CORS: opt-in. Browser clients on other origins (the dashboard, the showcase) need it;
    // with CORS_ALLOWED_ORIGINS unset (or empty) no CORS middleware is installed at all.
    // Comma-separated list of origins, e.g. "https://dash.example.com,https://menu.example.com".
    // Added at `.beginning` so error responses carry CORS headers too (`useErrorEnvelope`
    // keeps it outside the error middleware).
    let corsOrigins = (Environment.get("CORS_ALLOWED_ORIGINS") ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    if !corsOrigins.isEmpty {
        let cors = CORSMiddleware(configuration: .init(
            allowedOrigin: .any(corsOrigins),
            allowedMethods: [.GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS],
            allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, "Idempotency-Key", "If-Match"]
        ))
        app.middleware.use(cors, at: .beginning)
    }

    // Lift the Idempotency-Key header into RequestContext for the command
    // pipeline's IdempotentCommandHandler. Registered globally; a no-op for
    // requests without the header.
    //
    // Being global, header *validation* applies to every route, not just the
    // mutating ones that consume the key: a malformed `Idempotency-Key` (empty or
    // > 255 chars) on any request — including a read — is
    // rejected with `400 Bad Request`. That is intentional (a malformed header is
    // a client error regardless of method); read endpoints are not exempt.
    app.middleware.use(IdempotencyKeyMiddleware())

    // Render every failure as the contract's error envelope. Replaces Vapor's default
    // ErrorMiddleware (so there is exactly one) and sits right after the trace middleware.
    app.useErrorEnvelope()

    // Persistence. Aggregate storage is always a SQL database (see
    // `App/Store.swift`); the driver follows the environment — Postgres when
    // DATABASE_URL/DATABASE_HOST is configured, an in-memory SQLite database
    // otherwise, so this boots with no external service. Must run before
    // anything touches `app.deps`, which reads the profile when it builds the
    // store.
    try await configureFluentStore(app)

    // Configure integration events
    await configureIntegrationEvents(app)

    // Configure Passage — authentication over the shared `users` table in overlay mode.
    // Overlays Passage's dependent tables on the app's database; FKs require same DB.
    try await configurePassage(app)

    // register routes
    try routes(app)

    // Configuration Point: Debug: print registered endpoints
    printRegisteredRoutes(app)
}

// MARK: - Integration Events Configuration

func configureIntegrationEvents(_ app: Application) async {
    // IAM: register the user-lifecycle integration events + their handlers.
    //
    // In this template both sides live in one process, so publishing an event
    // dispatches it straight to the handler below. In a real deployment the
    // producer and consumer are separate services and the events travel over a
    // message bus — that is what the transactional outbox and its relay
    // (`App/Outbox+Vapor.swift`) exist to make reliable.
    await app.deps.integrationEventRegistry.register(UserCreatedIntegrationEvent.self)
    await app.deps.integrationEventRegistry.register(UserDeletedIntegrationEvent.self)
    await app.deps.integrationEventDispatcher.register(handler: app.deps.userCreatedIntegrationEventHandler)
    await app.deps.integrationEventDispatcher.register(handler: app.deps.userDeletedIntegrationEventHandler)
}

// MARK: - Debugging Helpers

func printRegisteredRoutes(_ app: Application) {
    app.logger.info("Registered routes:")
    for route in app.routes.all {
        let method = String(describing: route.method)
        let path = route.path.map { $0.description }.joined(separator: "/")
        // use logger or print
        app.logger.info("\(method) /\(path)")
    }
}
