import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    if let port = Environment.get("PORT").flatMap(Int.init) {
        app.http.server.configuration.port = port
    }

    // Single error format for every failure (D4), replacing Vapor's default
    // ErrorMiddleware. Must run before any other middleware is added.
    app.useErrorEnvelope()

    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))


    // Configuration Point: CORS: uncomment to set
    // let cors = CORSMiddleware(configuration: .init(
    //     allowedOrigin: .all,
    //     allowedMethods: [.GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS],
    //     allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
    // ))
    // app.middleware.use(cors, at: .beginning)

    // Lift the Idempotency-Key header into RequestContext for the command
    // pipeline's IdempotentCommandHandler. Registered globally; a no-op for
    // requests without the header.
    //
    // Being global, header *validation* applies to every route, not just the
    // mutating ones that consume the key: a malformed `Idempotency-Key` (empty or
    // > 255 chars) on any request — including a read like `GET /api/v1/echo/hello` — is
    // rejected with `400 Bad Request`. That is intentional (a malformed header is
    // a client error regardless of method); read endpoints are not exempt.
    app.middleware.use(IdempotencyKeyMiddleware())

    app.gcp = try GoogleCloudPlatform.fromEnvironment(logger: app.logger)
    try await app.gcp.verify(client: app.client, logger: app.logger)
    logFirebaseEnvironment(config: app.gcp.config, logger: app.logger)

    // Configure integration events
    await configureIntegrationEvents(app)

    // register routes
    try routes(app)

    // Configuration Point: Debug: print registered endpoints
    printRegisteredRoutes(app)
}

private func logFirebaseEnvironment(config: GoogleCloudPlatform.Configuration, logger: Logger) {
    switch config.environment {
    case .standalone:
        logger.info("Firebase environment: standalone")

    case .emulator(let emulatorConfig):
        logger.info("Firebase environment: emulator", metadata: [
            "firestoreEmulator": .string("\(emulatorConfig.firestoreHost):\(emulatorConfig.firestorePort)"),
            "authEmulator": .string("\(emulatorConfig.authHost):\(emulatorConfig.authPort)")
        ])

    case .cloudRun:
        logger.info("Firebase environment: cloudRun")
    }
}

// MARK: - Integration Events Configuration

private func configureIntegrationEvents(_ app: Application) async {
    // USER_LIFECYCLE_BEGIN
    // IAM: register Firebase Auth lifecycle events + handlers
    await app.deps.integrationEventRegistry.register(UserCreatedIntegrationEvent.self)
    await app.deps.integrationEventRegistry.register(UserDeletedIntegrationEvent.self)
    await app.deps.integrationEventDispatcher.register(handler: app.deps.userCreatedIntegrationEventHandler)
    await app.deps.integrationEventDispatcher.register(handler: app.deps.userDeletedIntegrationEventHandler)
    // USER_LIFECYCLE_END
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
