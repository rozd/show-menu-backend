//
//  CommandHandler.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 10/21/25.
//

protocol CommandHandler: Sendable {
    associatedtype Params: Command
    associatedtype Result: Sendable

    typealias Factory = @Sendable () -> Self

    var unitOfWork: any UnitOfWork { get  }

    /// The transaction-scoped body of the command.
    ///
    /// Runs **inside** a single `UnitOfWork` transaction (the `context` carries
    /// the live transaction + domain-event collector). Conforming handlers put
    /// their orchestration here — building the UseCase from `context` and
    /// running it — *without* opening a transaction of their own.
    ///
    /// Separating the body from the transaction boundary is what lets a
    /// cross-cutting decorator (see ``IdempotentCommandHandler``) wrap
    /// reserve / replay / store around the work **within the same
    /// transaction**. It mirrors the `Repository.doInsert` / `insert` split.
    func perform(_ command: Params, in context: any UnitOfWorkContext) async throws -> Result

    func handle(_ command: Params) async throws -> Result
}

extension CommandHandler {

    /// Opens the `UnitOfWork` and runs ``perform(_:in:)`` inside it, so the whole
    /// command body — including anything a decorator composes around it — shares
    /// one transaction and one post-commit domain-event dispatch.
    func handle(_ command: Params) async throws -> Result {
        try await unitOfWork.execute { context in
            try await perform(command, in: context)
        }
    }
}
