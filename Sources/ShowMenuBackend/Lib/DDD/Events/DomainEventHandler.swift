//
//  DomainEventHandler.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 10/25/25.
//

protocol DomainEventHandler: Sendable {
    associatedtype Event: DomainEvent

    /// The specific event kind this handler responds to.
    /// Return `nil` to handle all kinds of this event type.
    static var kind: Event.Kind? { get }

    func handle(event: Event) async
}

extension DomainEventHandler {
    /// Default: handle every kind of this event type. Override to subscribe to a single kind.
    static var kind: Event.Kind? { nil }
}
