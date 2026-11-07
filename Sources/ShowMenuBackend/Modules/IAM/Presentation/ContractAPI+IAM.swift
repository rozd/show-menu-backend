import ShowMenuContracts

/// IAM's witnesses: the user lookups and the Eventarc user/account lifecycle webhook.
extension ContractAPI {

    private var userController: UserController {
        UserController(
            getUserQueryHandler: app.deps.getUserQueryHandler,
            findUserQueryHandler: app.deps.findUserQueryHandler,
            logger: app.logger
        )
    }

    func findUsers(_ input: Operations.FindUsers.Input) async throws -> Operations.FindUsers.Output {
        try await userController.findUsers(input)
    }

    func getUser(_ input: Operations.GetUser.Input) async throws -> Operations.GetUser.Output {
        try await userController.getUser(input)
    }

    func handleEventarcEvent(
        _ input: Operations.HandleEventarcEvent.Input
    ) async throws -> Operations.HandleEventarcEvent.Output {
        try await EventarcController(app: app).handleEventarcEvent(input)
    }
}
