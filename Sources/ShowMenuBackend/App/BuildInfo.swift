import Foundation

/// Human-readable build info served by `GET /api/v1/version`:
/// `v<version>+<build>, revision: <K_REVISION>`.
///
/// Pure over an environment dictionary so it is testable without touching the process
/// environment; ``BuildInfo/current`` reads the real one.
enum BuildInfo {

    /// Build info of the running process.
    static var current: String {
        buildInfo(in: ProcessInfo.processInfo.environment)
    }
}

/// `v0.0.1+<branch>[-<sha>], revision: <rev>`; branch defaults to `local`, revision to `unknown`.
func buildInfo(in environment: [String: String]) -> String {
    let branch = environment["BUILD_BRANCH_NAME"] ?? "local"
    let sha = environment["BUILD_SHORT_SHA"] ?? ""
    let build = sha.isEmpty ? branch : "\(branch)-\(sha)"
    let revision = environment["K_REVISION"] ?? "unknown"
    return "v0.0.1+\(build), revision: \(revision)"
}
