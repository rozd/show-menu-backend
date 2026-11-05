import Vapor

func routes(_ app: Application) throws {
    // Health check endpoint
    app.get("health") { req async -> String in
        "OK"
    }

    app.get("version") { req async -> String in
        return "0.0.1"
    }

    // USER_LIFECYCLE_BEGIN
    // Eventarc webhook controller handles POST /
    // This receives CloudEvents from Firebase Auth triggers (forwarded by cloud-functions/auth-forwarder)
    try app.register(collection: EventarcWebhookController())
    // USER_LIFECYCLE_END

    // Items (sample module)
    let itemController = ItemController(
        getItemQueryHandler: app.deps.getItemQueryHandler,
        listItemsQueryHandler: app.deps.listItemsQueryHandler,
        createItemCommandHandler: app.deps.createItemCommandHandler,
        updateItemCommandHandler: app.deps.updateItemCommandHandler
    )
    try app.register(collection: ItemRouteV1(controller: itemController))

    // USER_LIFECYCLE_BEGIN
    // IAM (Firebase Auth user lifecycle)
    let userController = UserController(
        getUserQueryHandler: app.deps.getUserQueryHandler,
        findUserQueryHandler: app.deps.findUserQueryHandler
    )
    try app.register(collection: UserRouteV1(controller: userController))
    // USER_LIFECYCLE_END
}
