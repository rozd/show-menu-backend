import Foundation

/// `DELETE /accounts/:accountId/purchases/:invoiceId`: both ids come from the route.
struct CancelPurchaseCommand: Command {
    struct Payload: Sendable, Codable {}

    let accountId: String
    let invoiceId: String
    let payload: Payload = .init()
    let metadata: CommandMetadata
}
