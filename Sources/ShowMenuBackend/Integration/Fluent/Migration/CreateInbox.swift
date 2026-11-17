//
//  CreateInbox.swift
//  ShowMenuBackend
//
//  Schema for the consumer-side de-duplication table.
//

import Foundation
import Fluent
import FluentPostgresDriver

/// Creates the `inbox` table backing ``FluentInboxStore``.
///
/// The primary key carries the load-bearing constraint: the record id is the
/// per-consumer, per-event scoped hash, so `INSERT` doubles as the in-flight
/// guard for two concurrent first-time handlers of the same event (see
/// ``FluentInboxStore``). The `expires_at` index exists for TTL cleanup.
struct CreateInbox: AsyncMigration {

    var name: String { "CreateInbox" }

    func prepare(on database: any Database) async throws {
        try await database.schema(InboxMessageRecord.schema)
            .field("id", .string, .identifier(auto: false))
            .field("processed_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.create(index: "inbox_expires_at_idx")
            .on(InboxMessageRecord.schema)
            .column("expires_at")
            .run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(InboxMessageRecord.schema).delete()
    }
}
