import Foundation
import GoogleAuth

// MARK: - Test seam

/// The one capability `GoogleAuthProvider` needs from `GoogleAuth.Credentials`:
/// producing the request headers that authenticate a GCP API call.
///
/// `Credentials` cannot be stubbed from outside its module (its injectable
/// initializer is `internal`), so the provider depends on this protocol instead
/// and tests supply a scripted conformer.
protocol GoogleAuthHeadersSource: Sendable {
    func headers() async throws -> AuthHeaders
}

extension Credentials: GoogleAuthHeadersSource {}

// MARK: - Credential source

/// Where `GoogleAuthProvider` obtains its credentials, mapped to a
/// `GoogleAuth.CredentialsConfiguration` that always requests
/// `GoogleAuthProvider.scopes` (non-empty scopes yield an OAuth2 access token,
/// not a self-signed JWT).
enum GoogleAuthCredentialSource: Sendable {
    /// Application Default Credentials. Used on Cloud Run, where ADC falls
    /// through to the metadata server (`metadata.google.internal`, overridable
    /// via `GCE_METADATA_HOST`).
    case applicationDefault

    /// An explicit service-account JSON key (the bytes of the key file). Used in
    /// standalone mode. Deliberately NOT routed through ADC, so a developer's
    /// `gcloud auth application-default login` can never silently be picked up
    /// in place of the configured service account.
    case serviceAccountKey(Data)

    /// The `GoogleAuth` configuration for this source, requesting `scopes`.
    func configuration(
        scopes: [String] = GoogleAuthProvider.scopes
    ) -> CredentialsConfiguration {
        switch self {
        case .applicationDefault:
            return .adc(scopes: scopes)
        case .serviceAccountKey(let keyJSON):
            return .serviceAccount(keyJSON: keyJSON, accessSpecifier: .scopes(scopes))
        }
    }
}

// MARK: - Provider

/// `GCPAuthProvider` backed by Google's `swift-google-auth` (`GoogleAuth`).
///
/// **Token extraction.** `GoogleAuth` exposes no public raw-token accessor — only
/// `Credentials.headers()`, which returns `Authorization: Bearer <token>` (plus,
/// possibly, `x-goog-user-project`). The access token is therefore parsed out of
/// the `Authorization` header.
///
/// **Caching / refresh is the library's job.** `Credentials` caches the token in
/// memory and refreshes it proactively in a background loop, so this type holds
/// no cache of its own. Construct it **once** (the app's `Resolver` caches the
/// provider by keypath): `Credentials.init` does synchronous file I/O for ADC and
/// starts the refresh loop, so it must never be built per call.
struct GoogleAuthProvider: GCPAuthProvider {
    /// OAuth2 scopes requested for every access token.
    ///
    /// - `cloud-platform` covers Firestore (datastore), Pub/Sub, Cloud Tasks and
    ///   IAM, which the previous hand-written providers requested individually.
    /// - `identitytoolkit` is kept because the Cloud Run custom-token minting path
    ///   talks to Identity Toolkit and the previous Cloud Run provider requested
    ///   it. The union is harmless: scopes only restrict a token, and the service
    ///   account's IAM roles remain the real authority.
    static let scopes: [String] = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/identitytoolkit",
    ]

    private let source: any GoogleAuthHeadersSource

    /// Wraps an existing headers source (a `Credentials`, or a test stub).
    init(headersSource: any GoogleAuthHeadersSource) {
        self.source = headersSource
    }

    /// Builds a real `GoogleAuth.Credentials` for `credentialSource`, requesting
    /// `GoogleAuthProvider.scopes`.
    ///
    /// - Throws: `GoogleAuth.CredentialsError` if the credentials cannot be
    ///   loaded or parsed (e.g. a malformed service-account key).
    init(credentialSource: GoogleAuthCredentialSource) throws {
        let credentials = try Credentials(configuration: credentialSource.configuration())
        self.init(headersSource: credentials)
    }

    /// Returns the current OAuth2 access token. Never returns `nil`.
    ///
    /// - Throws: Errors from `Credentials.headers()` unchanged; otherwise a
    ///   `GoogleAuthProviderError` when the `Authorization` header is missing,
    ///   empty, or not a `Bearer` credential.
    func getAccessToken() async throws -> String? {
        let headers = try await source.headers()
        return try Self.bearerToken(from: headers)
    }

    /// Extracts the token from a `Bearer` `Authorization` header (header name and
    /// scheme matched case-insensitively).
    static func bearerToken(from headers: AuthHeaders) throws -> String {
        guard let authorization = headers["Authorization"]?
            .trimmingCharacters(in: .whitespaces), !authorization.isEmpty
        else {
            throw GoogleAuthProviderError.missingAuthorizationHeader
        }

        let parts = authorization.split(separator: " ", maxSplits: 1)
        let scheme = parts.first.map(String.init) ?? ""
        guard scheme.lowercased() == "bearer" else {
            throw GoogleAuthProviderError.unsupportedAuthorizationScheme(scheme)
        }

        let token = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces)
            : ""
        guard !token.isEmpty else {
            throw GoogleAuthProviderError.missingAuthorizationHeader
        }
        return token
    }
}

/// Failures specific to reading a token out of `GoogleAuth`'s headers.
enum GoogleAuthProviderError: Error, LocalizedError, Equatable {
    /// `Credentials.headers()` returned no usable `Authorization` header
    /// (absent, empty, or a scheme with no token).
    case missingAuthorizationHeader
    /// The `Authorization` header used a scheme other than `Bearer`.
    case unsupportedAuthorizationScheme(String)

    var errorDescription: String? {
        switch self {
        case .missingAuthorizationHeader:
            return "Google credentials returned no Bearer access token in the Authorization header"
        case .unsupportedAuthorizationScheme(let scheme):
            return "Google credentials returned an unsupported Authorization scheme '\(scheme)'; expected 'Bearer'"
        }
    }
}
