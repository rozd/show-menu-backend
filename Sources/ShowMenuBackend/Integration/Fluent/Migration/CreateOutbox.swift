//
//  CreateOutbox.swift
//  ShowMenuBackend
//
//  Schema for the transactional-outbox table.
//

import Foundation
import Fluent
import FluentPostgresDriver

/// Creates the `outbox` table backing ``FluentOutboxStore``.
///
/// The two indexes are not decoration — they are the difference between a relay
/// that scales and one that scans the whole table every minute:
///
/// - `(status, available_at)` serves the drain query (`pending` **and** due), which
///   runs on every relay tick.
/// - `(status, published_at)` serves TTL pruning, which walks published rows oldest
///   first.
struct CreateOutbox: AsyncMigration {

    var name: String { "CreateOutbox" }

    func prepare(on database: any Database) async throws {
        try await database.schema(OutboxMessageRecord.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("kind", .string, .required)
            .field("payload", .data, .required)
            .field("origin", .string, .required)
            .field("correlation_id", .string)
            .field("occurred_at", .datetime)
            .field("sequence", .int, .required)
            .field("status", .string, .required)
            .field("created_at", .datetime, .required)
            .field("published_at", .datetime)
            .field("attempts", .int, .required)
            .field("available_at", .datetime, .required)
            .field("last_error", .string)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.create(index: "outbox_pending_idx")
            .on(OutboxMessageRecord.schema)
            .column("status")
            .column("available_at")
            .run()
        try await sql.create(index: "outbox_published_idx")
            .on(OutboxMessageRecord.schema)
            .column("status")
            .column("published_at")
            .run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(OutboxMessageRecord.schema).delete()
    }
}
