import Logging

/// Users over a Fluent-managed SQL store: a `FluentDataSource` bound to the
/// `users` table.
struct FluentUserDataSource: FluentDataSource, UserDataSource {
    typealias Model = UserModel

    let transaction: FluentTransaction
    let table = "users"
    let logger: Logger

    func documentId(for model: UserModel) -> String {
        model.id
    }
}
