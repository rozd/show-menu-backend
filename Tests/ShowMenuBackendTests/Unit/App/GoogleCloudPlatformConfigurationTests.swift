import Foundation
import GoogleAuth
import Logging
import Testing
@testable import ShowMenuBackend

/// Environment detection and auth-source selection for `Vapor+GCP.swift`.
///
/// Every test passes a literal environment dictionary — never `setenv` — because
/// Swift Testing runs suites in parallel and process env is shared. No test
/// successfully constructs `GoogleAuth.Credentials` (that starts a background
/// refresh loop that could hit the network or a developer's real credentials);
/// non-emulator cases assert on the pure `authCredentialSource` mapping, except
/// the startup-failure test, whose key is rejected before any loop starts.
@Suite("GoogleCloudPlatform.Configuration.fromEnvironment")
struct GoogleCloudPlatformConfigurationTests {

    typealias Configuration = GoogleCloudPlatform.Configuration
    typealias ConfigurationError = GoogleCloudPlatform.ConfigurationError

    /// Vars every successful detection needs, regardless of environment.
    static let required: [String: String] = [
        "GCP_PROJECT_ID": "demo-project",
        "GCP_CLOUD_RUN_SERVICE_URL": "http://localhost:8080",
    ]

    /// Syntactically valid service-account JSON with fake values. Detection only
    /// decodes the fields; the "private key" is deliberately NOT a valid RSA key,
    /// so handing it to GoogleAuth fails (see `invalidPrivateKeyFailsAtStartup`).
    static let fakeKeyJSON = Data("""
    {
      "type": "service_account",
      "project_id": "demo-project",
      "private_key_id": "fake-key-id",
      "private_key": "-----BEGIN PRIVATE KEY-----\\nZmFrZQ==\\n-----END PRIVATE KEY-----\\n",
      "client_email": "fake@demo-project.iam.gserviceaccount.com",
      "client_id": "1234567890"
    }
    """.utf8)

    /// Writes `contents` to a unique temp file and returns its path.
    func makeTempFile(_ contents: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gcp-config-test-\(UUID().uuidString).json")
        try contents.write(to: url)
        return url.path
    }

    func removeFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    func env(_ extra: [String: String]) -> [String: String] {
        Self.required.merging(extra) { _, new in new }
    }

    // MARK: - Emulator

    @Test("both emulator vars select the emulator, with no GoogleAuth source")
    func emulator() throws {
        let config = try Configuration.fromEnvironment(environment: env([
            "FIRESTORE_EMULATOR_HOST": "localhost:9002",
            "FIREBASE_AUTH_EMULATOR_HOST": "localhost:9099",
        ]))

        guard case .emulator(let emulators) = config.environment else {
            Issue.record("expected .emulator, got \(config.environment)")
            return
        }
        #expect(emulators.firestorePort == 9002)
        #expect(emulators.authPort == 9099)
        #expect(config.environment.authCredentialSource == nil)

        let provider = try config.makeAuthProvider(logger: Logger(label: "test"))
        #expect(provider is EmulatorAuthProvider)
    }

    @Test("emulator mode does not require GCP_CLOUD_RUN_SERVICE_URL; defaults to the local PORT")
    func emulatorServiceURLOptional() throws {
        let emulatorVars = [
            "GCP_PROJECT_ID": "demo-project",
            "FIRESTORE_EMULATOR_HOST": "localhost:9002",
            "FIREBASE_AUTH_EMULATOR_HOST": "localhost:9099",
        ]
        let defaulted = try Configuration.fromEnvironment(environment: emulatorVars)
        #expect(defaulted.thisServiceURL == "http://localhost:8080")

        let withPort = try Configuration.fromEnvironment(
            environment: emulatorVars.merging(["PORT": "9191"]) { _, new in new }
        )
        #expect(withPort.thisServiceURL == "http://localhost:9191")
    }

    @Test("outside the emulator a missing GCP_CLOUD_RUN_SERVICE_URL still throws, naming the right variable")
    func serviceURLRequiredOutsideEmulator() {
        let error = #expect(throws: ConfigurationError.self) {
            try Configuration.fromEnvironment(environment: [
                "GCP_PROJECT_ID": "demo-project", "K_SERVICE": "svc",
            ])
        }
        guard case .missingServiceURL = error else {
            Issue.record("expected .missingServiceURL, got \(String(describing: error))")
            return
        }
        #expect(error?.errorDescription?.contains("GCP_CLOUD_RUN_SERVICE_URL") == true)
    }

    @Test("emulator wins over K_SERVICE when both emulator vars are set")
    func emulatorWinsOverCloudRun() throws {
        let config = try Configuration.fromEnvironment(environment: env([
            "FIRESTORE_EMULATOR_HOST": "localhost:9002",
            "FIREBASE_AUTH_EMULATOR_HOST": "localhost:9099",
            "K_SERVICE": "backend",
        ]))
        #expect(config.environment.isEmulator)
    }

    // MARK: - Cloud Run

    @Test("one emulator var plus K_SERVICE selects Cloud Run → ADC")
    func cloudRun() throws {
        let config = try Configuration.fromEnvironment(environment: env([
            "FIRESTORE_EMULATOR_HOST": "localhost:9002",
            "K_SERVICE": "backend",
        ]))

        guard case .cloudRun = config.environment else {
            Issue.record("expected .cloudRun, got \(config.environment)")
            return
        }
        guard case .applicationDefault = config.environment.authCredentialSource else {
            Issue.record("expected .applicationDefault")
            return
        }
    }

    // MARK: - Standalone

    @Test("GOOGLE_APPLICATION_CREDENTIALS selects standalone → explicit key bytes")
    func standaloneViaGoogleApplicationCredentials() throws {
        let path = try makeTempFile(Self.fakeKeyJSON)
        defer { removeFile(path) }

        let config = try Configuration.fromEnvironment(environment: env([
            "GOOGLE_APPLICATION_CREDENTIALS": path,
        ]))

        guard case .standalone(let key) = config.environment else {
            Issue.record("expected .standalone, got \(config.environment)")
            return
        }
        #expect(key.pathVariable == .googleApplicationCredentials)
        #expect(key.pathVariable.isDeprecated == false)
        #expect(key.path == path)
        #expect(key.keyJSON == Self.fakeKeyJSON)

        guard case .serviceAccountKey(let bytes) = config.environment.authCredentialSource else {
            Issue.record("expected .serviceAccountKey")
            return
        }
        #expect(bytes == Self.fakeKeyJSON)
    }

    @Test("GCP_SERVICE_ACCOUNT_JSON_PATH is a deprecated fallback")
    func standaloneViaDeprecatedFallback() throws {
        let path = try makeTempFile(Self.fakeKeyJSON)
        defer { removeFile(path) }

        let config = try Configuration.fromEnvironment(environment: env([
            "GCP_SERVICE_ACCOUNT_JSON_PATH": path,
        ]))

        guard case .standalone(let key) = config.environment else {
            Issue.record("expected .standalone, got \(config.environment)")
            return
        }
        #expect(key.pathVariable == .serviceAccountJSONPath)
        #expect(key.pathVariable.isDeprecated)
        #expect(key.keyJSON == Self.fakeKeyJSON)

        guard case .serviceAccountKey(let bytes) = config.environment.authCredentialSource else {
            Issue.record("expected .serviceAccountKey")
            return
        }
        #expect(bytes == Self.fakeKeyJSON)
    }

    @Test("GOOGLE_APPLICATION_CREDENTIALS wins when both path vars are set")
    func googleApplicationCredentialsWins() throws {
        let gacJSON = Self.fakeKeyJSON
        let legacyJSON = Data(String(decoding: Self.fakeKeyJSON, as: UTF8.self)
            .replacingOccurrences(of: "fake-key-id", with: "legacy-key-id").utf8)
        let gacPath = try makeTempFile(gacJSON)
        let legacyPath = try makeTempFile(legacyJSON)
        defer {
            removeFile(gacPath)
            removeFile(legacyPath)
        }

        let config = try Configuration.fromEnvironment(environment: env([
            "GOOGLE_APPLICATION_CREDENTIALS": gacPath,
            "GCP_SERVICE_ACCOUNT_JSON_PATH": legacyPath,
        ]))

        guard case .standalone(let key) = config.environment else {
            Issue.record("expected .standalone, got \(config.environment)")
            return
        }
        #expect(key.pathVariable == .googleApplicationCredentials)
        #expect(key.path == gacPath)
        #expect(key.keyJSON == gacJSON)
    }

    @Test("neither path var set throws missingCredentials")
    func missingCredentials() throws {
        let error = #expect(throws: ConfigurationError.self) {
            try Configuration.fromEnvironment(environment: Self.required)
        }
        guard case .missingCredentials = error else {
            Issue.record("expected .missingCredentials, got \(String(describing: error))")
            return
        }
    }

    @Test("a nonexistent key path throws credentialsFileNotFound")
    func credentialsFileNotFound() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json").path

        let error = #expect(throws: ConfigurationError.self) {
            try Configuration.fromEnvironment(environment: env([
                "GOOGLE_APPLICATION_CREDENTIALS": path,
            ]))
        }
        guard case .credentialsFileNotFound(let reported) = error else {
            Issue.record("expected .credentialsFileNotFound, got \(String(describing: error))")
            return
        }
        #expect(reported == path)
    }

    @Test("malformed key JSON throws credentialsDecodingError")
    func credentialsDecodingError() throws {
        let path = try makeTempFile(Data("{ not json".utf8))
        defer { removeFile(path) }

        let error = #expect(throws: ConfigurationError.self) {
            try Configuration.fromEnvironment(environment: env([
                "GOOGLE_APPLICATION_CREDENTIALS": path,
            ]))
        }
        guard case .credentialsDecodingError = error else {
            Issue.record("expected .credentialsDecodingError, got \(String(describing: error))")
            return
        }
    }

    // MARK: - Startup guarantee

    /// Pins "bad credentials fail the boot, not the first request": the key file
    /// passes detection (valid service-account JSON), but its private key is not
    /// a valid RSA key, so building the provider inside
    /// `GoogleCloudPlatform.fromEnvironment` must throw. If provider creation
    /// moved back into the lazy `Resolver` closure, this would stop throwing.
    /// GoogleAuth parses the key eagerly in `Credentials.init` and throws before
    /// creating its token cache, so no refresh loop or network call happens.
    @Test("an invalid private key fails GoogleCloudPlatform.fromEnvironment at startup")
    func invalidPrivateKeyFailsAtStartup() throws {
        let path = try makeTempFile(Self.fakeKeyJSON)
        defer { removeFile(path) }
        let environment = env(["GOOGLE_APPLICATION_CREDENTIALS": path])

        // Detection alone accepts the file…
        _ = try Configuration.fromEnvironment(environment: environment)

        // …but the startup path, which builds the provider, rejects it.
        #expect(throws: CredentialsError.self) {
            try GoogleCloudPlatform.fromEnvironment(
                environment: environment,
                logger: Logger(label: "test")
            )
        }
    }
}
