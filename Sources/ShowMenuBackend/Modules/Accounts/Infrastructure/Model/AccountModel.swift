import Foundation
import FirestoreAPI

/// `accounts/{accountId}` as written by the client (Flutter): `{name, creator,
/// createdAt, updatedAt, ...}`. Only the fields the backend reads are declared;
/// unknown keys are ignored on decode. The id is the document id.
struct AccountModel: Codable, Sendable {
    @DocumentID
    var id: String

    var name: String?
    var creator: String?
}
