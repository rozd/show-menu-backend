import Vapor

/// `POST /api/v1/payments/liqpay/callback`: LiqPay's `server_url` payload,
/// `application/x-www-form-urlencoded` with base64 `data` and `signature`. Both are optional
/// at decode time so that "missing" is a typed 400 / 401 rather than a decoding failure. The
/// endpoint is public: the signature *is* the authentication.
struct LiqPayCallbackEnvelope: Content {
    let data: String?
    let signature: String?
}
