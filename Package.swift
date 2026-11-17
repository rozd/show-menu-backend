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
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
