//
//  RetryPolicy+Firestore.swift
//  VaporFirebaseBackendApp
//
//  Firestore-aware retry policy preset.
//

import Foundation

extension RetryPolicy {
    /// Retries only transient Firestore failures (`FirestoreError.isRetryable`):
    /// connection drops, rate limits, temporary unavailability.
    static let firestore = RetryPolicy(
        shouldRetry: { ($0 as? FirestoreError)?.isRetryable ?? false }
    )
}
