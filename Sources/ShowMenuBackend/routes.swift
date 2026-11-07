import Vapor

/// Every HTTP route is an operation in the OpenAPI contract (`show-menu-contracts`), served by
/// the generated `registerHandlers` through `ContractAPI`. Do not add routes here.
func routes(_ app: Application) throws {
    try app.registerContractHandlers()
}
