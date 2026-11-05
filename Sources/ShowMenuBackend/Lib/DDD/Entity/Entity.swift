//
//  Entity.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 9/5/25.
//

import Foundation

// MARK: - EntityId

protocol EntityId: Sendable, Hashable, Codable, LosslessStringConvertible, RawRepresentable {

    static func generate() -> Self

    init(rawValue: RawValue)
}

extension EntityId where RawValue == UUID {
    static func generate() -> Self {
        return Self(rawValue: UUID())
    }

    var description: String {
        return rawValue.uuidString
    }
}

extension EntityId where RawValue == String {
    static func generate() -> Self {
        return Self(rawValue: UUID().uuidString)
    }

    init?(_ description: String) {
        self.init(rawValue: description)
    }

    var description: String {
        return rawValue
    }
}

// MARK: - Entity

protocol Entity: AnyObject, Identifiable, Equatable where ID: EntityId {
    associatedtype Error: ValidationError
}

extension Entity where ID: EntityId {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}
