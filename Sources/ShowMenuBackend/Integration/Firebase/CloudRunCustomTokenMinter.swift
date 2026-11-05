import Foundation
import Logging
import Vapor

// MARK: - Cloud Run (IAM signBlob)

final class CloudRunCustomTokenMinter: FirebaseCustomTokenMinter, @unchecked Sendable {
    private static let metadataServerURL = "http://metadata.google.internal/computeMetadata/v1"
    private static let iamBaseURL = "https://iamcredentials.googleapis.com/v1"

    private let client: any Client
    private let authProvider: any GCPAuthProvider
    private let logger: Logger

    private let lock = NSLock()
    private var cachedEmail: String?

    init(client: any Client, authProvider: any GCPAuthProvider, logger: Logger) {
        self.client = client
        self.authProvider = authProvider
        self.logger = logger
    }

    func createCustomToken(uid: String) async throws -> String {
        let email = try await serviceAccountEmail()

        let signatureInput = try FirebaseCustomTokenJWT.signatureInput(
            issuer: email,
            uid: uid,
        )

        let signedBytes = try await signBlob(
            email: email,
            bytes: Data(signatureInput.utf8),
        )

        return "\(signatureInput).\(signedBytes.base64URLEncodedString())"
    }

    // MARK: - IAM signBlob

    private func signBlob(email: String, bytes: Data) async throws -> Data {
        guard let token = try await authProvider.getAccessToken() else {
            throw CloudRunMintingError.authenticationFailed
        }

        let url = "\(Self.iamBaseURL)/projects/-/serviceAccounts/\(email):signBlob"

        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Bearer \(token)")
        headers.add(name: .contentType, value: "application/json")

        let body = SignBlobRequest(payload: bytes.base64EncodedString())
        let bodyData = try JSONEncoder().encode(body)

        let response = try await client.post(URI(string: url), headers: headers) { req in
            req.body = .init(data: bodyData)
        }

        guard response.status == .ok else {
            let message = response.body.map { String(buffer: $0) } ?? "Unknown error"
            logger.error("IAM signBlob failed", metadata: [
                "status": .stringConvertible(response.status.code),
                "body": .string(message),
            ])
            throw CloudRunMintingError.signBlobFailed(
                statusCode: Int(response.status.code),
                message: message,
            )
        }

        let signResponse = try response.content.decode(SignBlobResponse.self)

        guard let signedData = Data(base64Encoded: signResponse.signedBlob) else {
            throw CloudRunMintingError.invalidSignBlobResponse
        }

        return signedData
    }

    // MARK: - Service Account Email

    private func serviceAccountEmail() async throws -> String {
        if let cached = lock.withLock({ cachedEmail }) {
            return cached
        }

        let url = "\(Self.metadataServerURL)/instance/service-accounts/default/email"
        let response = try await client.get(URI(string: url), headers: ["Metadata-Flavor": "Google"])

        guard response.status == .ok, let body = response.body else {
            throw CloudRunMintingError.metadataServerUnavailable
        }

        let email = String(buffer: body).trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock { cachedEmail = email }

        logger.info("Resolved service account email from metadata server", metadata: [
            "email": .string(email),
        ])

        return email
    }
}

// MARK: - Cloud Run Types

private struct SignBlobRequest: Encodable {
    let payload: String
}

private struct SignBlobResponse: Decodable {
    let keyId: String
    let signedBlob: String
}

enum CloudRunMintingError: Error, LocalizedError {
    case authenticationFailed
    case signBlobFailed(statusCode: Int, message: String)
    case invalidSignBlobResponse
    case metadataServerUnavailable

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Failed to obtain access token for IAM signBlob"
        case .signBlobFailed(let code, let message):
            return "IAM signBlob failed with status \(code): \(message)"
        case .invalidSignBlobResponse:
            return "IAM signBlob returned invalid base64 response"
        case .metadataServerUnavailable:
            return "GCP metadata server is unavailable"
        }
    }
}
