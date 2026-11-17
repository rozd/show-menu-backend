import Vapor

func routes(_ app: Application) throws {
    // HTTP routes come only from the OpenAPI contract; Passage mounts /auth/* (and /me) itself.
    try app.registerContractHandlers()
}
