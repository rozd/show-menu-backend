import Foundation
import Logging

struct GoogleCloudPlatformLogHandler: LogHandler {
    private static let gcpTimeFormatter = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
    )

    private let label: String

    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?

    init(label: String, metadataProvider: Logger.MetadataProvider? = nil) {
        self.label = label
        self.metadataProvider = metadataProvider
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        var merged = self.metadata
        if let pm = metadataProvider?.get() { merged.merge(pm) { _, new in new } }
        if let cm = metadata { merged.merge(cm) { _, new in new } }

        var entry: [String: Any] = [
            "severity": gcpSeverity(for: level),
            "message": message.description,
            "time": Self.gcpTimeFormatter.format(.now),
            "logging.googleapis.com/sourceLocation": [
                "file": file, "line": "\(line)", "function": function
            ]
        ]

        func extract(_ key: String) -> String? {
            guard case .string(let v) = merged.removeValue(forKey: key) else { return nil }
            return v
        }

        if let t = extract("gcp/trace") {
            entry["logging.googleapis.com/trace"] = t
        }
        if let s = extract("gcp/spanId") {
            entry["logging.googleapis.com/spanId"] = s
        }
        if case .stringConvertible(let v) = merged.removeValue(forKey: "gcp/traceSampled") {
            entry["logging.googleapis.com/trace_sampled"] = (v as? Bool) ?? false
        }
        if case .dictionary(let dict) = merged.removeValue(forKey: "gcp/httpRequest") {
            entry["httpRequest"] = dict.mapValues { metadataValueToJSON($0) }
        }
        if !merged.isEmpty {
            entry["logging.googleapis.com/labels"] = merged.mapValues { "\($0)" }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let str = String(data: data, encoding: .utf8) else {
            return
        }

        print(str)
    }
}

// MARK: - GCP Log Metadata Helpers

extension GoogleCloudPlatformLogHandler {

    private func metadataValueToJSON(_ value: Logger.MetadataValue) -> Any {
        switch value {
        case .string(let s):
            return s
        case .stringConvertible(let v):
            if let b = v as? Bool { return b }
            let desc = v.description
            if let i = Int(desc) { return i }
            if let d = Double(desc), desc.contains(".") { return d }
            return desc
        case .dictionary(let d):
            return d.mapValues { metadataValueToJSON($0) }
        case .array(let a):
            return a.map { metadataValueToJSON($0) }
        }
    }

    func gcpSeverity(for level: Logger.Level) -> String {
        switch level {
        case .trace, .debug: return "DEBUG"
        case .info:          return "INFO"
        case .notice:        return "NOTICE"
        case .warning:       return "WARNING"
        case .error:         return "ERROR"
        case .critical:      return "CRITICAL"
        }
    }

}
