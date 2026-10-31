mutable struct TurnCounterState
    count::Int
end

const turn_counter_state = TurnCounterState(0)

install!(kernel, ComponentSpec(:turn_counter_state, turn_counter_state))

function turn_loop(session, prompt, max_steps)
    turn_counter_state.count += 1
    return JuliaForever2.default_loop!(session, prompt, max_steps)
end

install!(kernel, ComponentSpec(:loop, turn_loop; requires=[:turn_counter_state]))
