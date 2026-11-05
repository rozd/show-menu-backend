import Foundation
import JWT
import Vapor

/// Fetches the raw JWKS document. Injectable so tests never touch the network.
typealias JWKSFetcher = @Sendable () async throws -> (body: Data, headers: HTTPHeaders)

/// The signing keys could not be obtained (network, non-2xx, undecodable body)
/// and none are cached. This is an *infrastructure* failure, not a bad token:
/// it surfaces as 503 through the error envelope instead of 401.
struct FirebaseJWKSUnavailableError: Error, AbortError, CustomStringConvertible {
    let underlying: String
    var status: HTTPResponseStatus { .serviceUnavailable }
    var reason: String { "Authentication service temporarily unavailable" }
    var description: String { "Firebase JWKS unavailable: \(underlying)" }
}

/// Verifies Firebase Auth ID tokens.
///
/// Production path: RS256 signature against Google's JWKS for the
/// `securetoken` service account (keys cached per `max-age`, clamped to
/// [60 s, 24 h], concurrent refreshes coalesced, stale keys served if a refresh
/// fails), then issuer/audience/subject/`iat`/`auth_time` validation.
///
/// Emulator path: the Firebase Auth emulator issues *unsigned* tokens
/// (`alg: "none"`), so when the backend runs against emulators the payload
/// is decoded without signature verification — same policy as Firebase's
/// Admin SDKs. `iss`, `aud`, `exp` and `sub` are still checked (D5).
actor FirebaseTokenVerifier {

    static let jwksURL = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"
    static let minCacheAge: TimeInterval = 60
    static let maxCacheAge: TimeInterval = 24 * 3600
    /// How long stale keys are reused before retrying after a failed refresh.
    static let staleRetryInterval: TimeInterval = 60

    private let projectID: String
    private let acceptsUnsignedTokens: Bool
    private let fetcher: JWKSFetcher
    private let now: @Sendable () -> Date
    private let logger: Logger

    /// A fetched JWKS: the verifier collection plus the key ids it contains
    /// (jwt-kit falls back to a default signer on an unknown `kid`; we don't).
    private struct KeySet: Sendable {
        let collection: JWTKeyCollection
        let kids: Set<String>
    }

    private var keys: KeySet?
    private var keysExpireAt: Date = .distantPast
    private var inflight: Task<KeySet, any Error>?

    init(
        projectID: String,
        acceptsUnsignedTokens: Bool,
        fetcher: @escaping JWKSFetcher,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger
    ) {
        self.projectID = projectID
        self.acceptsUnsignedTokens = acceptsUnsignedTokens
        self.fetcher = fetcher
        self.now = now
        self.logger = logger
    }

    /// Production wiring: fetch Google's JWKS through the Vapor client.
    init(
        projectID: String,
        acceptsUnsignedTokens: Bool,
        client: any Client,
        logger: Logger
    ) {
        self.init(
            projectID: projectID,
            acceptsUnsignedTokens: acceptsUnsignedTokens,
            fetcher: {
                let response = try await client.get(URI(string: FirebaseTokenVerifier.jwksURL))
                guard (200..<300).contains(Int(response.status.code)) else {
                    throw FirebaseJWKSUnavailableError(underlying: "HTTP \(response.status.code)")
                }
                guard var body = response.body, let data = body.readData(length: body.readableBytes) else {
                    throw FirebaseJWKSUnavailableError(underlying: "empty body")
                }
                return (data, response.headers)
            },
            logger: logger
        )
    }

    func verify(_ token: String) async throws -> FirebaseIDToken {
        let payload: FirebaseIDToken
        if acceptsUnsignedTokens {
            payload = try Self.decodeUnverified(token)
            try payload.exp.verifyNotExpired()
        } else {
            let kid = try Self.requireRS256WithKid(token)
            let keySet = try await keyCollection()
            guard keySet.kids.contains(kid) else {
                throw FirebaseAuthError.unknownKeyID(kid)
            }
            payload = try await keySet.collection.verify(token, as: FirebaseIDToken.self)
        }
        try payload.validate(projectID: projectID, now: now())
        return payload
    }

    // MARK: - JWKS

    private func keyCollection() async throws -> KeySet {
        if let keys, keysExpireAt > now() {
            return keys
        }
        // Coalesce: every concurrent caller awaits the same refresh.
        if let inflight {
            return try await inflight.value
        }
        let task = Task { try await self.refreshKeys() }
        inflight = task
        return try await task.value
    }

    /// Runs on the actor; always clears `inflight`. On failure, serves the stale
    /// collection when there is one (and delays the next attempt).
    private func refreshKeys() async throws -> KeySet {
        defer { inflight = nil }
        do {
            logger.info("Fetching Firebase JWKS")
            let (data, headers) = try await fetcher()
            let jwks: JWKS
            do {
                jwks = try JSONDecoder().decode(JWKS.self, from: data)
            } catch {
                throw FirebaseJWKSUnavailableError(underlying: "undecodable JWKS: \(error)")
            }
            let collection = JWTKeyCollection()
            try await collection.add(jwks: jwks)
            let keySet = KeySet(collection: collection, kids: Set(jwks.keys.compactMap { $0.keyIdentifier?.string }))
            keys = keySet
            keysExpireAt = now() + Self.maxAge(from: headers)
            return keySet
        } catch {
            if let stale = keys {
                logger.warning("JWKS refresh failed, serving stale keys", metadata: [
                    "error": .string(String(describing: error))
                ])
                keysExpireAt = now() + Self.staleRetryInterval
                return stale
            }
            if error is FirebaseJWKSUnavailableError { throw error }
            throw FirebaseJWKSUnavailableError(underlying: String(describing: error))
        }
    }

    /// Cache lifetime from the JWKS response's Cache-Control, default 1 hour,
    /// clamped to [`minCacheAge`, `maxCacheAge`].
    static func maxAge(from headers: HTTPHeaders) -> TimeInterval {
        guard
            let cacheControl = headers.first(name: .cacheControl),
            let match = cacheControl.firstMatch(of: /max-age=(\d+)/),
            let seconds = TimeInterval(match.1)
        else {
            return 3600
        }
        return min(max(seconds, minCacheAge), maxCacheAge)
    }

    // MARK: - Token shape

    /// The signed path only ever accepts RS256 tokens that name a key (`kid`):
    /// rejects `alg: none` and algorithm-confusion (HS256 with the public key as
    /// the secret) before any key lookup.
    @discardableResult
    static func requireRS256WithKid(_ token: String) throws -> String {
        struct Header: Decodable { let alg: String?; let kid: String? }
        guard
            let first = token.split(separator: ".", omittingEmptySubsequences: false).first,
            let data = Data(base64URLEncoded: String(first)),
            let header = try? JSONDecoder().decode(Header.self, from: data),
            header.alg == "RS256",
            let kid = header.kid, !kid.isEmpty
        else {
            throw FirebaseAuthError.malformedToken
        }
        return kid
    }

    // MARK: - Emulator Tokens

    /// Decodes a JWT payload without verifying its signature.
    /// Only used for Firebase Auth emulator tokens.
    static func decodeUnverified(_ token: String) throws -> FirebaseIDToken {
        let segments = token.split(separator: ".")
        guard segments.count >= 2, let payload = Data(base64URLEncoded: String(segments[1])) else {
            throw FirebaseAuthError.malformedToken
        }
        do {
            // JWT dates are seconds since the Unix epoch; Foundation's default
            // would read them relative to 2001-01-01 (+31 years).
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(FirebaseIDToken.self, from: payload)
        } catch {
            throw FirebaseAuthError.malformedToken
        }
    }
}

// MARK: - Helpers

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        self.init(base64Encoded: base64)
    }
}
