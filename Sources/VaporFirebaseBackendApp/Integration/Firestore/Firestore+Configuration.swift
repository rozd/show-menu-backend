import Foundation
import FirestoreAPI
import GRPCCore
import GRPCNIOTransportHTTP2

extension Firestore {

    static func create(
        with config: GoogleCloudPlatform.Configuration,
        using authProvider: any GCPAuthProvider,
    ) -> Firestore<HTTP2ClientTransport.Posix> {
        let host = config.environment.firestoreHost
        let port = config.environment.firestorePort
        let usesSSL = !config.environment.isEmulator

        guard let transport = try? HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: port),
            transportSecurity: usesSSL ? .tls : .plaintext
        ) else {
            fatalError("Failed to create gRPC transport")
        }

        return .init(
            projectId: config.projectID,
            transport: transport,
            settings: FirestoreSettings(
                host: host,
                port: port,
                usesSSL: usesSSL
            ),
            accessTokenProvider: AccessTokenProviderAdapter(authProvider: authProvider)
        )
    }

}

// MARK: - AccessTokenProvider Adapter

/// Access scope for Firestore operations
struct FirestoreAccessScope: AccessScope, Sendable {
    let value: String = "https://www.googleapis.com/auth/datastore"
}

/// Adapter to bridge our AuthProvider to FirebaseAPI's AccessTokenProvider
struct AccessTokenProviderAdapter: AccessTokenProvider, Sendable {
    private let authProvider: any GCPAuthProvider

    let scope: any AccessScope = FirestoreAccessScope()

    init(authProvider: any GCPAuthProvider) {
        self.authProvider = authProvider
    }

    func getAccessToken(expirationDuration: TimeInterval) async throws -> String {
        guard let token = try await authProvider.getAccessToken() else {
            throw GCPAuthProviderError.noAccessToken
        }
        return token
    }
}

