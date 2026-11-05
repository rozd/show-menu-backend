import Foundation

struct ItemNotFoundError: Error {
    let itemId: Item.Id
}
