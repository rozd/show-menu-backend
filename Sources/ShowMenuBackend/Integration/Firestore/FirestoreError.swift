import Foundation

enum FirestoreError: Error, LocalizedError {
    case connectionFailed(underlying: any Error)
    case authenticationFailed
    case rateLimitExceeded
    case serviceUnavailable
    case documentNotFound
    case documentAlreadyExists
    case requestFailed(statusCode: Int, message: String)
    case transactionReturnedNil

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let underlying):
            return "Failed to connect to Firestore: \(underlying.localizedDescription)"
        case .authenticationFailed:
            return "Firestore authentication failed"
        case .rateLimitExceeded:
            return "Firestore rate limit exceeded"
        case .serviceUnavailable:
            return "Firestore service is temporarily unavailable"
        case .documentNotFound:
            return "Firestore document not found"
        case .documentAlreadyExists:
            return "Firestore document already exists"
        case .requestFailed(let statusCode, let message):
            return "Firestore request failed with status \(statusCode): \(message)"
        case .transactionReturnedNil:
            return "Firestore transaction returned nil"
        }
    }

    /// Whether this error is transient and the request should be retried
    var isRetryable: Bool {
        switch self {
        case .connectionFailed, .rateLimitExceeded, .serviceUnavailable, .transactionReturnedNil:
            return true
        case .authenticationFailed, .documentNotFound, .documentAlreadyExists, .requestFailed:
            return false
        }
    }
}
