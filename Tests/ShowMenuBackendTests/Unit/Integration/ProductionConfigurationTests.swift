import Testing
import Logging
import Vapor
@testable import ShowMenuBackend

@Suite("Production boot configuration")
struct ProductionConfigurationTests {

    // MARK: - Database

    @Test("production without database config throws")
    func productionNoDatabase() {
        #expect(throws: StoreConfigurationError.self) {
            try FluentDriver.resolve(values: [:], environment: .production)
        }
    }

    @Test("production with empty database config throws")
    func productionEmptyDatabase() {
        #expect(throws: StoreConfigurationError.self) {
            try FluentDriver.resolve(values: ["DATABASE_URL": "", "DATABASE_HOST": ""], environment: .production)
        }
    }

    @Test("production with DATABASE_URL resolves to postgres")
    func productionWithURL() throws {
        let driver = try FluentDriver.resolve(
            values: ["DATABASE_URL": "postgres://u:p@localhost:5432/db"],
            environment: .production
        )
        guard case .postgres = driver else {
            Issue.record("expected postgres")
            return
        }
    }

    @Test("development and testing with no env resolve to SQLite", arguments: [Vapor.Environment.development, .testing])
    func nonProductionFallsBack(environment: Vapor.Environment) throws {
        let driver = try FluentDriver.resolve(values: [:], environment: environment)
        guard case .sqliteInMemory = driver else {
            Issue.record("expected sqliteInMemory")
            return
        }
    }

    // MARK: - Signing keys

    @Test("production without JWKS throws")
    func productionNoJWKS() {
        #expect(throws: PassageConfigurationError.self) {
            try resolvePassageJWT(values: [:], logger: Logger(label: "test"), environment: .production)
        }
    }

    @Test("development and testing with no env use an ephemeral key", arguments: [Vapor.Environment.development, .testing])
    func nonProductionEphemeralKey(environment: Vapor.Environment) throws {
        _ = try resolvePassageJWT(values: [:], logger: Logger(label: "test"), environment: environment)
    }
}
