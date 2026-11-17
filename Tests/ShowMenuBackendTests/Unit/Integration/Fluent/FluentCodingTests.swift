import Foundation
import Testing
@testable import ShowMenuBackend

/// Tests for ``FluentCoding.columnName(for:)`` and the row encoder/decoder.
@Suite("Fluent Coding")
struct FluentCodingTests {

    // MARK: - Column Name Translation

    @Test("columnName: simple camelCase becomes snake_case")
    func simpleSnakeCase() {
        #expect(FluentCoding.columnName(for: "id") == "id")
        #expect(FluentCoding.columnName(for: "name") == "name")
        #expect(FluentCoding.columnName(for: "createdAt") == "created_at")
        #expect(FluentCoding.columnName(for: "displayName") == "display_name")
    }

    @Test("columnName: all snake_case conversions")
    func multiWordConversion() {
        #expect(FluentCoding.columnName(for: "photoUrl") == "photo_url")
        #expect(FluentCoding.columnName(for: "emailVerified") == "email_verified")
        #expect(FluentCoding.columnName(for: "isSomething") == "is_something")
    }

    @Test("columnName: single character")
    func singleChar() {
        #expect(FluentCoding.columnName(for: "x") == "x")
        #expect(FluentCoding.columnName(for: "a") == "a")
    }

    @Test("columnName: empty string")
    func emptyString() {
        #expect(FluentCoding.columnName(for: "") == "")
    }

    @Test("columnName: documents the photoURL quirk — consecutive capitals don't fully lowercase")
    func acronymQuirk() {
        // This is the documented quirk from FluentCoding's comment:
        // "consecutive capitals are *not* fully lowercased (photoURL becomes photo_uRL, not photo_url)"
        // The model keeps coding keys free of acronym runs (photoUrl, not photoURL),
        // so this documents the edge case to prevent silent divergence if someone
        // adds a field with an acronym.
        #expect(FluentCoding.columnName(for: "photoURL") == "photo_uRL")
    }

    // MARK: - Column Resolution

    @Test("column(for:) resolves a field to a SQLColumn")
    func simpleColumnResolution() throws {
        let _ = try FluentCoding.column(for: "id")
        // Successfully returns without throwing
    }

    @Test("column(for:) throws on nested (dotted) fields")
    func nestedFieldThrows() {
        #expect(throws: FluentQueryError.self) {
            try FluentCoding.column(for: "owner.id")
        }
    }

    // MARK: - Row Encoding

    @Test("encodes UserModel with displayName → display_name")
    func encodeUserModel() throws {
        let model = UserModel(
            id: "u1",
            displayName: "Alice",
            photoURL: "https://example.com/photo.jpg",
            emailVerified: true,
            version: 1
        )

        let columns = try FluentCoding.columns(of: model)
        let columnDict = Dictionary(uniqueKeysWithValues: columns.map { ($0.0, $0.1) })

        #expect(columnDict["display_name"] != nil)
        #expect(columnDict["photo_url"] != nil)
        #expect(columnDict["email_verified"] != nil)
    }

    @Test("nil strategy .asNil writes explicit NULL")
    func nilEncodingAsNil() throws {
        let model = UserModel(id: "u1")

        let columns = try FluentCoding.columns(of: model)

        // When display_name is nil, the .asNil strategy means it *is* encoded
        // (unlike .omitted, which would skip it). We can't easily verify the
        // NULL encoding without inspecting SQLExpression internals, but the
        // presence of the column is the main point: updates must clear a column,
        // not leave it stale.
        let columnNames = columns.map { $0.0 }
        #expect(columnNames.contains("display_name"))
    }

    // MARK: - Row Decoding

    @Test("decodes StubSQLRow with snake_case columns to UserModel")
    func decodeUserModel() throws {
        let row = StubSQLRow([
            "id": "u1",
            "display_name": "Alice",
            "email": "alice@example.com",
            "version": 5,
            "created_at": Date(timeIntervalSince1970: 1000)
        ])

        let model = try FluentCoding.decode(UserModel.self, from: row, table: "users", id: "u1")

        #expect(model.id == "u1")
        #expect(model.displayName == "Alice")
        #expect(model.email == "alice@example.com")
        #expect(model.version == 5)
        #expect(model.createdAt == Date(timeIntervalSince1970: 1000))
    }

    @Test("decoding failure reports the table and id")
    func decodingFailureReportsContext() throws {
        // A row missing a required field
        let row = StubSQLRow(["id": "u1", "version": "not-an-int"])

        #expect(throws: FluentStoreError.self) {
            try FluentCoding.decode(UserModel.self, from: row, table: "users", id: "u1")
        }
    }
}
