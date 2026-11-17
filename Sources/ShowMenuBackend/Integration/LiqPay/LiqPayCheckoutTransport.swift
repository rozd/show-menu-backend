import AsyncHTTPClient
import Foundation
import NIOCore
import Vapor

/// What the checkout POST yielded. LiqPay answers a valid checkout with a 3xx
/// whose `Location` is the hosted payment page.
struct LiqPayCheckoutResponse: Sendable, Equatable {
    let statusCode: Int
    let location: String?
    /// First bytes of the body, for diagnostics only.
    let bodyPreview: String
}

/// Seam for the checkout POST. The package's `LiqPayTransport` response carries no
/// headers, and checkout needs the redirect `Location`, so this is separate.
/// Throws only on genuine transport failures (connection, TLS, timeout...).
protocol LiqPayCheckoutTransport: Sendable {
    func post(url: URL, form: [String: String]) async throws -> LiqPayCheckoutResponse
}

/// AsyncHTTPClient-backed transport. Owns a **dedicated** `HTTPClient` that
/// never follows redirects (the redirect is the result); `app.http.client` is untouched.
final class AsyncHTTPClientLiqPayCheckoutTransport: LiqPayCheckoutTransport, Sendable {

    private let client: HTTPClient
    private let timeout: TimeAmount

    init(timeout: TimeAmount = .seconds(30)) {
        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        self.client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        self.timeout = timeout
    }

    func post(url: URL, form: [String: String]) async throws -> LiqPayCheckoutResponse {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        request.body = .bytes(ByteBuffer(string: Self.formEncode(form)))

        let response = try await client.execute(request, timeout: timeout)

        var preview = ByteBuffer()
        for try await chunk in response.body {
            preview.writeImmutableBuffer(chunk)
            if preview.readableBytes >= 512 { break }
        }
        let bytes = preview.readBytes(length: min(512, preview.readableBytes)) ?? []
        return LiqPayCheckoutResponse(
            statusCode: Int(response.status.code),
            location: response.headers.first(name: "Location"),
            bodyPreview: String(decoding: bytes, as: UTF8.self)
        )
    }

    func shutdown() async throws {
        try await client.shutdown()
    }

    /// `application/x-www-form-urlencoded` body: keys sorted for determinism, every
    /// byte outside the RFC 3986 unreserved set percent-encoded (base64 `+/=` included).
    static func formEncode(_ form: [String: String]) -> String {
        form.keys.sorted().map { key in
            "\(percentEncode(key))=\(percentEncode(form[key] ?? ""))"
        }.joined(separator: "&")
    }

    static func percentEncode(_ value: String) -> String {
        var result = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                result.append(Character(UnicodeScalar(byte)))
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }
}

/// Shuts the dedicated checkout `HTTPClient` down with the application.
struct LiqPayCheckoutTransportShutdown: LifecycleHandler {
    let transport: AsyncHTTPClientLiqPayCheckoutTransport

    func shutdownAsync(_ application: Application) async {
        try? await transport.shutdown()
    }
}
