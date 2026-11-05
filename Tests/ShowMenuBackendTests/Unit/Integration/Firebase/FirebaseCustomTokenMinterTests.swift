import Foundation
import Testing
@testable import ShowMenuBackend

@Suite("FirebaseCustomToken Infrastructure")
struct FirebaseCustomTokenMinterTests {

    // MARK: - Data.base64URLEncodedString()

    @Test("base64URL encoding contains no +, /, or = characters")
    func base64URL_noForbiddenCharacters() {
        // Use bytes that produce +, /, and = in standard base64
        // 0xFB, 0xFF, 0xFE produces "+//" in standard base64
        let problematicData = Data([0xFB, 0xFF, 0xFE, 0x3E, 0x2F])
        let encoded = problematicData.base64URLEncodedString()

        #expect(!encoded.contains("+"), "base64URL must not contain +")
        #expect(!encoded.contains("/"), "base64URL must not contain /")
        #expect(!encoded.contains("="), "base64URL must not contain =")
    }

    @Test("base64URL encoding round-trips through base64URL decode")
    func base64URL_roundTrip() {
        let original = Data("Hello, Firebase Custom Token!".utf8)
        let encoded = original.base64URLEncodedString()

        // Reverse the base64URL encoding
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-add padding
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        let decoded = Data(base64Encoded: base64)

        #expect(decoded == original)
    }

    // MARK: - FirebaseCustomTokenJWT.signatureInput

    @Test("signatureInput produces header.claims with correct JSON structure")
    func signatureInput_correctStructure() throws {
        let input = try FirebaseCustomTokenJWT.signatureInput(
            issuer: "test@example.iam.gserviceaccount.com",
            uid: "USER_42",
        )

        let parts = input.split(separator: ".")
        #expect(parts.count == 2, "signatureInput must be header.claims (2 parts)")

        // Decode header
        let headerJSON = try decodeBase64URLSegment(String(parts[0]))
        #expect(headerJSON["alg"] as? String == "RS256")
        #expect(headerJSON["typ"] as? String == "JWT")

        // Decode claims
        let claimsJSON = try decodeBase64URLSegment(String(parts[1]))
        #expect(claimsJSON["iss"] as? String == "test@example.iam.gserviceaccount.com")
        #expect(claimsJSON["sub"] as? String == "test@example.iam.gserviceaccount.com")
        #expect(claimsJSON["uid"] as? String == "USER_42")
        #expect(claimsJSON["aud"] as? String == FirebaseCustomTokenJWT.audience)

        // iat and exp should be integers, exp > iat
        let iat = claimsJSON["iat"] as? Int
        let exp = claimsJSON["exp"] as? Int
        #expect(iat != nil, "iat must be present")
        #expect(exp != nil, "exp must be present")
        if let iat, let exp {
            #expect(exp > iat, "exp must be after iat")
            #expect(exp - iat == 3600, "token should be valid for 1 hour")
        }
    }

    // MARK: - EmulatorCustomTokenMinter

    @Test("emulator minter produces unsigned JWT with alg:none and correct uid")
    func emulatorMinter_unsignedToken() async throws {
        let minter = EmulatorCustomTokenMinter(projectId: "demo-project")

        let token = try await minter.createCustomToken(uid: "USER_99")

        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3, "JWT must have 3 parts (header.claims.signature)")
        #expect(parts[2].isEmpty, "Emulator token signature must be empty")

        // Decode header
        let headerJSON = try decodeBase64URLSegment(String(parts[0]))
        #expect(headerJSON["alg"] as? String == "none")
        #expect(headerJSON["typ"] as? String == "JWT")

        // Decode claims
        let claimsJSON = try decodeBase64URLSegment(String(parts[1]))
        #expect(claimsJSON["uid"] as? String == "USER_99")

        let expectedIssuer = "demo-project@demo-project.iam.gserviceaccount.com"
        #expect(claimsJSON["iss"] as? String == expectedIssuer)
        #expect(claimsJSON["sub"] as? String == expectedIssuer)
    }

    // MARK: - ServiceAccountCustomTokenMinter

    @Test("service account minter signs with RSA and produces 3-part JWT")
    func serviceAccountMinter_signedToken() async throws {
        let minter = ServiceAccountCustomTokenMinter(
            clientEmail: "test@project.iam.gserviceaccount.com",
            privateKey: testRSAPrivateKey,
        )

        let token = try await minter.createCustomToken(uid: "USER_777")

        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3, "Signed JWT must have 3 parts")
        #expect(!parts[2].isEmpty, "Signature must not be empty")

        // Verify header and claims structure
        let headerJSON = try decodeBase64URLSegment(String(parts[0]))
        #expect(headerJSON["alg"] as? String == "RS256")

        let claimsJSON = try decodeBase64URLSegment(String(parts[1]))
        #expect(claimsJSON["uid"] as? String == "USER_777")
        #expect(claimsJSON["iss"] as? String == "test@project.iam.gserviceaccount.com")
    }
}

// MARK: - Helpers

private func decodeBase64URLSegment(_ segment: String) throws -> [String: Any] {
    var base64 = segment
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder > 0 {
        base64 += String(repeating: "=", count: 4 - remainder)
    }
    guard let data = Data(base64Encoded: base64) else {
        throw DecodingError.invalidBase64
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw DecodingError.invalidJSON
    }
    return json
}

private enum DecodingError: Error {
    case invalidBase64
    case invalidJSON
}

// MARK: - Test RSA Key (2048-bit, for testing only)

private let testRSAPrivateKey = """
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCZieeLBF+gIAXb
iUdqBbmR5nHMT4cy4GLJe9wNvvCosf7ETFQtnbdWxdxr0i/a9O7nxvwdxRlzcCm1
jnBkyvd7wjgUA4eRA558IvJjeL44s8JXWVLxsWOgowBK0xb2r3PeQ+3bdtsH8+uT
zPQBnPD2hEBAXgvgPOrXyBBgdf+0d9VxhyIhpGG7NMmbGHvLCfBQ93flPOcdW06M
5VE2dgn0xx3mpozShJtwnp4MlNOz2GI223LHxqjw7w/K/IEaq+O4NnZOB76bP9s4
oFGbuUJBHtwPgzlVo11YkvHVQ1miJR9D6EroFkBRryqe1D9xlWTWfH0E3szQpQO5
MXzBYeWLAgMBAAECggEAFAUs2W4pD+aNDPrCApubfmBHj2YBUYt7ph0N7QbsN3r6
JttzEH2jtd9X5gFCtzC/5B4IqtMUBf7mmWNo2WOz0IHbMRTivPB1XmdqJrlMSHV8
Dkq564T/YidO9vK+aE0pdR5zae3+EnPmUF/loz41F1fYTuxUbRlUX+2Y4RMR1BSm
VeAWF/expkmR/SuO2b80t1V6EaQ7sw+CR/T1iDtWMUmlbgxaOLZv9J+bw+bpCiCK
GU/GcSc50mDqu9rsecL9fHHKAZFiSmiwdyuwc3jXG2JqzMHqE/jHunWucwPZ9xGg
HrAoFs7uZXuXu3KuKeXf62EW5nM+WUIPCHduNdGYUQKBgQDNqtCQ8dyAlrSybksv
6S0v2LJ3ZG2y6R4yYYcv+P1WakYbHFPu8I/U+QDax4VMq7vAehjcOZO1VfpzSQ14
WjZnsO6/j0IQ7zpvZc8YjtaHu5FXDyjk6sNF91zpyDc04y9zfYrJrICeQlQtmYXj
PfPp/1PWmimN1i/IFa1CyxcuMQKBgQC/HTPCcyVnETOGwjo8R8Z6zY1aCr0ZeS3d
1E37sqsXfWMyZs+mflA+q0aTTs52RPuRML5XcAbqRT2VfUke7frkT8xpP/8JLsU2
JOzx1kefVCcLjJ8WL0O8/czt1RuxJKWelZJPq2JuDoRWhFPedCCvF+VuuZx2XoxK
li/Fgrj0ewKBgQDE0hly/OMmdBNNRtvRZ/cEeP6h34xT0WBCmq8DK+dV0bJxs3Rn
j/Q1vm4g8RwSOa8eDjrIVpmSyks6FMk9SigSp3J0BCcXibmEbgv41olbsBbxF+Ls
3/YseQOD/0VF6by5a4VsZxdXXOauFOPaiqloYB7dmv71a+qiMoxzBWSToQKBgGrj
PEWu/OZOOpFOJB/+zMV2HW6Uvvp2Se7dhNgXL5WtrUNNOSoXT24dgRV2aAbBwimM
J4jjwRpZq33mWnUQCNiUwPDEuDE8lVQZBuSjQd+cw1G0Tm2r9ajIEkuaeyhyJKcz
ZGdmpWCEggOZcwbh0D3dkZaB/T4+1xwIL6O53xPtAoGBAK3//ANXSb8+ofzG4UT/
w+zRoFwvAyaJGgENXGZp9v2iBOdQlBDJ1Gu5bWWlvJ0UflD7ZxYg25apsjOyP8iw
79e2IB3St4VmB/cIyH7bp3j9Upnm0lytY6Urux1k4p0FGq2ki+MEdp7veMTJaC4+
s75G+JQjzrJAMp/zxERt2i6+
-----END PRIVATE KEY-----
"""
