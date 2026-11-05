import Foundation

actor InMemoryCloudTasksClient: CloudTasksClient {
    private(set) var enqueuedTasks: [CloudTask] = []

    func enqueue(task: CloudTask) async throws {
        enqueuedTasks.append(task)
    }

    func reset() {
        enqueuedTasks.removeAll()
    }
}
