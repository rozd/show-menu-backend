import Foundation

// MARK: - Shared JWT Construction

enum FirebaseCustomTokenJWT {
    static let audience =
        "https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit"

    struct Header: Encodable {
        let alg: String
        let typ: String
    }

    struct Claims: Encodable {
        let iss: String
        let sub: String
        let aud: String
        let iat: Int
        let exp: Int
        let uid: String
    }

    static func signatureInput(issuer: String, uid: String) throws -> String {
        let header = Header(alg: "RS256", typ: "JWT")
        let headerData = try JSONEncoder().encode(header)
        let headerBase64 = headerData.base64URLEncodedString()

        let now = Date()
        let claims = Claims(
            iss: issuer,
            sub: issuer,
            aud: audience,
            iat: Int(now.timeIntervalSince1970),
            exp: Int(now.addingTimeInterval(3600).timeIntervalSince1970),
            uid: uid,
        )
        let claimsData = try JSONEncoder().encode(claims)
        let claimsBase64 = claimsData.base64URLEncodedString()

        return "\(headerBase64).\(claimsBase64)"
    }
}
