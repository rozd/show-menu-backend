import Foundation
import Vapor

struct GCPCloudTasksClient: CloudTasksClient {
    static let defaultBaseURL = "https://cloudtasks.googleapis.com"

    let client: any Client
    let authProvider: any GCPAuthProvider
    let config: Config
    let logger: Logger

    func enqueue(task: CloudTask) async throws {
        let queuePath = "projects/\(config.projectId)/locations/\(config.location)/queues/\(config.queueId)"
        let url = "\(config.baseURL)/v2/\(queuePath)/tasks"

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")

        guard let token = try await authProvider.getAccessToken() else {
            throw CloudTasksError.authenticationFailed
        }
        headers.add(name: .authorization, value: "Bearer \(token)")

        var task = task
        task.httpRequest.oidcToken = .init(
            serviceAccountEmail: try Environment.gcpServiceAccountEmail,
            audience: config.serviceURL
        )

        let bodyData = try JSONEncoder().encode(
            CreateCloudTaskRequest(task: task)
        )

        let uri = URI(string: url)
        let response = try await client.post(uri, headers: headers) { req in
            req.body = .init(data: bodyData)
        }

        guard (200...299).contains(response.status.code) else {
            let responseBody = response.body.map { String(buffer: $0) } ?? ""
            logger.error("Cloud Tasks enqueue failed", metadata: [
                "status": .stringConvertible(response.status.code),
                "body": .string(responseBody),
            ])
            throw CloudTasksError.enqueueFailed(statusCode: Int(response.status.code))
        }

        logger.info("Cloud Tasks enqueued", metadata: ["url": .string(task.httpRequest.url)])
    }


}

// MARK: - Cloud Tasks Config

extension GCPCloudTasksClient {

    struct Config: Sendable {
        let projectId: String
        let location: String
        let queueId: String
        let baseURL: String
        let serviceURL: String
    }

}

extension GCPCloudTasksClient.Config {

    static func fromEnvironment() throws -> Self {
        .init(
            projectId: try Environment.gcpProjectId,
            location: Environment.gcpCloudTasksLocation,
            queueId: Environment.gcpCloudTasksQueueName,
            baseURL: Environment.gcpCloudTasksURL,
            serviceURL: try Environment.gcpThisServiceURL,
        )
    }

    static func fromEnvironment(
        with config: GoogleCloudPlatform.Configuration,
    ) -> Self {
        .init(
            projectId: config.projectID,
            location: Environment.gcpCloudTasksLocation,
            queueId: Environment.gcpCloudTasksQueueName,
            baseURL: Environment.gcpCloudTasksURL,
            serviceURL: config.thisServiceURL,
        )
    }
}

// MARK: - Cloud Tasks Errors

enum CloudTasksError: Error {
    case authenticationFailed
    case enqueueFailed(statusCode: Int)
}
