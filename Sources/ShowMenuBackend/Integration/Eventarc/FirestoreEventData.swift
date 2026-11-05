import Vapor

/// Firestore document event payload forwarded by `firestore-forwarder`
/// (`cloud-functions/firestore-forwarder`, or the emulator bridge in
/// `show-menu-firebase/forwarders`).
///
/// The forwarder has already flattened the trigger's typed `fields` into plain
/// JSON (Timestamps as ISO strings), so only the fields this backend reads are
/// declared; everything else is ignored.
struct FirestoreEventData: Content, Sendable {
    /// Document path relative to the database, e.g. `accounts/acc-1`.
    let path: String

    /// Last path segment, e.g. `acc-1`.
    let documentId: String

    /// The created document's fields (`accounts/{id}` is the only trigger today).
    let data: AccountFields?

    /// `accounts/{id}` fields. Field names are the ones Flutter writes
    /// (`firestore_account_data_source.dart`): `name`, `creator`.
    struct AccountFields: Content, Sendable {
        let name: String?
        let creator: String?
    }
}
