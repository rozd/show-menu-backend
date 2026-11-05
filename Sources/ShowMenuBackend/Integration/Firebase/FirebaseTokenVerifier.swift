import Foundation
import JWT
import Vapor

/// Verifies Firebase Auth ID tokens.
///
/// Production path: RS256 signature against Google's JWKS for the
/// `securetoken` service account (cached per the response's `max-age`), then
/// issuer/audience validation for our project.
///
/// Emulator path: the Firebase Auth emulator issues *unsigned* tokens
/// (`alg: "none"`), so when the backend runs against emulators the payload
/// is decoded without signature verification — same policy as Firebase's
/// Admin SDKs. `iss`, `aud`, `exp` and `sub` are still checked (D5).
actor FirebaseTokenVerifier {

    static let jwksURL = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"

    private let projectID: String
    private let acceptsUnsignedTokens: Bool
    private let client: any Client
    private let logger: Logger

    private var keys: JWTKeyCollection?
    private var keysExpireAt: Date = .distantPast

    init(
        projectID: String,
        acceptsUnsignedTokens: Bool,
        client: any Client,
        logger: Logger
    ) {
        self.projectID = projectID
        self.acceptsUnsignedTokens = acceptsUnsignedTokens
        self.client = client
        self.logger = logger
    }

    /// Test hook: a verifier with a fixed key collection and no fetching.
    init(projectID: String, keys: JWTKeyCollection, logger: Logger) {
        self.projectID = projectID
        self.acceptsUnsignedTokens = false
        self.client = UnavailableClient()
        self.logger = logger
        self.keys = keys
        self.keysExpireAt = .distantFuture
    }

    func verify(_ token: String) async throws -> FirebaseIDToken {
        let payload: FirebaseIDToken
        if acceptsUnsignedTokens {
            payload = try Self.decodeUnverified(token)
            try payload.exp.verifyNotExpired()
        } else {
            payload = try await keyCollection().verify(token, as: FirebaseIDToken.self)
        }
        try payload.validate(projectID: projectID)
        return payload
    }

    // MARK: - JWKS

    private func keyCollection() async throws -> JWTKeyCollection {
        if let keys, keysExpireAt > .now {
            return keys
        }

        logger.info("Fetching Firebase JWKS")
        let response = try await client.get(URI(string: Self.jwksURL))
        guard var body = response.body, let bytes = body.readData(length: body.readableBytes) else {
            throw Abort(.internalServerError, reason: "Empty JWKS response")
        }
        let jwks = try JSONDecoder().decode(JWKS.self, from: bytes)

        let collection = JWTKeyCollection()
        try await collection.add(jwks: jwks)

        self.keys = collection
        self.keysExpireAt = .now + Self.maxAge(from: response.headers)
        return collection
    }

    /// Cache lifetime from the JWKS response's Cache-Control, default 1 hour.
    static func maxAge(from headers: HTTPHeaders) -> TimeInterval {
        guard
            let cacheControl = headers.first(name: .cacheControl),
            let match = cacheControl.firstMatch(of: /max-age=(\d+)/),
            let seconds = TimeInterval(match.1)
        else {
            return 3600
        }
        return seconds
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
            return try JSONDecoder().decode(FirebaseIDToken.self, from: payload)
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

/// Placeholder client for the test initializer of `FirebaseTokenVerifier` —
/// JWKS is never fetched when keys are preloaded.
struct UnavailableClient: Client {
    var eventLoop: any EventLoop {
        fatalError("UnavailableClient has no event loop")
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        fatalError("UnavailableClient cannot send requests")
    }

    func delegating(to eventLoop: any EventLoop) -> any Client {
        self
    }
}
