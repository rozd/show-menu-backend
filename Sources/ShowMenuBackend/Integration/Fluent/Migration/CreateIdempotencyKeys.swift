//
//  CreateIdempotencyKeys.swift
//  ShowMenuBackend
//
//  Schema for the inbound-command de-duplication table.
//

import Foundation
import Fluent
import FluentPostgresDriver

/// Creates the `idempotency_keys` table backing ``FluentIdempotencyStore``.
///
/// The primary key carries the load-bearing constraint: the record id is the
/// scoped, hashed `Idempotency-Key`, so `INSERT` doubles as the in-flight guard for
/// two concurrent first-time requests (see ``FluentIdempotencyStore``). The
/// `expires_at` index exists for TTL cleanup.
struct CreateIdempotencyKeys: AsyncMigration {

    var name: String { "CreateIdempotencyKeys" }

    func prepare(on database: any Database) async throws {
        try await database.schema(IdempotencyKeyRecord.schema)
            .field("id", .string, .identifier(auto: false))
            .field("fingerprint", .string, .required)
            .field("status", .string, .required)
            .field("response_status", .int)
            .field("response_body", .data)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.create(index: "idempotency_keys_expires_at_idx")
            .on(IdempotencyKeyRecord.schema)
            .column("expires_at")
            .run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(IdempotencyKeyRecord.schema).delete()
    }
}
