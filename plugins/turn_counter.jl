mutable struct TurnCounterState
    count::Int
    lock::ReentrantLock
end

struct CountingLoop{L,S}
    inner::L
    state::S
end

function (loop::CountingLoop)(session, prompt, max_steps)
    lock(loop.state.lock) do
        loop.state.count += 1
    end
    return loop.inner(session, prompt, max_steps)
end

const turn_counter_state = TurnCounterState(0, ReentrantLock())
install!(kernel, ComponentSpec(:turn_counter_state, turn_counter_state))
JuliaForever2.wrap_component!(kernel, :loop; fallback=JuliaForever2.default_loop!, requires=[:turn_counter_state]) do inner
    CountingLoop(inner, turn_counter_state)
end
