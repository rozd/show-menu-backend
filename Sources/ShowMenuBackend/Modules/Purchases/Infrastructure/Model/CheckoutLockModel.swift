import FirestoreAPI

/// `checkout_locks/{accountId}` — the concurrency backstop for "one pending checkout
/// per account". Backend-owned root collection (like `plan_skus`), deliberately NOT under
/// `accounts/{a}/checkout-sessions`: Flutter decodes every document there.
///
/// Firestore cannot run a query inside the pinned client's transaction (roadmap §7, S05),
/// so the purchase transaction `get`s this document instead (a transactional read of a
/// single key: two concurrent purchases both read it, only one commit wins and the other
/// is retried by the runner, its re-read then answers 409). The lock is **self-healing**:
/// it only names the invoice whose session was last started; the purchase is blocked while
/// *that session* is `pending`, and a lock whose session is terminal (success / failure /
/// cancelled) or gone is simply overwritten. Nothing has to release it.
struct CheckoutLockModel: Codable, Sendable {
    let accountId: String
    let invoiceId: String
    let createdAt: Timestamp
}
