# FSM

Generic, value-type finite state machine.

- `FiniteStateMachine` — declared with an initial state + `StateTransition`s (each with an optional effect); `transition(to:)` throws `FSMError` on an invalid move.
