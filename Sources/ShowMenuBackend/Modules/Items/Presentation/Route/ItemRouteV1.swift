import Vapor

struct ItemRouteV1: RouteCollection {
    private let controller: ItemController

    init(controller: ItemController) {
        self.controller = controller
    }

    func boot(routes: any RoutesBuilder) throws {
        let items = routes.grouped("v1", "items")
        items.get(use: controller.listItems)
        items.get(":itemId", use: controller.getItem)
        items.post(use: controller.createItem)
        items.put(":itemId", use: controller.updateItem)
    }
}
