import Vapor

struct ItemController: Sendable {

    let getItemQueryHandler: GetItemQueryHandler
    let listItemsQueryHandler: ListItemsQueryHandler
    let createItemCommandHandler: CreateItemCommandHandler
    let updateItemCommandHandler: UpdateItemCommandHandler

    // MARK: - Endpoints

    @Sendable
    func getItem(req: Request) async throws -> Response {
        guard let itemId = req.parameters.get("itemId") else {
            throw Abort(.badRequest, reason: "Missing itemId parameter")
        }

        do {
            guard let dto = try await getItemQueryHandler.handle(GetItemQuery(itemId: itemId)) else {
                throw Abort(.notFound, reason: "Item not found")
            }
            // Advertise the current version as an ETag so clients can later send
            // it back in If-Match on mutating requests.
            let response = Response(status: .ok)
            try response.content.encode(dto, as: .json)
            response.setETag(Version(rawValue: dto.version))
            return response
        } catch let error as FirestoreError {
            req.logger.error("Firestore error", metadata: ["error": .string(error.localizedDescription)])
            switch error {
            case .serviceUnavailable:
                throw Abort(.serviceUnavailable, reason: "Service temporarily unavailable")
            default:
                throw Abort(.internalServerError, reason: "Internal server error")
            }
        }
    }

    /// `GET /v1/items?limit=&offset=`.
    ///
    /// Page bounds are clamped rather than rejected: `limit` is the server's
    /// protection against an unbounded scan, not a contract the client can fail.
    /// A negative `offset` is meaningless, so it floors at zero.
    @Sendable
    func listItems(req: Request) async throws -> ItemPageDTO {
        let limit = min(max(req.query[Int.self, at: "limit"] ?? Self.defaultPageLimit, 1), Self.maxPageLimit)
        let offset = max(req.query[Int.self, at: "offset"] ?? 0, 0)

        do {
            return try await listItemsQueryHandler.handle(ListItemsQuery(
                pagination: OffsetPagination(offset: offset, limit: limit)
            ))
        } catch let error as FirestoreError {
            req.logger.error("Firestore error", metadata: ["error": .string(error.localizedDescription)])
            switch error {
            case .serviceUnavailable:
                throw Abort(.serviceUnavailable, reason: "Service temporarily unavailable")
            default:
                throw Abort(.internalServerError, reason: "Internal server error")
            }
        }
    }

    private static let defaultPageLimit = 20
    private static let maxPageLimit = 100

    @Sendable
    func createItem(req: Request) async throws -> Response {
        let payload = try req.content.decode(CreateItemCommand.Payload.self)

        do {
            let command = CreateItemCommand(
                payload: payload,
                metadata: CommandMetadata(req: req)
            )
            let dto = try await createItemCommandHandler.handle(command)
            let response = Response(status: .created)
            try response.content.encode(dto, as: .json)
            response.setETag(Version(rawValue: dto.version))
            return response
        } catch let error as Item.Error {
            throw Abort(.badRequest, reason: error.errorDescription ?? "Validation error")
        } catch let error as FirestoreError {
            req.logger.error("Firestore error", metadata: ["error": .string(error.localizedDescription)])
            throw Abort(.internalServerError, reason: "Internal server error")
        }
    }

    @Sendable
    func updateItem(req: Request) async throws -> Response {
        guard let itemId = req.parameters.get("itemId") else {
            throw Abort(.badRequest, reason: "Missing itemId parameter")
        }
        let payload = try req.content.decode(UpdateItemCommand.Payload.self)
        let ifMatch = req.ifMatch

        // Optional fast path: reject a stale edit before opening a transaction.
        // The in-transaction check-and-set remains the authoritative backstop for
        // the (rare) race between this read and the commit.
        if let ifMatch {
            if let current = try await getItemQueryHandler.handle(GetItemQuery(itemId: itemId)),
               Version(rawValue: current.version) != ifMatch {
                throw Abort(.preconditionFailed, reason: "ETag does not match the current version")
            }
        }

        do {
            let command = UpdateItemCommand(
                itemId: itemId,
                expectedEntityVersion: ifMatch,
                payload: payload,
                metadata: CommandMetadata(req: req)
            )
            let dto = try await updateItemCommandHandler.handle(command)
            let response = Response(status: .ok)
            try response.content.encode(dto, as: .json)
            response.setETag(Version(rawValue: dto.version))
            return response
        } catch let error as Item.Error {
            throw Abort(.badRequest, reason: error.errorDescription ?? "Validation error")
        } catch let error as ConcurrencyError {
            // Stale write detected at commit: 412 when the client supplied an
            // If-Match precondition, otherwise 409 for an internal clash.
            req.logger.notice("Concurrency conflict", metadata: ["error": .string(String(describing: error))])
            throw Abort(ifMatch != nil ? .preconditionFailed : .conflict,
                        reason: "Item was modified by another writer")
        } catch let error as ApplicationError {
            if case .notFound = error {
                throw Abort(.notFound, reason: "Item not found")
            }
            throw Abort(.internalServerError, reason: "Internal server error")
        } catch let error as FirestoreError {
            req.logger.error("Firestore error", metadata: ["error": .string(error.localizedDescription)])
            throw Abort(.internalServerError, reason: "Internal server error")
        }
    }
}
