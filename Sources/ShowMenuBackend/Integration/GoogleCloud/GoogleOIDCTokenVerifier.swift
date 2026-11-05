import Foundation
import JWT
import Vapor

/// Claims of a Google-signed OIDC identity token (RS256 JWT from
/// `accounts.google.com`). `email` is the calling service account.
struct GoogleOIDCToken: JWTPayload {
    let iss: IssuerClaim
    let aud: AudienceClaim
    let exp: ExpirationClaim
    let email: String?
    let emailVerified: Bool?

    enum CodingKeys: String, CodingKey {
        case iss, aud, exp, email
        case emailVerified = "email_verified"
    }

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}

enum GoogleOIDCError: Error, LocalizedError, Equatable {
    case malformedToken
    case unknownKeyID(String)
    case invalidIssuer(String)
    case serviceAccountNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case .malformedToken:
            return "Malformed OIDC token (expected RS256 with a key id)"
        case .unknownKeyID(let kid):
            return "OIDC token signed with unknown key id '\(kid)'"
        case .invalidIssuer(let issuer):
            return "Unexpected OIDC token issuer '\(issuer)'"
        case .serviceAccountNotAllowed(let email):
            return "Service account '\(email)' is not allowed to call this endpoint"
        }
    }
}

/// Verifies Google-signed OIDC identity tokens (how the `auth-forwarder` Cloud
/// Function and Cloud Scheduler authenticate to Cloud Run) against Google's
/// OAuth2 JWKS, then validates issuer, audience and — when configured — the
/// calling service account's email.
///
/// Reuses the S03 JWKS machinery: RS256 + `kid` pinning
/// (`FirebaseTokenVerifier.requireRS256WithKid`), the shared `JWKSKeyCache`
/// (cache by `max-age`, coalesced refresh, stale-on-failure, 503 on outage), and
/// the unknown-`kid` check that jwt-kit would otherwise paper over.
actor GoogleOIDCTokenVerifier {

    static let jwksURL = "https://www.googleapis.com/oauth2/v3/certs"
    static let validIssuers: Set<String> = ["https://accounts.google.com", "accounts.google.com"]

    private let audience: String
    private let allowedEmails: Set<String>
    private let jwks: JWKSKeyCache

    init(
        audience: String,
        allowedEmails: Set<String> = [],
        fetcher: @escaping JWKSFetcher,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger
    ) {
        self.audience = audience
        self.allowedEmails = allowedEmails
        self.jwks = JWKSKeyCache(name: "Google OIDC", fetcher: fetcher, now: now, logger: logger)
    }

    /// Production wiring: fetch Google's JWKS through the Vapor client.
    init(
        audience: String,
        allowedEmails: Set<String> = [],
        client: any Client,
        logger: Logger
    ) {
        self.init(
            audience: audience,
            allowedEmails: allowedEmails,
            fetcher: JWKSKeyCache.clientFetcher(client: client, url: GoogleOIDCTokenVerifier.jwksURL),
            logger: logger
        )
    }

    @discardableResult
    func verify(_ token: String) async throws -> GoogleOIDCToken {
        let kid: String
        do {
            kid = try FirebaseTokenVerifier.requireRS256WithKid(token)
        } catch {
            throw GoogleOIDCError.malformedToken
        }
        let keySet = try await jwks.keySet()
        guard keySet.kids.contains(kid) else {
            throw GoogleOIDCError.unknownKeyID(kid)
        }
        let payload = try await keySet.collection.verify(token, as: GoogleOIDCToken.self)

        guard Self.validIssuers.contains(payload.iss.value) else {
            throw GoogleOIDCError.invalidIssuer(payload.iss.value)
        }
        try payload.aud.verifyIntendedAudience(includes: audience)

        if !allowedEmails.isEmpty {
            guard let email = payload.email, allowedEmails.contains(email) else {
                throw GoogleOIDCError.serviceAccountNotAllowed(payload.email ?? "nil")
            }
        }
        return payload
    }
}
