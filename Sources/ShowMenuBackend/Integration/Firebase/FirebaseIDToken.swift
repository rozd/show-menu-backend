import JWT
import Vapor

/// Claims of a Firebase Auth ID token (an RS256 JWT issued by
/// `securetoken.google.com`). `sub` carries the Firebase uid; `admin` is the
/// custom claim that makes the caller an administrator (D5).
struct FirebaseIDToken: JWTPayload {
    let iss: IssuerClaim
    let aud: AudienceClaim
    let exp: ExpirationClaim
    let sub: SubjectClaim
    let email: String?
    let admin: Bool?
    /// Issued-at (seconds since epoch); must not be in the future.
    var iat: IssuedAtClaim? = nil
    /// Time of the user's last authentication (seconds since epoch); must not be in the future.
    var authTime: TimeInterval? = nil

    enum CodingKeys: String, CodingKey {
        case iss, aud, exp, sub, email, admin, iat
        case authTime = "auth_time"
    }

    /// Tolerated clock skew for `iat` / `auth_time`.
    static let leeway: TimeInterval = 60

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }

    /// Issuer/audience/subject/time checks shared by the signed and emulator paths.
    func validate(projectID: String, now: Date = Date()) throws {
        guard iss.value == "https://securetoken.google.com/\(projectID)" else {
            throw FirebaseAuthError.invalidIssuer(iss.value)
        }
        guard aud.value.contains(projectID) else {
            throw FirebaseAuthError.invalidAudience(aud.value)
        }
        guard !sub.value.isEmpty else {
            throw FirebaseAuthError.missingSubject
        }
        let limit = now.timeIntervalSince1970 + Self.leeway
        if let iat, iat.value.timeIntervalSince1970 > limit {
            throw FirebaseAuthError.issuedInFuture
        }
        if let authTime, authTime > limit {
            throw FirebaseAuthError.issuedInFuture
        }
    }
}

enum FirebaseAuthError: Error, LocalizedError, Equatable {
    case invalidIssuer(String)
    case invalidAudience([String])
    case missingSubject
    case malformedToken
    case issuedInFuture
    case unknownKeyID(String)

    var errorDescription: String? {
        switch self {
        case .invalidIssuer(let issuer):
            return "Unexpected token issuer '\(issuer)'"
        case .invalidAudience(let audience):
            return "Unexpected token audience \(audience)"
        case .missingSubject:
            return "Token has no subject (uid)"
        case .malformedToken:
            return "Token is not a valid RS256 JWT with a key id"
        case .issuedInFuture:
            return "Token was issued in the future"
        case .unknownKeyID(let kid):
            return "Unknown signing key id '\(kid)'"
        }
    }
}
