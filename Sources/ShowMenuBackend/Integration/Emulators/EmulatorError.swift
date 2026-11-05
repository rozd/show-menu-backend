import Foundation

/// Errors specific to Firebase Emulator operations
enum EmulatorError: Error, LocalizedError, Sendable {
    /// Emulator is configured but not running
    case notRunning(service: String, host: String, port: Int)

    /// Health check timed out
    case healthCheckTimeout(service: String, timeoutSeconds: Int)

    /// Some emulators are running but not all required ones
    case partialAvailability(available: [String], missing: [String])

    /// Invalid emulator host format in environment variable
    case invalidHostFormat(envVar: String, value: String)

    var errorDescription: String? {
        switch self {
        case .notRunning(let service, let host, let port):
            return "\(service) emulator not running at \(host):\(port). Start with: firebase emulators:start"
        case .healthCheckTimeout(let service, let timeout):
            return "\(service) emulator health check timed out after \(timeout) seconds"
        case .partialAvailability(let available, let missing):
            return "Partial emulator availability. Running: \(available.joined(separator: ", ")). Missing: \(missing.joined(separator: ", "))"
        case .invalidHostFormat(let envVar, let value):
            return "Invalid format for \(envVar): '\(value)'. Expected format: host:port"
        }
    }
}
