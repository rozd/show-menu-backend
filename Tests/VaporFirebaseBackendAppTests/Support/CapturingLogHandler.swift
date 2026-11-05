import Foundation
import Logging

/// A `LogHandler` that captures all log entries for test assertions.
///
/// Usage:
/// ```swift
/// let handler = CapturingLogHandler()
/// let logger = Logger(label: "test", factory: { _ in handler })
/// ```
final class CapturingLogHandler: LogHandler, @unchecked Sendable {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    private let lock = NSLock()
    private var _entries: [(level: Logger.Level, message: String, metadata: Logger.Metadata?)] = []

    var entries: [(level: Logger.Level, message: String, metadata: Logger.Metadata?)] {
        lock.withLock { _entries }
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        lock.withLock {
            _entries.append((level, message.description, metadata))
        }
    }

    // MARK: - Convenience accessors

    var infoEntries: [(message: String, metadata: Logger.Metadata?)] {
        lock.withLock { _entries.filter { $0.level == .info }.map { ($0.message, $0.metadata) } }
    }

    var errorEntries: [(message: String, metadata: Logger.Metadata?)] {
        lock.withLock { _entries.filter { $0.level == .error }.map { ($0.message, $0.metadata) } }
    }

    var debugEntries: [(message: String, metadata: Logger.Metadata?)] {
        lock.withLock { _entries.filter { $0.level == .debug }.map { ($0.message, $0.metadata) } }
    }

    var traceEntries: [(message: String, metadata: Logger.Metadata?)] {
        lock.withLock { _entries.filter { $0.level == .trace }.map { ($0.message, $0.metadata) } }
    }
}
