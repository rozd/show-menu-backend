import HTTPTypes

extension HTTPFields {

    /// The token of an `Authorization: Bearer <token>` header (scheme matched
    /// case-insensitively), or `nil` when the header is absent or not a two-part
    /// bearer credential. Mirrors Vapor's `HTTPHeaders.bearerAuthorization`.
    var bearerToken: String? {
        guard let value = self[.authorization] else { return nil }
        let parts = value.split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1])
    }
}
