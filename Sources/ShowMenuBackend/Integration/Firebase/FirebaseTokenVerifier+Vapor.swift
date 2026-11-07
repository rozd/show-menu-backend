import Vapor

extension Application {

    private struct FirebaseTokenVerifierKey: StorageKey {
        typealias Value = FirebaseTokenVerifier
    }

    /// The ID-token verifier, created on first use from `app.gcp` (project id,
    /// and unsigned-token acceptance **only** in emulator mode). Tests may assign
    /// their own before `routes(_:)` runs.
    var firebaseTokenVerifier: FirebaseTokenVerifier {
        get {
            if let existing = storage[FirebaseTokenVerifierKey.self] {
                return existing
            }
            let verifier = FirebaseTokenVerifier(
                projectID: gcp.config.projectID,
                acceptsUnsignedTokens: gcp.config.environment.isEmulator,
                client: client,
                logger: logger
            )
            storage[FirebaseTokenVerifierKey.self] = verifier
            return verifier
        }
        set { storage[FirebaseTokenVerifierKey.self] = newValue }
    }

    /// The bearer authenticator for `authenticated` / `admin` contract operations.
    var firebaseBearerAuthenticator: FirebaseBearerAuthenticator {
        FirebaseBearerAuthenticator(verifier: firebaseTokenVerifier, logger: logger)
    }
}
