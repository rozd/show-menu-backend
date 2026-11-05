import Foundation

struct FindUserQuery: Query {
    let displayName: String?
    let email: String?

    init(displayName: String? = nil, email: String? = nil) {
        self.displayName = displayName
        self.email = email
    }
}
