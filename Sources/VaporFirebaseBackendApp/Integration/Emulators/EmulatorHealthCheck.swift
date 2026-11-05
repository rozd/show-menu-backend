import Foundation
import Vapor

/// Result of checking emulator availability
struct EmulatorHealthCheckResult: Sendable {
    /// Whether Firestore emulator is available
    let firestoreAvailable: Bool

    /// Whether Auth emulator is available
    let authAvailable: Bool

    /// Error message if any check failed
    let errorMessage: String?

    /// True if all required emulators are available
    var allAvailable: Bool {
        firestoreAvailable && authAvailable
    }
}

/// Health check service for Firebase Emulators
/// Verifies emulator availability at startup
struct EmulatorHealthCheck: Sendable {
    private let config: GoogleCloudPlatform.Configuration.Emulators
    private let client: any Client
    private let logger: Logger

    init(
        config: GoogleCloudPlatform.Configuration.Emulators,
        client: any Client,
        logger: Logger
    ) {
        self.config = config
        self.client = client
        self.logger = logger
    }

    /// Verifies all configured emulators are running and accessible
    /// - Returns: Health check result with availability status
    /// - Throws: EmulatorError if emulators are not available
    @discardableResult
    func verify() async throws -> EmulatorHealthCheckResult {
        logger.info("Checking Firebase Emulator health", metadata: [
            "firestoreHost": .string(config.firestoreHost),
            "firestorePort": .stringConvertible(config.firestorePort),
            "authHost": .string(config.authHost),
            "authPort": .stringConvertible(config.authPort)
        ])

        // Check both emulators concurrently
        async let firestoreCheck = checkEmulator(
            name: "Firestore",
            host: config.firestoreHost,
            port: config.firestorePort
        )
        async let authCheck = checkEmulator(
            name: "Auth",
            host: config.authHost,
            port: config.authPort
        )

        let firestoreResult = await firestoreCheck
        let authResult = await authCheck

        let result = EmulatorHealthCheckResult(
            firestoreAvailable: firestoreResult.isAvailable,
            authAvailable: authResult.isAvailable,
            errorMessage: buildErrorMessage(firestore: firestoreResult, auth: authResult)
        )

        // Log result
        if result.allAvailable {
            logger.info("Emulator health check: OK", metadata: [
                "firestoreEmulator": .string("\(config.firestoreHost):\(config.firestorePort)"),
                "authEmulator": .string("\(config.authHost):\(config.authPort)")
            ])
        } else {
            logger.error("Emulator health check: FAILED", metadata: [
                "errorMessage": .string(result.errorMessage ?? "Unknown error")
            ])
        }

        // Throw appropriate error if not all available
        if !result.allAvailable {
            var available: [String] = []
            var missing: [String] = []

            if firestoreResult.isAvailable {
                available.append("Firestore")
            } else {
                missing.append("Firestore")
            }

            if authResult.isAvailable {
                available.append("Auth")
            } else {
                missing.append("Auth")
            }

            if missing.count == 2 {
                // Neither emulator is running
                throw EmulatorError.notRunning(
                    service: "Firestore",
                    host: config.firestoreHost,
                    port: config.firestorePort
                )
            } else {
                throw EmulatorError.partialAvailability(available: available, missing: missing)
            }
        }

        return result
    }

    /// Checks if a single emulator is available
    private func checkEmulator(name: String, host: String, port: Int) async -> EmulatorCheckResult {
        let url = "http://\(host):\(port)/"

        do {
            let response = try await client.get(URI(string: url))

            // Any successful response (including error pages) means the emulator is running
            let isSuccess = response.status.code < 500
            return EmulatorCheckResult(isAvailable: isSuccess, error: nil)
        } catch {
            logger.debug("\(name) emulator health check failed", metadata: [
                "host": .string(host),
                "port": .stringConvertible(port),
                "error": .string(error.localizedDescription)
            ])
            return EmulatorCheckResult(isAvailable: false, error: error)
        }
    }

    /// Builds error message from individual check results
    private func buildErrorMessage(firestore: EmulatorCheckResult, auth: EmulatorCheckResult) -> String? {
        var messages: [String] = []

        if !firestore.isAvailable {
            messages.append("Firestore emulator not available at \(config.firestoreHost):\(config.firestorePort)")
        }
        if !auth.isAvailable {
            messages.append("Auth emulator not available at \(config.authHost):\(config.authPort)")
        }

        return messages.isEmpty ? nil : messages.joined(separator: "; ")
    }
}

/// Internal result type for individual emulator checks
private struct EmulatorCheckResult: Sendable {
    let isAvailable: Bool
    let error: (any Error)?
}
