struct StateTransition<State: Equatable & Sendable>: Sendable {
    let source: State
    let target: State
    let effect: (@Sendable () -> Void)?

    init(
        source: State,
        target: State,
        action: (@Sendable () -> Void)? = nil,
    ) {
        self.source = source
        self.target = target
        self.effect = action
    }
}

struct FiniteStateMachine<State: Equatable & Sendable>: Sendable {
    private(set) var state: State
    private let transitions: [StateTransition<State>]

    init(
        initial: State,
        transitions: [StateTransition<State>],
    ) {
        self.state = initial
        self.transitions = transitions
    }

    func getTransition(to target: State) -> StateTransition<State>? {
        transitions.first { $0.source == state && $0.target == target }
    }

    mutating func transition(to target: State) throws {
        guard let transition = getTransition(to: target) else {
            throw FSMError.invalidTransition(from: "\(state)", to: "\(target)")
        }
        state = target
        transition.effect?()
    }
}

enum FSMError: Error, CustomStringConvertible {
    case invalidTransition(from: String, to: String)

    var description: String {
        switch self {
        case .invalidTransition(let from, let to):
            "Invalid transition from \(from) to \(to)"
        }
    }
}
