import Vapor

func routes(_ app: Application) throws {
    // Health check endpoint
    app.get("health") { req async -> String in
        "OK"
    }

    app.get("version") { req async -> String in
        Environment.buildInfo
    }

    // USER_LIFECYCLE_BEGIN
    // Eventarc webhook controller handles POST /
    // This receives CloudEvents from Firebase Auth triggers (forwarded by cloud-functions/auth-forwarder)
    // Guarded by Google OIDC verification (bypassed only in emulator mode).
    try app.grouped(app.eventarcAuthMiddleware).register(collection: EventarcWebhookController())
    // USER_LIFECYCLE_END

    // All module routes live under `/api` (D3); `/health`, `/version` and
    // `POST /` stay at the root. Each RouteCollection adds its own `v1` segment.
    let api = app.grouped("api")

    // Route groups (D5): `public` needs no token, `authenticated` needs a valid
    // Firebase ID token (401), `admin` additionally needs the `admin` claim (403).
    let verifier = app.firebaseTokenVerifier
    let publicRoutes = api
    let authenticated = api.grouped(FirebaseAuthMiddleware(verifier: verifier))
    let admin = authenticated.grouped(RequireAdminMiddleware())

    try publicRoutes.register(collection: EchoRouteV1())

    // /plans/* is admin-only. Node's guard also answered 401/403 for *unmatched*
    // paths under /plans; Vapor skips group middleware when no route matches, so
    // a guarded catch-all reproduces that (admins get the normal 404).
    try admin.register(collection: PlansGuardRouteV1())

    // Catalog: `POST/PUT /plans/features` are admin-only. Registered after the
    // guard collection; the explicit routes win over its `/plans/**` catch-all.
    let featureController = FeatureController(
        createFeatureCommandHandler: app.deps.createFeatureCommandHandler,
        updateFeatureCommandHandler: app.deps.updateFeatureCommandHandler
    )
    try admin.register(collection: FeatureRouteV1(controller: featureController))

    // Catalog: `/plans` create/list/get/update/activate/deactivate/features (admin-only).
    let planController = PlanController(
        createPlanCommandHandler: app.deps.createPlanCommandHandler,
        getPlanQueryHandler: app.deps.getPlanQueryHandler,
        listPlansQueryHandler: app.deps.listPlansQueryHandler,
        updatePlanCommandHandler: app.deps.updatePlanCommandHandler,
        activatePlanCommandHandler: app.deps.activatePlanCommandHandler,
        deactivatePlanCommandHandler: app.deps.deactivatePlanCommandHandler,
        addPlanFeatureCommandHandler: app.deps.addPlanFeatureCommandHandler,
        removePlanFeatureCommandHandler: app.deps.removePlanFeatureCommandHandler
    )
    try admin.register(collection: PlanRouteV1(controller: planController))

    // Purchases: `POST /accounts/:accountId/purchases` and `DELETE .../purchases/:invoiceId` (any authenticated user; the use
    // case enforces account membership).
    let purchaseController = PurchaseController(
        purchaseFlow: app.deps.purchaseSubscriptionFlow,
        cancelPurchaseCommandHandler: app.deps.cancelPurchaseCommandHandler
    )
    try authenticated.register(collection: PurchaseRouteV1(controller: purchaseController))

    // USER_LIFECYCLE_BEGIN
    // IAM (Firebase Auth user lifecycle)
    let userController = UserController(
        getUserQueryHandler: app.deps.getUserQueryHandler,
        findUserQueryHandler: app.deps.findUserQueryHandler
    )
    // Conservative: authenticated (was public).
    try authenticated.register(collection: UserRouteV1(controller: userController))
    // USER_LIFECYCLE_END
}
