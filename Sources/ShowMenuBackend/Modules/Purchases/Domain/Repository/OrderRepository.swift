import Foundation

protocol OrderRepository: Repository where Entity == Order, Model == OrderModel, DTO == OrderDTO {
    /// Orders live under `accounts/{accountId}/orders`, so a lookup needs the account.
    /// (`fetch(byId:)` from `Repository` cannot address a sub-collection and throws.)
    func fetch(accountId: String, id: Order.Id) async throws -> Order?
}
