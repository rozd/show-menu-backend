import Logging
import Testing
@testable import ShowMenuBackend

@Suite("GoogleCloudPlatformLogHandler")
struct GoogleCloudPlatformLogHandlerTests {

    @Test("value semantics — copy does not share logLevel or metadata")
    func valueSemantics() {
        var logger1 = Logger(label: "first logger", factory: GoogleCloudPlatformLogHandler.init)
        logger1.logLevel = .debug
        logger1[metadataKey: "only-on"] = "first"

        var logger2 = logger1
        logger2.logLevel = .error
        logger2[metadataKey: "only-on"] = "second"

        #expect(logger1.logLevel == .debug)
        #expect(logger2.logLevel == .error)
        #expect(logger1[metadataKey: "only-on"] == "first")
        #expect(logger2[metadataKey: "only-on"] == "second")
    }
}
