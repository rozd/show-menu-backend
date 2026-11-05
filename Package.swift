// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "VaporFirebaseBackendApp",
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
        // 🔥 Firebase API - gRPC-based Firestore client
        .package(url: "https://github.com/Rsych/FirebaseAPI.git", branch: "main"),
        // 📡 gRPC Swift NIO Transport - HTTP/2 transport for FirebaseAPI
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        // 🔑 Google Auth - Application Default Credentials and OAuth2 access tokens for GCP APIs
        .package(url: "https://github.com/googleapis/swift-google-auth", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "VaporFirebaseBackendApp",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Queues", package: "queues"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
                .product(name: "FirestoreAPI", package: "FirebaseAPI"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GoogleAuth", package: "swift-google-auth"),
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
                .target(name: "VaporFirebaseBackendApp"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "VaporFirebaseBackendAppTests",
            dependencies: [
                .target(name: "VaporFirebaseBackendApp"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "GoogleAuth", package: "swift-google-auth"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
