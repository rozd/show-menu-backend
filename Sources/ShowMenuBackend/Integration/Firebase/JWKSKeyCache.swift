import Foundation
import JWT
import Vapor

/// A fetched JWKS: the verifier collection plus the key ids it contains
/// (jwt-kit falls back to a default signer on an unknown `kid`; we don't).
struct JWKSKeySet: Sendable {
    let collection: JWTKeyCollection
    let kids: Set<String>
}

/// Caches a remote JWKS: refreshed per the response's `Cache-Control: max-age`
/// (clamped to [60 s, 24 h]), concurrent refreshes coalesced into one in-flight
/// task, stale keys served (retry after 60 s) if a refresh fails, and
/// `FirebaseJWKSUnavailableError` (503) when there is nothing cached to fall back to.
///
/// Shared by `FirebaseTokenVerifier` (securetoken keys) and
/// `GoogleOIDCTokenVerifier` (Eventarc / Scheduler OIDC keys).
actor JWKSKeyCache {

    static let minCacheAge: TimeInterval = 60
    static let maxCacheAge: TimeInterval = 24 * 3600
    /// How long stale keys are reused before retrying after a failed refresh.
    static let staleRetryInterval: TimeInterval = 60

    private let name: String
    private let fetcher: JWKSFetcher
    private let now: @Sendable () -> Date
    private let logger: Logger

    private var keys: JWKSKeySet?
    private var keysExpireAt: Date = .distantPast
    private var inflight: Task<JWKSKeySet, any Error>?

    init(
        name: String,
        fetcher: @escaping JWKSFetcher,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger
    ) {
        self.name = name
        self.fetcher = fetcher
        self.now = now
        self.logger = logger
    }

    /// A fetcher that GETs `url` through the Vapor client.
    static func clientFetcher(client: any Client, url: String) -> JWKSFetcher {
        {
            let response = try await client.get(URI(string: url))
            guard (200..<300).contains(Int(response.status.code)) else {
                throw FirebaseJWKSUnavailableError(underlying: "HTTP \(response.status.code)")
            }
            guard var body = response.body, let data = body.readData(length: body.readableBytes) else {
                throw FirebaseJWKSUnavailableError(underlying: "empty body")
            }
            return (data, response.headers)
        }
    }

    func keySet() async throws -> JWKSKeySet {
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
    private func refreshKeys() async throws -> JWKSKeySet {
        defer { inflight = nil }
        do {
            logger.info("Fetching \(name) JWKS")
            let (data, headers) = try await fetcher()
            let jwks: JWKS
            do {
                jwks = try JSONDecoder().decode(JWKS.self, from: data)
            } catch {
                throw FirebaseJWKSUnavailableError(underlying: "undecodable JWKS: \(error)")
            }
            let collection = JWTKeyCollection()
            try await collection.add(jwks: jwks)
            let keySet = JWKSKeySet(collection: collection, kids: Set(jwks.keys.compactMap { $0.keyIdentifier?.string }))
            keys = keySet
            keysExpireAt = now() + Self.maxAge(from: headers)
            return keySet
        } catch {
            if let stale = keys {
                logger.warning("JWKS refresh failed, serving stale keys", metadata: [
                    "jwks": .string(name),
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
}
