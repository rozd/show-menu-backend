import Vapor

/// Protocol for obtaining OAuth2 access tokens for GCP services
/// Implementations: `GoogleAuthProvider` (Cloud Run ADC / service-account key) and `EmulatorAuthProvider`
protocol GCPAuthProvider: Sendable {
    /// Obtains a valid OAuth2 access token
    /// - Returns: Access token string for use in Authorization header
    /// - Throws: If token cannot be obtained
    func getAccessToken() async throws -> String?
}

/// Errors raised by consumers of a `GCPAuthProvider`.
enum GCPAuthProviderError: Error, LocalizedError {
    /// The provider returned no access token (`nil`).
    case noAccessToken

    var errorDescription: String? {
        switch self {
        case .noAccessToken:
            return "GCP auth provider returned no access token"
        }
    }
}
