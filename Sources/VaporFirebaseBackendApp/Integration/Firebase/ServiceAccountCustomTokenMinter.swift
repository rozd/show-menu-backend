import Crypto
import CryptoExtras
import Foundation

// MARK: - Standalone (Service Account JSON)

struct ServiceAccountCustomTokenMinter: FirebaseCustomTokenMinter {
    let clientEmail: String
    let privateKey: String

    func createCustomToken(uid: String) async throws -> String {
        let signatureInput = try FirebaseCustomTokenJWT.signatureInput(
            issuer: clientEmail,
            uid: uid,
        )

        let rsaKey = try _RSA.Signing.PrivateKey(pemRepresentation: privateKey)
        let signature = try rsaKey.signature(
            for: signatureInput.data(using: .utf8)!,
            padding: .insecurePKCS1v1_5,
        )

        return "\(signatureInput).\(Data(signature.rawRepresentation).base64URLEncodedString())"
    }
}
