import Foundation
import FirestoreAPI
import Logging

/// Firestore binding of ``InvoiceStatusAuditStore``: a buffered `create` of
/// `invoices/{invoiceId}/statuses/{auto-id}` in the command's transaction, so the audit
/// document commits (or rolls back) with the state change.
///
/// The document is the callback's decoded JSON object, field for field (the extension did
/// `.add(status)` with the parsed payload), with JSON types preserved: integral numbers are
/// `integerValue`, fractional ones `doubleValue`, booleans `booleanValue`, `null` `nullValue`.
struct FirestoreInvoiceStatusAuditStore: InvoiceStatusAuditStore {
    let transaction: FirestoreTransaction
    /// Collection prefix (`FIRESTORE_PATH_PREFIX` aware), "" for the root.
    let prefix: String
    let logger: Logger

    func append(invoiceId: String, rawPayload: String) async throws {
        let path = [prefix, "invoices", invoiceId, "statuses"].filter { !$0.isEmpty }.joined(separator: "/")
        do {
            let fields = try Self.fields(fromJSON: rawPayload)
            let docRef = transaction.collection(path).document()
            logger.debug("Appending invoice status", metadata: [
                "collection": .string(path), "documentId": .string(docRef.documentID)
            ])
            try await transaction.create(documentReference: docRef, data: fields)
        } catch {
            throw FirestoreError.from(grpcError: error)
        }
    }

    /// A JSON object as Firestore document data with native Swift value types (`Int`, `Double`,
    /// `Bool`, `String`, `NSNull`, `[Any]`, `[String: Any]`), avoiding `NSNumber` bridging.
    static func fields(fromJSON json: String) throws -> [String: Any] {
        guard case .object(let object) = try JSONDecoder().decode(JSONNode.self, from: Data(json.utf8)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Payload is not a JSON object"))
        }
        return object.mapValues(\.value)
    }

    private indirect enum JSONNode: Decodable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case array([JSONNode])
        case object([String: JSONNode])

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Int64.self) { self = .int(v) }
            else if let v = try? c.decode(Double.self) { self = .double(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([JSONNode].self) { self = .array(v) }
            else { self = .object(try c.decode([String: JSONNode].self)) }
        }

        var value: Any {
            switch self {
            case .null: NSNull()
            case .bool(let v): v
            case .int(let v): v
            case .double(let v): v
            case .string(let v): v
            case .array(let v): v.map(\.value)
            case .object(let v): v.mapValues(\.value)
            }
        }
    }
}
