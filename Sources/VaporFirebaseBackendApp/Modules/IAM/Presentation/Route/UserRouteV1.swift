import Vapor

struct UserRouteV1: RouteCollection {
    private let controller: UserController

    init(controller: UserController) {
        self.controller = controller
    }

    func boot(routes: any RoutesBuilder) throws {
        let users = routes.grouped("v1", "users")
        users.get(use: controller.findUsers)
        users.get(":userId", use: controller.getUser)
    }
}
