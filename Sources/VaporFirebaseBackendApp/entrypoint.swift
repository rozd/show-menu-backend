import Vapor
import Logging
import NIOCore
import NIOPosix

public enum VaporFirebaseBackendApp {
    public static func main() async throws {
        var env = try Environment.detect()

        if Environment.isRunningInCloudRun {
            let projectId = try Environment.gcpProjectId
            let metadataProvider = Logger.MetadataProvider {
                guard let traceId = RequestContext.traceId else { return [:] }
                return ["gcp/trace": .string("projects/\(projectId)/traces/\(traceId.rawValue)")]
            }
            LoggingSystem.bootstrap(
                { label, metadataProvider in
                    GoogleCloudPlatformLogHandler(label: label, metadataProvider: metadataProvider)
                },
                metadataProvider: metadataProvider
            )
        } else {
            try LoggingSystem.bootstrap(from: &env)
        }

        let app = try await Application.make(env)

        app.middleware.use(try GoogleCloudPlatformTraceMiddleware.initFromEnvironment(), at: .beginning)

        // This attempts to install NIO as the Swift Concurrency global executor.
        // You can enable it if you'd like to reduce the amount of context switching between NIO and Swift Concurrency.
        // Note: this has caused issues with some libraries that use `.wait()` and cleanly shutting down.
        // If enabled, you should be careful about calling async functions before this point as it can cause assertion failures.
        // let executorTakeoverSuccess = NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
        // app.logger.debug("Tried to install SwiftNIO's EventLoopGroup as Swift's global concurrency executor", metadata: ["success": .stringConvertible(executorTakeoverSuccess)])
        
        do {
            try await configure(app)
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
