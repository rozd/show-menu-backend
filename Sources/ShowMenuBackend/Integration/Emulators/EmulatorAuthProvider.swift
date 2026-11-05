import Foundation

/// Auth provider for Firebase Emulator environments
/// Firebase Emulators accept unauthenticated requests, so this provider is a no-op
final class EmulatorAuthProvider: GCPAuthProvider, Sendable {
    /// Returns an empty string since emulators don't require authentication
    /// The FirestoreClient will skip the Authorization header when in emulator mode
    func getAccessToken() async throws -> String? {
        // Emulators don't require authentication
        // Return empty string - the client should skip auth header when using this provider
        return "owner"
    }
}
