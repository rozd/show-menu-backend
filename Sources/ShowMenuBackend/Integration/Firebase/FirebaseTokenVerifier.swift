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

    private let projectID: String
    private let acceptsUnsignedTokens: Bool
    private let jwks: JWKSKeyCache
    private let now: @Sendable () -> Date

    init(
        projectID: String,
        acceptsUnsignedTokens: Bool,
        fetcher: @escaping JWKSFetcher,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger
    ) {
        self.projectID = projectID
        self.acceptsUnsignedTokens = acceptsUnsignedTokens
        self.jwks = JWKSKeyCache(name: "Firebase", fetcher: fetcher, now: now, logger: logger)
        self.now = now
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
            fetcher: JWKSKeyCache.clientFetcher(client: client, url: FirebaseTokenVerifier.jwksURL),
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
            let keySet = try await jwks.keySet()
            guard keySet.kids.contains(kid) else {
                throw FirebaseAuthError.unknownKeyID(kid)
            }
            payload = try await keySet.collection.verify(token, as: FirebaseIDToken.self)
        }
        try payload.validate(projectID: projectID, now: now())
        return payload
    }

    /// Cache lifetime from the JWKS response's Cache-Control (see `JWKSKeyCache`).
    static func maxAge(from headers: HTTPHeaders) -> TimeInterval {
        JWKSKeyCache.maxAge(from: headers)
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
