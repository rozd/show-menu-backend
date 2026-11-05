import Foundation
import Logging
import Vapor
import FirestoreAPI
import GRPCNIOTransportHTTP2
@testable import ShowMenuBackend

/// Shared helper for creating a Firestore gRPC client connected to the local emulator.
///
/// Usage:
/// ```swift
/// @Suite(.tags(.integration))
/// struct MyIntegrationTests {
///     @Test(.enabled(if: EmulatorFirestoreHelper.isAvailable))
///     func myTest() async throws {
///         let firestore = try EmulatorFirestoreHelper.makeFirestore()
///         let ds = FirestoreFeatureDataSource(transaction: .direct(firestore: firestore), prefix: "", logger: logger)
///         // ...
///     }
/// }
/// ```
///
/// Requirements:
///   - Firebase Emulator running: `firebase emulators:start`
///   - Environment variables set:
///     - `FIRESTORE_EMULATOR_HOST=localhost:9002`
///     - `GCP_PROJECT_ID=your-test-project`
enum EmulatorFirestoreHelper {

    /// Whether the emulator environment is available for integration tests.
    static var isAvailable: Bool {
        Environment.get("FIRESTORE_EMULATOR_HOST") != nil
            && Environment.get("GCP_PROJECT_ID") != nil
    }

    /// Creates a Firestore gRPC client connected to the emulator.
    ///
    /// Reuses the production `Firestore.create` factory with emulator configuration,
    /// ensuring the test client behaves identically to the real one.
    static func makeFirestore() throws -> Firestore<HTTP2ClientTransport.Posix> {
        let hostPort = Environment.get("FIRESTORE_EMULATOR_HOST") ?? "localhost:9002"
        let components = hostPort.split(separator: ":", maxSplits: 1)

        let host = components.count >= 1 ? String(components[0]) : "localhost"
        let port = components.count >= 2 ? (Int(components[1]) ?? 9002) : 9002
        let projectId = Environment.get("GCP_PROJECT_ID") ?? "demo-project"

        let config = GoogleCloudPlatform.Configuration(
            projectID: projectId,
            thisServiceURL: "http://localhost:8080",
            environment: .emulator(.init(
                firestoreHost: host,
                firestorePort: port,
                authHost: "localhost",
                authPort: 9099
            ))
        )

        return .create(with: config, using: EmulatorAuthProvider())
    }

    /// Creates a silent logger for integration tests.
    static func makeLogger() -> Logger {
        Logger(label: "integration-test", factory: { _ in CapturingLogHandler() })
    }

    /// Generates a unique document ID to prevent test interference.
    static func uniqueId() -> String {
        UUID().uuidString
    }
}
