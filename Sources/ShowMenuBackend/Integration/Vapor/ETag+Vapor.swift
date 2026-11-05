import Vapor

// MARK: - Version <-> HTTP entity tag

extension Version {

    /// Renders the token as a quoted HTTP entity-tag value (RFC 7232), suitable
    /// for an `ETag` response header. `nil` for `.none` (nothing to advertise).
    var etag: String? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        return "\"\(rawValue)\""
    }

    /// Parses an HTTP entity tag (from `ETag`/`If-Match`) into a `Version`,
    /// stripping the optional weak-validator prefix and surrounding quotes.
    init(etag: String) {
        let unquoted = etag
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "W/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        self = Version(rawValue: unquoted.isEmpty ? nil : unquoted)
    }
}

// MARK: - Request: read If-Match precondition

extension Request {

    /// The `If-Match` precondition supplied by the client, if any. `*` (match
    /// any existing representation) yields `nil`, since it imposes no specific
    /// version precondition.
    var ifMatch: Version? {
        guard let header = headers.first(name: .ifMatch) else { return nil }
        if header.trimmingCharacters(in: .whitespaces) == "*" { return nil }
        return Version(etag: header)
    }
}

// MARK: - Response: advertise the current version

extension Response {

    /// Stamps the response with the aggregate's current version as an `ETag`.
    /// No-op when the version is `.none`.
    func setETag(_ version: Version) {
        if let etag = version.etag {
            headers.replaceOrAdd(name: .eTag, value: etag)
        }
    }
}
