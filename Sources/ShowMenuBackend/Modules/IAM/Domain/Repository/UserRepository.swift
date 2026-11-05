import Foundation

protocol UserRepository: Repository where Entity == User, Model == UserModel, DTO == UserDTO {
}
