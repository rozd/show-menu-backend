import Foundation
import GoogleAuth
import Testing
@testable import ShowMenuBackend

@Suite("GoogleAuthProvider")
struct GoogleAuthProviderTests {

    // MARK: - Test doubles

    private struct StubHeadersSource: GoogleAuthHeadersSource {
        let result: Result<AuthHeaders, any Error>

        func headers() async throws -> AuthHeaders {
            try result.get()
        }
    }

    private struct SentinelError: Error, Equatable {}

    private func makeSUT(headers: AuthHeaders) -> GoogleAuthProvider {
        GoogleAuthProvider(headersSource: StubHeadersSource(result: .success(headers)))
    }

    private func makeSUT(error: any Error) -> GoogleAuthProvider {
        GoogleAuthProvider(headersSource: StubHeadersSource(result: .failure(error)))
    }

    // MARK: - Token extraction

    @Test("returns the token from 'Authorization: Bearer <token>'")
    func bearerToken() async throws {
        let sut = makeSUT(headers: [(name: "Authorization", value: "Bearer abc")])
        #expect(try await sut.getAccessToken() == "abc")
    }

    @Test(
        "matches the header name and Bearer scheme case-insensitively",
        arguments: [
            ("Authorization", "bearer abc"),
            ("authorization", "Bearer abc"),
            ("AUTHORIZATION", "BEARER abc"),
        ]
    )
    func caseInsensitive(name: String, value: String) async throws {
        let sut = makeSUT(headers: [(name: name, value: value)])
        #expect(try await sut.getAccessToken() == "abc")
    }

    @Test("ignores an extra x-goog-user-project header")
    func ignoresQuotaProjectHeader() async throws {
        let sut = makeSUT(headers: [
            (name: "x-goog-user-project", value: "billing-project"),
            (name: "Authorization", value: "Bearer abc"),
        ])
        #expect(try await sut.getAccessToken() == "abc")
    }

    @Test("throws missingAuthorizationHeader when there is no Authorization header")
    func missingHeader() async {
        let sut = makeSUT(headers: [(name: "x-goog-user-project", value: "p")])
        await #expect(throws: GoogleAuthProviderError.missingAuthorizationHeader) {
            try await sut.getAccessToken()
        }
    }

    @Test("throws missingAuthorizationHeader for an empty header or a token-less Bearer",
          arguments: ["", "   ", "Bearer", "Bearer   "])
    func emptyHeaderOrToken(value: String) async {
        let sut = makeSUT(headers: [(name: "Authorization", value: value)])
        await #expect(throws: GoogleAuthProviderError.missingAuthorizationHeader) {
            try await sut.getAccessToken()
        }
    }

    @Test("throws unsupportedAuthorizationScheme for a non-Bearer scheme")
    func nonBearerScheme() async {
        let sut = makeSUT(headers: [(name: "Authorization", value: "Basic dXNlcjpwYXNz")])
        await #expect(throws: GoogleAuthProviderError.unsupportedAuthorizationScheme("Basic")) {
            try await sut.getAccessToken()
        }
    }

    @Test("propagates an error thrown by headers() unchanged")
    func propagatesSourceError() async {
        let sut = makeSUT(error: SentinelError())
        await #expect(throws: SentinelError()) {
            try await sut.getAccessToken()
        }
    }

    // MARK: - Scopes

    @Test("scope set is exactly cloud-platform + identitytoolkit")
    func scopeSet() {
        #expect(GoogleAuthProvider.scopes.contains("https://www.googleapis.com/auth/cloud-platform"))
        #expect(GoogleAuthProvider.scopes.contains("https://www.googleapis.com/auth/identitytoolkit"))
        #expect(GoogleAuthProvider.scopes.count == 2)
    }

    // MARK: - Credential source → configuration

    @Test(".applicationDefault maps to .adc with the provider's scopes")
    func applicationDefaultMapping() throws {
        let config = GoogleAuthCredentialSource.applicationDefault.configuration()
        guard case let .adc(quotaProjectID, universeDomain, scopes) = config else {
            Issue.record("expected .adc, got \(config)")
            return
        }
        #expect(scopes == GoogleAuthProvider.scopes)
        #expect(quotaProjectID == nil)
        #expect(universeDomain == nil)
    }

    @Test(".serviceAccountKey maps to .serviceAccount with the key bytes and scopes")
    func serviceAccountMapping() throws {
        let key = Data(#"{"type":"service_account","client_email":"x@y.iam.gserviceaccount.com"}"#.utf8)
        let config = GoogleAuthCredentialSource.serviceAccountKey(key).configuration()
        guard case let .serviceAccount(keyJSON, quotaProjectID, universeDomain, accessSpecifier) = config else {
            Issue.record("expected .serviceAccount, got \(config)")
            return
        }
        #expect(keyJSON == key)
        #expect(accessSpecifier == .scopes(GoogleAuthProvider.scopes))
        #expect(quotaProjectID == nil)
        #expect(universeDomain == nil)
    }
}
