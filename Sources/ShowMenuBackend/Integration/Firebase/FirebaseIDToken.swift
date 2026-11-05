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

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }

    /// Issuer/audience/subject checks shared by the signed and emulator paths.
    func validate(projectID: String) throws {
        guard iss.value == "https://securetoken.google.com/\(projectID)" else {
            throw FirebaseAuthError.invalidIssuer(iss.value)
        }
        guard aud.value.contains(projectID) else {
            throw FirebaseAuthError.invalidAudience(aud.value)
        }
        guard !sub.value.isEmpty else {
            throw FirebaseAuthError.missingSubject
        }
    }
}

enum FirebaseAuthError: Error, LocalizedError, Equatable {
    case invalidIssuer(String)
    case invalidAudience([String])
    case missingSubject
    case malformedToken

    var errorDescription: String? {
        switch self {
        case .invalidIssuer(let issuer):
            return "Unexpected token issuer '\(issuer)'"
        case .invalidAudience(let audience):
            return "Unexpected token audience \(audience)"
        case .missingSubject:
            return "Token has no subject (uid)"
        case .malformedToken:
            return "Token is not a valid JWT"
        }
    }
}
