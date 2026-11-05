import Foundation

struct UserNotFoundError: Error {
    let userId: User.Id
}
