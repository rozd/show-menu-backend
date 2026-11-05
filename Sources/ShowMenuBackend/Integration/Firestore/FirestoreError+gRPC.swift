import FirestoreAPI
import GRPCCore

extension FirestoreError {
    /// Maps gRPC errors to FirestoreError cases
    /// - Parameter error: The error from FirebaseAPI or gRPC layer
    /// - Returns: Appropriate FirestoreError case
    static func from(grpcError error: any Error) -> FirestoreError {
        // Check if it's an RPCError from gRPC
        if let rpcError = error as? RPCError {
            return from(rpcError: rpcError)
        }

        // FirebaseAPI wraps every RPCError in FirestoreAPI.FirestoreError.rpcError.
        // Unwrap so we preserve the real gRPC status instead of collapsing to .connectionFailed.
        if let firestoreAPIError = error as? FirestoreAPI.FirestoreError {
            switch firestoreAPIError {
            case .rpcError(let rpcError):
                return from(rpcError: rpcError)
            case .invalidAccessToken:
                return .authenticationFailed
            case .timeout, .maxAttemptsReached:
                return .serviceUnavailable
            case .transactionFailed(let underlying):
                return from(grpcError: underlying)
            case .readAfterWriteError, .minNumberOfArgumentsError, .noResult, .invalidConfiguration:
                return .connectionFailed(underlying: firestoreAPIError)
            }
        }

        // Default: treat as connection failure
        return .connectionFailed(underlying: error)
    }

    /// Maps gRPC RPCError status codes to FirestoreError cases
    private static func from(rpcError: RPCError) -> FirestoreError {
        switch rpcError.code {
        case .unauthenticated:
            return .authenticationFailed
        case .permissionDenied:
            return .authenticationFailed
        case .notFound:
            return .documentNotFound
        case .alreadyExists:
            return .documentAlreadyExists
        case .unavailable:
            return .serviceUnavailable
        case .resourceExhausted:
            return .rateLimitExceeded
        case .deadlineExceeded:
            return .serviceUnavailable
        case .cancelled:
            return .connectionFailed(underlying: rpcError)
        case .internalError:
            return .requestFailed(statusCode: 500, message: rpcError.message)
        case .invalidArgument:
            return .requestFailed(statusCode: 400, message: rpcError.message)
        case .failedPrecondition:
            return .requestFailed(statusCode: 412, message: rpcError.message)
        case .aborted:
            return .requestFailed(statusCode: 409, message: rpcError.message)
        case .outOfRange:
            return .requestFailed(statusCode: 416, message: rpcError.message)
        case .unimplemented:
            return .requestFailed(statusCode: 501, message: rpcError.message)
        case .dataLoss:
            return .requestFailed(statusCode: 500, message: rpcError.message)
        case .unknown:
            return .requestFailed(statusCode: 500, message: rpcError.message)
        default:
            return .requestFailed(statusCode: 500, message: rpcError.message)
        }
    }
}
