import Logging

protocol DomainEventDispatcher: Sendable {

    func dispatch(event: any DomainEvent) async

    func dispatch(events: [any DomainEvent]) async

    func register<Handler>(handler: Handler) async where Handler : DomainEventHandler
}

// MARK: - Default Implementation

actor InMemoryDomainEventDispatcher: DomainEventDispatcher {
    private struct HandlerBox: Sendable {
        let handle: @Sendable (any DomainEvent) async -> Void
    }

    private var handlers: [ObjectIdentifier: [HandlerBox]] = [:]
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func dispatch(event: any DomainEvent) async {
        let key = ObjectIdentifier(type(of: event))
        let handlerCount = handlers[key]?.count ?? 0
        logger.debug("Dispatching domain event", metadata: [
            "eventType": .string(String(describing: type(of: event))),
            "handlerCount": .string(String(handlerCount))
        ])
        for box in handlers[key] ?? [] {
            await box.handle(event)
        }
    }

    func dispatch(events: [any DomainEvent]) async {
        logger.debug("Dispatching domain events", metadata: [
            "count": .string(String(events.count))
        ])
        for event in events {
            await dispatch(event: event)
        }
    }

    func register<Handler>(handler: Handler) async where Handler : DomainEventHandler {
        let key = ObjectIdentifier(Handler.Event.self)
        let box = HandlerBox { event in
            guard let typed = event as? Handler.Event else {
                return
            }
            if let requiredKind = Handler.kind, typed.kind != requiredKind {
                return
            }
            await handler.handle(event: typed)
        }
        handlers[key, default: []].append(box)
        logger.debug("Registered domain event handler", metadata: [
            "eventType": .string(String(describing: Handler.Event.self)),
            "eventKind": .string(Handler.kind.map { String(describing: $0) } ?? "*")
        ])
    }

}
