// swift-tools-version:6.3
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
        // 🔐 Cross-platform cryptography (SHA-256 request fingerprints; macOS and Linux)
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.2.0"),
        // 🗄 Fluent: database toolkit — connection pooling, migrations, transactions.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        // 🐘 The Postgres driver behind the Fluent store adapter (Integration/Fluent).
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
        // 🪶 SQLite driver: backs the app's own store when nothing is configured
        // (the zero-infrastructure default — see App/Fluent+Vapor.swift).
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0"),
        // 🎫 Passage: authentication (registration, login, tokens) — see App/Passage+Vapor.swift.
        .package(url: "https://github.com/vapor-community/passage.git", from: "0.5.12"),
        // 🎫 Fluent-backed Passage store in overlay mode: shares the app's `users` table.
        .package(url: "https://github.com/rozd/passage-fluent.git", from: "0.1.0"),
        // 📜 The wire contract: OpenAPI spec + generated Swift types (`APIProtocol`).
        // Pinned by tag (`from:` resolves to a tagged release). The repo is private:
        // locally it resolves with the developer's git credentials; CI and Docker
        // resolve it with a read-only token (see docs/conventions/WireContract.md).
        .package(url: "https://github.com/rozd/show-menu-contracts.git", from: "0.6.0"),
        // 💳 LiqPay client (signing, status, webhook decoding). Manifest is swift-tools 6.3.
        //    Pinned to a revision; bump deliberately.
        .package(url: "https://github.com/summerhammer/liqpay-client.git", revision: "fcfdf522d121b5c12783a2745803ce9cecc82ddd"),
        // 🌐 HTTP client for the LiqPay checkout transport (a dedicated client with redirects disabled).
        //    Comes with Vapor; declared explicitly so the import is not transitive.
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.20.0"),
        // 🔌 Vapor transport for swift-openapi (registers the generated routes).
        .package(url: "https://github.com/swift-server/swift-openapi-vapor.git", from: "1.1.0"),
        // Runtime types shared by the generated code (HTTPBody, ServerMiddleware, ...).
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.12.0"),
    ],
    targets: [
        .target(
            name: "ShowMenuBackend",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Queues", package: "queues"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Passage", package: "passage"),
                .product(name: "PassageFluent", package: "passage-fluent"),
                .product(name: "ShowMenuContracts", package: "show-menu-contracts"),
                .product(name: "LiqPayClient", package: "liqpay-client"),
                .product(name: "LiqPayClientVapor", package: "liqpay-client"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
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
                "Integration/Fluent/README.md",
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
