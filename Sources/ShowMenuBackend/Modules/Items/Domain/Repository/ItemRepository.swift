import Foundation

protocol ItemRepository: Repository where Entity == Item, Model == ItemModel, DTO == ItemDTO {
}
