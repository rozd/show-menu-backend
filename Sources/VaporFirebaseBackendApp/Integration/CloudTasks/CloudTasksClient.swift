import Foundation

protocol CloudTasksClient: Sendable {
    func enqueue(task: CloudTask) async throws

    func enqueue(
        taskWithRequest request: CloudTask.HTTPRequest,
        named name: String?,
        scheduledAt scheduleTime: Date?,
    ) async throws

    func enqueue<T: Sendable & Codable>(
        taskWithRequestBody body: T,
        onURL url: String,
        named name: String?,
        scheduledAt scheduleTime: Date?,
    ) async throws
}

// MARK: - Cloud Task

struct CloudTask: Sendable, Codable {
    let name: String?
    var httpRequest: HTTPRequest
    let scheduleTime: String?
}

extension CloudTask {

    struct HTTPRequest: Sendable, Codable {
        let httpMethod: String
        let url: String
        let body: Data?
        var headers: [String: String]?
        var oidcToken: OIDCToken?
    }

}

extension CloudTask.HTTPRequest {

    struct OIDCToken: Sendable, Codable {
        let serviceAccountEmail: String
        let audience: String
    }
}

// MARK: - Create Task Request

struct CreateCloudTaskRequest: Sendable, Codable {
    let task: CloudTask
}

// MARK: - Cloud Task Client Default Implementation

extension CloudTasksClient {

    func enqueue(
        taskWithRequest request: CloudTask.HTTPRequest,
        named name: String? = nil,
        scheduledAt scheduleTime: Date? = nil
    ) async throws {
        return try await self.enqueue(
            task: .init(
                name: name,
                httpRequest: request,
                scheduleTime: scheduleTime?.asRFC3339String(),
            )
        )
    }

    func enqueue<T: Sendable & Codable>(
        taskWithRequestBody body: T,
        onURL url: String,
        named name: String? = nil,
        scheduledAt scheduleTime: Date? = nil,
    ) async throws {
        return try await self.enqueue(
            taskWithRequest: .init(
                httpMethod: "POST",
                url: url,
                body: try JSONEncoder().encode(body),
                headers: [
                    "Content-Type": "application/json",
                ],
                oidcToken: nil,
            ),
            named: name,
            scheduledAt: scheduleTime,
        )
    }
}

// MARK: - Utils

fileprivate extension Date {

    func asRFC3339String() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
    }

}
