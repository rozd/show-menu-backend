// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "ShowMenuBackend",
    platforms: [
       .macOS(.v15)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.1"),
        // 🎯 Job queue system for Vapor applications
        .package(url: "https://github.com/vapor/queues.git", from: "1.17.2"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // 🔐 Cross-platform cryptography for JWT signing (works on macOS and Linux)
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.2.0"),
        // 🔑 JWT verification for Firebase ID tokens (JWKS, RS256)
        .package(url: "https://github.com/vapor/jwt.git", from: "5.1.0"),
        // 🔥 Firebase API - gRPC-based Firestore client
        //    Pinned to a revision (was `branch: main`); bump deliberately.
        .package(url: "https://github.com/Rsych/FirebaseAPI.git", revision: "c5fe828790f7d7bf443dda42bbcba3fc3fe72a6a"),
        // 📡 gRPC Swift NIO Transport - HTTP/2 transport for FirebaseAPI
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        // 🔑 Google Auth - Application Default Credentials and OAuth2 access tokens for GCP APIs
        .package(url: "https://github.com/googleapis/swift-google-auth", from: "0.6.0"),
        // 💳 LiqPay client (signing, status, webhook decoding). Manifest is swift-tools 6.3.
        //    Pinned to a revision; bump deliberately.
        .package(url: "https://github.com/summerhammer/liqpay-client.git", revision: "fcfdf522d121b5c12783a2745803ce9cecc82ddd"),
        // 📜 The OpenAPI wire contract (generated types + server stubs) — single source of truth for the
        // HTTP API. Pinned to a **tag**, never a branch: a contract change is a PR in show-menu-contracts
        // first, then a bump here (see docs/conventions/WireContract.md). Private repo — CI and Docker
        // resolve it with a read-only token.
        .package(url: "https://github.com/rozd/show-menu-contracts.git", from: "0.2.0"),
        // 🧩 Vapor transport for swift-openapi-runtime (`registerHandlers(on: VaporTransport(...))`)
        .package(url: "https://github.com/swift-server/swift-openapi-vapor.git", from: "1.1.0"),
        // ⚙️ Runtime library for the generated server code
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.0"),
    ],
    targets: [
        .target(
            name: "ShowMenuBackend",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Queues", package: "queues"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
                .product(name: "FirestoreAPI", package: "FirebaseAPI"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GoogleAuth", package: "swift-google-auth"),
                .product(name: "LiqPayClient", package: "liqpay-client"),
                .product(name: "LiqPayClientVapor", package: "liqpay-client"),
                .product(name: "ShowMenuContracts", package: "show-menu-contracts"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            // Documentation-only files living next to sources. SwiftPM has no glob
            // for `exclude`, so add new README paths here when introducing them.
            exclude: [
                "Lib/README.md",
                "Lib/AOP/README.md",
                "Lib/CQRS/README.md",
                "Lib/DDD/README.md",
                "Lib/FSM/README.md",
                "Lib/Utils/README.md",
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "Run",
            dependencies: [
                .target(name: "ShowMenuBackend"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ShowMenuBackendTests",
            dependencies: [
                .target(name: "ShowMenuBackend"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "GoogleAuth", package: "swift-google-auth"),
                .product(name: "LiqPayClient", package: "liqpay-client"),
                .product(name: "ShowMenuContracts", package: "show-menu-contracts"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
