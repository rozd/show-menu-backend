import Vapor

// MARK: -

struct GoogleCloudPlatform: Sendable {

    let config: Configuration

    /// The process-wide GCP auth provider, built **once** at startup.
    ///
    /// Building it here (a throwing path called from `configure`) rather than in
    /// the non-throwing `Resolver` closure makes a bad credential fail the boot,
    /// not the first request.
    let authProvider: any GCPAuthProvider
}

extension GoogleCloudPlatform {

    /// Detects the GCP environment from `environment` and builds the matching
    /// auth provider.
    ///
    /// - Throws: `ConfigurationError` / `EmulatorError` for a bad environment,
    ///   or `GoogleAuth.CredentialsError` if the credentials cannot be loaded.
    static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: Logger
    ) throws -> GoogleCloudPlatform {
        let config = try Configuration.fromEnvironment(environment: environment)
        return .init(
            config: config,
            authProvider: try config.makeAuthProvider(logger: logger)
        )
    }

}

// MARK: - Environment

extension GoogleCloudPlatform {

    enum Environment: Sendable {
        case standalone(ServiceAccountKey)
        case emulator(Configuration.Emulators)
        case cloudRun

        var isEmulator: Bool {
            if case .emulator = self {
                return true
            }
            return false
        }
    }
}

extension GoogleCloudPlatform.Environment {

    var firestoreHost: String {
        switch self {
        case .emulator(let config):
            return config.firestoreHost
        case .cloudRun, .standalone:
            return "firestore.googleapis.com"
        }
    }

    var firestorePort: Int {
        switch self {
        case .emulator(let config):
            return config.firestorePort
        case .cloudRun, .standalone:
            return 443
        }
    }

    var firestoreBaseURL: String {
        switch self {
        case .emulator(let config):
            return config.firestoreBaseURL
        case .cloudRun, .standalone:
            return "https://firestore.googleapis.com/v1"
        }
    }
}

// MARK: Service Account Key

extension GoogleCloudPlatform.Environment {

    /// The env var a standalone service-account key path was read from.
    enum CredentialsPathVariable: String, Sendable, Equatable {
        /// The standard Google variable; takes precedence.
        case googleApplicationCredentials = "GOOGLE_APPLICATION_CREDENTIALS"
        /// The template's legacy variable; still honoured as a fallback, but
        /// deprecated in favour of `GOOGLE_APPLICATION_CREDENTIALS`.
        case serviceAccountJSONPath = "GCP_SERVICE_ACCOUNT_JSON_PATH"

        var isDeprecated: Bool { self == .serviceAccountJSONPath }
    }

    /// A service-account JSON key loaded (and validated) at startup for the
    /// standalone environment.
    struct ServiceAccountKey: Sendable {
        /// The raw key-file bytes, handed to `GoogleAuth` as-is.
        let keyJSON: Data
        /// The path the key was read from.
        let path: String
        /// Which env var supplied `path`.
        let pathVariable: CredentialsPathVariable
    }

    /// Decoder used only to validate that a key file is a service-account
    /// key; the bytes themselves are passed to `GoogleAuth`.
    struct ServiceAccountCredentials: Decodable {
        let type: String
        let projectId: String
        let privateKeyId: String
        let privateKey: String
        let clientEmail: String
        let clientId: String

        enum CodingKeys: String, CodingKey {
            case type
            case projectId    = "project_id"
            case privateKeyId = "private_key_id"
            case privateKey   = "private_key"
            case clientEmail  = "client_email"
            case clientId     = "client_id"
        }
    }
}

// MARK: - Configuration

extension GoogleCloudPlatform {

    struct Configuration: Sendable {
        /// GCP project ID (required for Firestore and authentication)
        let projectID: String

        let thisServiceURL: String

        /// Firebase environment (production, emulator, or cloudRun)
        let environment: Environment
    }
}

extension GoogleCloudPlatform.Configuration {

    /// Detects the environment: emulator (both emulator host vars set) →
    /// Cloud Run (`K_SERVICE` set) → standalone (service-account key file).
    ///
    /// Pure apart from reading the standalone key file: it never constructs
    /// `GoogleAuth` credentials. `environment` defaults to the process env;
    /// tests pass a literal dictionary instead of mutating it.
    static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        let gcpEnvironment: GoogleCloudPlatform.Environment
        if let emulatorConfig = try Emulators.fromEnvironment(environment: environment) {
            gcpEnvironment = .emulator(emulatorConfig)
        } else if Vapor.Environment.isRunningInCloudRun(in: environment) {
            gcpEnvironment = .cloudRun
        } else {
            gcpEnvironment = .standalone(try loadServiceAccountKey(from: environment))
        }

        // The service URL is only needed for Cloud Tasks / OIDC audiences; in the
        // emulator it defaults to the local listener so boot never requires it.
        let serviceURL: String
        if gcpEnvironment.isEmulator, environment["GCP_CLOUD_RUN_SERVICE_URL"] == nil {
            serviceURL = "http://localhost:\(environment["PORT"] ?? "8080")"
        } else {
            serviceURL = try Vapor.Environment.gcpThisServiceURL(in: environment)
        }

        return .init(
            projectID: try Vapor.Environment.gcpProjectId(in: environment),
            thisServiceURL: serviceURL,
            environment: gcpEnvironment
        )
    }

    /// Reads and validates the standalone service-account key.
    ///
    /// `GOOGLE_APPLICATION_CREDENTIALS` wins; `GCP_SERVICE_ACCOUNT_JSON_PATH` is a
    /// deprecated fallback (the variable used is recorded so a warning can be
    /// logged when the provider is built).
    private static func loadServiceAccountKey(
        from environment: [String: String]
    ) throws -> GoogleCloudPlatform.Environment.ServiceAccountKey {
        typealias PathVariable = GoogleCloudPlatform.Environment.CredentialsPathVariable

        let pathVariable: PathVariable
        let credentialsPath: String
        if let path = environment[PathVariable.googleApplicationCredentials.rawValue] {
            (pathVariable, credentialsPath) = (.googleApplicationCredentials, path)
        } else if let path = environment[PathVariable.serviceAccountJSONPath.rawValue] {
            (pathVariable, credentialsPath) = (.serviceAccountJSONPath, path)
        } else {
            throw GoogleCloudPlatform.ConfigurationError.missingCredentials
        }

        guard FileManager.default.fileExists(atPath: credentialsPath) else {
            throw GoogleCloudPlatform.ConfigurationError.credentialsFileNotFound(path: credentialsPath)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: credentialsPath))
            _ = try JSONDecoder().decode(
                GoogleCloudPlatform.Environment.ServiceAccountCredentials.self,
                from: data
            )
        } catch {
            throw GoogleCloudPlatform.ConfigurationError.credentialsDecodingError(underlying: error)
        }
        return .init(keyJSON: data, path: credentialsPath, pathVariable: pathVariable)
    }
}

// MARK: Emulators Configuration

extension GoogleCloudPlatform.Configuration {

    struct Emulators: Sendable, Equatable {

        /// Firestore emulator host (default: localhost)
        let firestoreHost: String

        /// Firestore emulator port (default: 9002)
        let firestorePort: Int

        /// Auth emulator host (default: localhost)
        let authHost: String

        /// Auth emulator port (default: 9099)
        let authPort: Int

        /// Computed Firestore base URL for REST API calls
        var firestoreBaseURL: String {
            "http://\(firestoreHost):\(firestorePort)/v1"
        }
    }
}

extension GoogleCloudPlatform.Configuration.Emulators {

    static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self? {
        let firestoreHostEnvName = "FIRESTORE_EMULATOR_HOST"
        let authHostEnvName = "FIREBASE_AUTH_EMULATOR_HOST"

        guard let firestoreHostEnv = environment[firestoreHostEnvName] else {
            return nil
        }

        guard let authHostEnv = environment[authHostEnvName] else {
            return nil
        }

        let (firestoreHost, firestorePort) = try parseHostPort(
            value: firestoreHostEnv,
            envVar: firestoreHostEnvName
        )

        let (authHost, authPort) = try parseHostPort(
            value: authHostEnv,
            envVar: authHostEnvName
        )

        return .init(
            firestoreHost: firestoreHost,
            firestorePort: firestorePort,
            authHost: authHost,
            authPort: authPort
        )
    }

    private static func parseHostPort(value: String, envVar: String) throws -> (String, Int) {
        var cleanValue = value
        if cleanValue.hasPrefix("http://") {
            cleanValue = String(cleanValue.dropFirst(7))
        } else if cleanValue.hasPrefix("https://") {
            cleanValue = String(cleanValue.dropFirst(8))
        }

        let components = cleanValue.split(separator: ":", maxSplits: 1)

        guard components.count == 2 else {
            throw EmulatorError.invalidHostFormat(envVar: envVar, value: value)
        }

        let host = String(components[0])
        guard !host.isEmpty else {
            throw EmulatorError.invalidHostFormat(envVar: envVar, value: value)
        }

        guard let port = Int(components[1]), port > 0, port <= 65535 else {
            throw EmulatorError.invalidHostFormat(envVar: envVar, value: value)
        }

        return (host, port)
    }

}

// MARK: - Errors

extension GoogleCloudPlatform {

    enum ConfigurationError: Error, LocalizedError {
        case missingProjectID
        case missingServiceURL
        case missingServiceAccount
        case missingCredentials
        case credentialsFileNotFound(path: String)
        case credentialsDecodingError(underlying: any Error)

        var errorDescription: String? {
            switch self {
            case .missingProjectID:
                return "GCP_PROJECT_ID or GOOGLE_CLOUD_PROJECT environment variable is required"
            case .missingServiceURL:
                return "GCP_CLOUD_RUN_SERVICE_URL environment variable is required (optional only in the Firebase emulator environment)"
            case .missingServiceAccount:
                return "GCP_SERVICE_ACCOUNT_EMAIL environment variable is required for local development"
            case .missingCredentials:
                return "GOOGLE_APPLICATION_CREDENTIALS (or the deprecated GCP_SERVICE_ACCOUNT_JSON_PATH) environment variable is required for local development"
            case .credentialsFileNotFound(let path):
                return "Service account credentials file not found at path: \(path)"
            case .credentialsDecodingError(let underlying):
                return "Failed to decode service account credentials: \(underlying.localizedDescription)"
            }
        }
    }

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
}

// MARK: - Emulator Verification

extension GoogleCloudPlatform {

    func verify(
        client: any Client,
        logger: Logger,
    ) async throws {
        if case .emulator(let config) = config.environment {
            let healthCheck = EmulatorHealthCheck(
                config: config,
                client: client,
                logger: logger
            )

            do {
                try await healthCheck.verify()
            } catch {
                logger.error("Firebase Emulator health check failed", metadata: [
                    "error": .string(error.localizedDescription)
                ])
                throw error
            }
        }
    }

}

// MARK: - Auth Provider

extension GoogleCloudPlatform.Environment {

    /// The `GoogleAuth` credential source for this environment, or `nil` for the
    /// emulator (which uses `EmulatorAuthProvider`). Pure: builds nothing.
    var authCredentialSource: GoogleAuthCredentialSource? {
        switch self {
        case .emulator:
            return nil
        case .cloudRun:
            return .applicationDefault
        case .standalone(let key):
            // Explicit key, never ADC: a developer's gcloud login must not be
            // picked up silently in place of the configured service account.
            return .serviceAccountKey(key.keyJSON)
        }
    }
}

extension GoogleCloudPlatform.Configuration {

    /// Builds the auth provider for this environment. Call **once**, at startup:
    /// a `GoogleAuthProvider` starts a background token-refresh loop.
    ///
    /// - Throws: `GoogleAuth.CredentialsError` if the credentials cannot be loaded.
    func makeAuthProvider(logger: Logger) throws -> any GCPAuthProvider {
        if case .standalone(let key) = environment, key.pathVariable.isDeprecated {
            logger.warning(
                "\(key.pathVariable.rawValue) is deprecated; set GOOGLE_APPLICATION_CREDENTIALS instead",
                metadata: ["path": .string(key.path)]
            )
        }

        guard let source = environment.authCredentialSource else {
            logger.info("Using EmulatorAuthProvider (Firebase Emulator environment detected)")
            return EmulatorAuthProvider()
        }

        switch source {
        case .applicationDefault:
            logger.info("Using GoogleAuthProvider with Application Default Credentials (Cloud Run environment detected)")
        case .serviceAccountKey:
            logger.info("Using GoogleAuthProvider with a service-account key (standalone environment)")
        }
        return try GoogleAuthProvider(credentialSource: source)
    }
}

// MARK: - Vapor Application Storage

extension GoogleCloudPlatform {
    struct StorageKey: Vapor.StorageKey {
        typealias Value = GoogleCloudPlatform
    }
}

extension Application {
    var gcp: GoogleCloudPlatform {
        set { storage[GoogleCloudPlatform.StorageKey.self] = newValue }
        get {
            guard let config = storage[GoogleCloudPlatform.StorageKey.self] else {
                fatalError("GCPConfiguration not configured. Please configure it in your application setup.")
            }
            return config
        }
    }
}

// MARK: - Vapor Environment Detection

extension Environment {

    static var isRunningInCloudRun: Bool {
        isRunningInCloudRun(in: ProcessInfo.processInfo.environment)
    }

    static func isRunningInCloudRun(in environment: [String: String]) -> Bool {
        environment["K_SERVICE"] != nil
    }

    static var gcpProjectId: String {
        get throws {
            try gcpProjectId(in: ProcessInfo.processInfo.environment)
        }
    }

    static func gcpProjectId(in environment: [String: String]) throws -> String {
        guard let projectId = environment["GCP_PROJECT_ID"] ?? environment["GOOGLE_CLOUD_PROJECT"] else {
            throw GoogleCloudPlatform.ConfigurationError.missingProjectID
        }
        return projectId
    }

    static var gcpThisServiceURL: String {
        get throws {
            try gcpThisServiceURL(in: ProcessInfo.processInfo.environment)
        }
    }

    static func gcpThisServiceURL(in environment: [String: String]) throws -> String {
        guard let serviceURL = environment["GCP_CLOUD_RUN_SERVICE_URL"] else {
            throw GoogleCloudPlatform.ConfigurationError.missingServiceURL
        }
        return serviceURL
    }

    static var gcpServiceAccountEmail: String {
        get throws {
            if let email = Environment.get("GCP_SERVICE_ACCOUNT_EMAIL") {
                return email
            }
            // TODO: it could be "{SOME_NAME}@\(try gcpProjectId).iam.gserviceaccount.com"
            // Fallback to the App Engine default service account for the project.
            return "\(try gcpProjectId)@appspot.gserviceaccount.com"
        }
    }

    // MARK: Cloud Tasks

    static var gcpCloudTasksURL: String {
        Environment.get("GCP_CLOUD_TASKS_URL") ?? GCPCloudTasksClient.defaultBaseURL
    }

    static var gcpCloudTasksLocation: String {
        Environment.get("GCP_CLOUD_TASKS_LOCATION") ?? "us-central1"
    }

    static var gcpCloudTasksQueueName: String {
        Environment.get("GCP_CLOUD_TASKS_QUEUE_NAME") ?? "default"
    }

    // MARK: Pub/Sub

    static var gcpPubSubURL: String {
        Environment.get("GCP_PUBSUB_URL") ?? GCPPubSubClient.defaultBaseURL
    }

    static var gcpPubSubTopicName: String {
        Environment.get("GCP_PUBSUB_TOPIC_NAME") ?? "default"
    }

    // MARK: Build Info

    static var buildBranchName: String {
        Environment.get("BUILD_BRANCH_NAME") ?? "local"
    }

    static var buildShortSha: String {
        Environment.get("BUILD_SHORT_SHA") ?? ""
    }

    static var buildTriggeredBy: String {
        let branch = buildBranchName
        let sha = buildShortSha
        return sha.isEmpty ? branch : "\(branch)-\(sha)"
    }

    /// Human-readable build info shared by `GET /version` and
    /// `GET /api/v1/version`: `v<version>+<build>, revision: <K_REVISION>`.
    static var buildInfo: String {
        buildInfo(in: ProcessInfo.processInfo.environment)
    }

    static func buildInfo(in environment: [String: String]) -> String {
        let branch = environment["BUILD_BRANCH_NAME"] ?? "local"
        let sha = environment["BUILD_SHORT_SHA"] ?? ""
        let build = sha.isEmpty ? branch : "\(branch)-\(sha)"
        let revision = environment["K_REVISION"] ?? "unknown"
        return "v0.0.1+\(build), revision: \(revision)"
    }
}
