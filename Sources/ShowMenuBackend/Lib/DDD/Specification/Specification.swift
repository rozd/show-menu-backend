//
//  Specification.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 10/21/25.
//

protocol Specification {
    associatedtype E: Entity

    func isSatisfied(by entity: E) -> Bool
}

// MARK: - Specification Combinators

extension Specification {
    static func &&<Other: Specification>(lhs: Self, rhs: Other) -> AndSpecification<Self, Other> where Other.E == Self.E {
        AndSpecification(lhs: lhs, rhs: rhs)
    }

    static func ||<Other: Specification>(lhs: Self, rhs: Other) -> OrSpecification<Self, Other> where Other.E == Self.E {
        OrSpecification(lhs: lhs, rhs: rhs)
    }

    static prefix func !(spec: Self) -> NotSpecification<Self> {
        NotSpecification(spec: spec)
    }
}

// MARK: - Specification Combinator Implementations

struct AndSpecification<LHS: Specification, RHS: Specification>: Specification where LHS.E == RHS.E {
    typealias E = LHS.E
    let lhs: LHS
    let rhs: RHS

    func isSatisfied(by entity: E) -> Bool {
        return lhs.isSatisfied(by: entity) && rhs.isSatisfied(by: entity)
    }
}

struct OrSpecification<LHS: Specification, RHS: Specification>: Specification where LHS.E == RHS.E {
    typealias E = LHS.E
    let lhs: LHS
    let rhs: RHS

    func isSatisfied(by entity: E) -> Bool {
        return lhs.isSatisfied(by: entity) || rhs.isSatisfied(by: entity)
    }
}

struct NotSpecification<Spec: Specification>: Specification {
    typealias E = Spec.E
    let spec: Spec

    func isSatisfied(by entity: E) -> Bool {
        return !spec.isSatisfied(by: entity)
    }
}
