//
//  IdempotencyKey.swift
//  ShowMenuBackend
//
//  A validated client-supplied de-duplication token.
//

import Foundation

/// A validated idempotency token, carried by clients in the `Idempotency-Key`
/// HTTP header (request *metadata*, never a field on a command payload).
///
/// The value is opaque to the server: a client generates a unique token per
/// logical operation (typically a UUID) and replays it verbatim when retrying,
/// so the server can recognise the retry and avoid running the work twice.
///
/// Validation keeps malformed/abusive headers out of the store: the raw value is
/// trimmed and bounded in length. The token is *not* the storage key on its own
/// — it is combined with an ``IdempotencyScope`` before hashing into a record id.
struct IdempotencyKey: Sendable, Hashable, CustomStringConvertible {

    /// Maximum accepted length, matching common API gateway limits.
    static let maxLength = 255

    let rawValue: String

    /// Validates and normalises a raw header value.
    /// - Throws: ``IdempotencyError/malformedKey(_:)`` when empty after trimming
    ///   or longer than ``maxLength``.
    init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxLength else {
            throw IdempotencyError.malformedKey(rawValue)
        }
        self.rawValue = trimmed
    }

    var description: String { rawValue }
}
