//
//  FluentCoding.swift
//  ShowMenuBackend
//
//  The single row-coding configuration used by every Fluent binding.
//

import Foundation
import FluentPostgresDriver

/// The one place the Fluent adapter's row coding is configured.
///
/// A module's store model (`UserModel`, …) is a plain `Codable`
/// struct — it *is* the row. ``SQLQueryEncoder`` turns it into (column, value)
/// pairs and ``SQLRowDecoder`` turns a row back into it, so the generic data
/// sources need no per-aggregate mapping code at all.
///
/// Two settings carry weight:
///
/// - **`.convertToSnakeCase`** — coding keys are camelCase, columns are
///   `snake_case`, the way a Postgres schema is conventionally written (and
///   without it every identifier would need quoting to survive Postgres's
///   lowercase folding). Because ``DataSourceFilter`` addresses fields by their
///   *model* name, ``columnName(for:)`` applies the identical transform, so a
///   filter on `createdAt` reaches the `created_at` column.
/// - **`.asNil`** — a `nil` property is written as an explicit `NULL` rather than
///   omitted. On an update that distinction is the difference between clearing a
///   column and silently leaving a stale value behind.
enum FluentCoding {

    /// Encodes a store model into (column, value) pairs.
    static let encoder = SQLQueryEncoder(
        keyEncodingStrategy: .convertToSnakeCase,
        nilEncodingStrategy: .asNil
    )

    /// Decodes a row back into a store model.
    static let decoder = SQLRowDecoder(keyDecodingStrategy: .convertFromSnakeCase)

    /// The (column, value) pairs a model writes, in coding-key order.
    static func columns(of model: some Encodable) throws -> [(String, any SQLExpression)] {
        try encoder.encode(model)
    }

    /// Decodes one row, reporting a failure as ``FluentStoreError`` with the row's
    /// coordinates — the analogue of a store surfacing a malformed row rather than
    /// an opaque `nil`.
    static func decode<M: Decodable>(
        _ type: M.Type,
        from row: any SQLRow,
        table: String,
        id: String? = nil
    ) throws -> M {
        do {
            return try decoder.decode(M.self, from: row)
        } catch {
            throw FluentStoreError.decodingFailed(table: table, id: id, underlying: error)
        }
    }

    // MARK: Field addressing

    /// Maps a store-agnostic field name (a ``DataSourceFilter``/``DataSourceOrder``
    /// field, i.e. a model coding key) to its column name.
    ///
    /// This mirrors SQLKit's own `convertToSnakeCase` transform *exactly* — the one
    /// ``encoder`` applies when writing. Reimplementing rather than reusing is
    /// unavoidable (SQLKit's version is internal), and divergence would be silent
    /// and nasty: filters would address columns that do not exist. The rule, from
    /// SQLKit: split at each lower→upper boundary, join with `_`, lowercase each
    /// word's first character.
    ///
    /// > Note: consecutive capitals are *not* fully lowercased (`photoURL` becomes
    /// > `photo_uRL`, not `photo_url`) — a quirk inherited from SQLKit. Keep model
    /// > coding keys free of acronym runs (`photoUrl`, not `photoURL`), as
    /// > ``UserModel`` does.
    static func columnName(for field: String) -> String {
        guard !field.isEmpty else { return field }

        var words: [Range<String.Index>] = []
        var wordStart = field.startIndex
        var searchIndex = field.index(after: wordStart)

        while let upperCaseIndex = field[searchIndex...].firstIndex(where: \.isUppercase) {
            words.append(wordStart..<upperCaseIndex)
            wordStart = upperCaseIndex
            guard let lowerCaseIndex = field[upperCaseIndex...].firstIndex(where: \.isLowercase) else {
                break
            }
            searchIndex = lowerCaseIndex
            if lowerCaseIndex != field.index(after: upperCaseIndex) {
                let beforeLowerIndex = field.index(before: lowerCaseIndex)
                words.append(upperCaseIndex..<beforeLowerIndex)
                wordStart = beforeLowerIndex
            }
        }
        words.append(wordStart..<field.endIndex)

        return words
            .map { range -> String in
                let word = field[range]
                guard let first = word.first else { return "" }
                return "\(first.lowercased())\(word.dropFirst())"
            }
            .joined(separator: "_")
    }

    /// Resolves a query field to a column, rejecting nested (dotted) paths.
    ///
    /// A document store can address `owner.id` inside a document; a relational
    /// column holds a scalar. Throwing beats quietly matching nothing.
    static func column(for field: String) throws -> SQLColumn {
        guard !field.contains(".") else {
            throw FluentQueryError.nestedField(field: field)
        }
        return SQLColumn(columnName(for: field))
    }
}
