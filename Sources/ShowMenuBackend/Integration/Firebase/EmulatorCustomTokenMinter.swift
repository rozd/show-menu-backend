import Foundation

// MARK: - Emulator

struct EmulatorCustomTokenMinter: FirebaseCustomTokenMinter {
    let projectId: String

    func createCustomToken(uid: String) async throws -> String {
        let issuer = "\(projectId)@\(projectId).iam.gserviceaccount.com"

        let header = FirebaseCustomTokenJWT.Header(alg: "none", typ: "JWT")
        let headerData = try JSONEncoder().encode(header)
        let headerBase64 = headerData.base64URLEncodedString()

        let claims = FirebaseCustomTokenJWT.Claims(
            iss: issuer,
            sub: issuer,
            aud: FirebaseCustomTokenJWT.audience,
            iat: Int(Date().timeIntervalSince1970),
            exp: Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
            uid: uid,
        )
        let claimsData = try JSONEncoder().encode(claims)
        let claimsBase64 = claimsData.base64URLEncodedString()

        // Emulator accepts unsigned tokens
        return "\(headerBase64).\(claimsBase64)."
    }
}
