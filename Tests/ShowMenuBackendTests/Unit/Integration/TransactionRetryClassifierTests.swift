import Foundation
import Testing
import GRPCCore
import FirestoreAPI
@testable import ShowMenuBackend

/// Stand-in with the same type/case name as FirebaseAPI's internal
/// `TransactionError.commitFailed`, which the classifier matches by name.
private enum TransactionError: Error { case commitFailed, rollbackFailed }

private struct DomainError: Error {}

@Suite("TransactionRetryClassifier")
struct TransactionRetryClassifierTests {

    private func rpc(_ code: RPCError.Code) -> FirestoreAPI.FirestoreError {
        .rpcError(RPCError(code: code, message: "x"))
    }

    @Test("transient transport failures retry", arguments: [
        RPCError.Code.aborted, .alreadyExists, .failedPrecondition,
        .unavailable, .deadlineExceeded, .resourceExhausted,
    ])
    func transientCodes(code: RPCError.Code) {
        #expect(TransactionRetryClassifier.isTransient(rpc(code)))
        #expect(TransactionRetryClassifier.isTransient(RPCError(code: code, message: "x")))
    }

    @Test("permanent gRPC codes do not retry", arguments: [
        RPCError.Code.invalidArgument, .notFound, .permissionDenied, .unauthenticated, .unimplemented,
    ])
    func permanentCodes(code: RPCError.Code) {
        #expect(!TransactionRetryClassifier.isTransient(rpc(code)))
    }

    @Test func commitFailedRetriesButOtherTransactionErrorsDoNot() {
        #expect(TransactionRetryClassifier.isTransient(TransactionError.commitFailed))
        #expect(!TransactionRetryClassifier.isTransient(TransactionError.rollbackFailed))
    }

    @Test func apiLevelTimeoutsRetry() {
        #expect(TransactionRetryClassifier.isTransient(FirestoreAPI.FirestoreError.timeout("t")))
        #expect(!TransactionRetryClassifier.isTransient(FirestoreAPI.FirestoreError.readAfterWriteError))
        #expect(!TransactionRetryClassifier.isTransient(FirestoreAPI.FirestoreError.invalidAccessToken("t")))
    }

    @Test func ownFirestoreErrorFollowsIsRetryable() {
        #expect(TransactionRetryClassifier.isTransient(FirestoreError.serviceUnavailable))
        #expect(!TransactionRetryClassifier.isTransient(FirestoreError.documentNotFound))
    }

    @Test func domainConcurrencyAndCancellationDoNotRetry() {
        #expect(!TransactionRetryClassifier.isTransient(DomainError()))
        #expect(!TransactionRetryClassifier.isTransient(CancellationError()))
        let conflict = ConcurrencyError.versionConflict(entity: "E", id: "1", expected: .none, actual: .none)
        #expect(!TransactionRetryClassifier.isTransient(conflict))
    }

    @Test func unwrapStripsTransactionFailedWrappers() {
        let wrapped = FirestoreAPI.FirestoreError.transactionFailed(
            error: FirestoreAPI.FirestoreError.transactionFailed(error: DomainError())
        )
        #expect(TransactionRetryClassifier.unwrap(wrapped) is DomainError)
        #expect(!TransactionRetryClassifier.isTransient(TransactionRetryClassifier.unwrap(wrapped)))
    }

    @Test func extraDelayTopsUpLibrarySleepToLegacySchedule() {
        #expect(TransactionRetryClassifier.extraDelay(forAttempt: 1) == 0)
        #expect(abs(TransactionRetryClassifier.extraDelay(forAttempt: 2) - 0.125) < 1e-9)
    }
}
