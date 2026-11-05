enum ApplicationError: Error {
    case notFound(entity: String, id: any EntityId)
    case invalidInput(reason: String)
}
