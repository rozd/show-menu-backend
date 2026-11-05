//
//  Partial.swift
//  DualPricing
//
//  Created by Max Rozdobudko on 9/4/25.
//

struct Partial<Wrapped> {

    init(_ values: [PartialKeyPath<Wrapped>: Any] = [:]) {
        self.values = values
    }

    private var values: [PartialKeyPath<Wrapped>: Any]

    subscript<ValueType>(key: KeyPath<Wrapped, ValueType>) -> ValueType? {
        // `flatMap` unwraps the dictionary's own `Optional` *before* the cast, and
        // that ordering is load-bearing. Written as `values[key] as? ValueType`,
        // a missing key casts `Optional<Any>.none` to `ValueType` — and when
        // `ValueType` is a **marker protocol** such as `any Sendable`, that cast
        // carries no runtime check and *succeeds*, handing the caller a boxed
        // `nil` dressed up as a real value. Every dependency typed `any Sendable`
        // would then resolve to garbage.
        get { values[key].flatMap { $0 as? ValueType } }
        set { values[key] = newValue }
    }

}
