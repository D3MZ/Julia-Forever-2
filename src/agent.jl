struct Message
    role::Symbol
    content::String
end

struct Reply
    kind::Symbol
    content::String
end

mutable struct Session
    kernel::Kernel
    messages::Vector{Message}
    scope::Module
    output::IOBuffer
    lock::ReentrantLock
end

function Session(kernel::Kernel)
    scope = Module(gensym(:Agent))
    output = IOBuffer()
    session = Session(kernel, Message[], scope, output, ReentrantLock())
    Core.eval(scope, :(using JuliaForever2))
    Core.eval(scope, :(const kernel = $(QuoteNode(kernel))))
    Core.eval(scope, :(const session = $(QuoteNode(session))))
    Core.eval(scope, :(const output = $(QuoteNode(output))))
    Core.eval(scope, :(include(path) = Base.include(@__MODULE__, path)))
    Core.eval(scope, :(print(args...) = Base.print(output, args...)))
    Core.eval(scope, :(println(args...) = Base.println(output, args...)))
    return session
end

function default_evaluate!(session::Session, code::AbstractString)
    truncate(session.output, 0)
    seekstart(session.output)
    task = @async Base.include_string(session.scope, code, "agent-code.jl")
    while !istaskdone(task)
        yield()
    end
    output = String(take!(session.output))
    if istaskfailed(task)
        return (ok=false, text=output * sprint(showerror, task.result))
    end
    value = task.result
    return (ok=true, text=output * (isnothing(value) ? "" : repr(value)))
end

function default_loop!(session::Session, prompt::AbstractString, max_steps::Int)
    lock(session.lock) do
        push!(session.messages, Message(:user, String(prompt)))
    end
    for _ in 1:max_steps
        lease = acquire!(session.kernel, :provider)
        isnothing(lease) && return (ok=false, text="No provider is configured.")
        messages = lock(session.lock) do
            copy(session.messages)
        end
        task = @async Base.invokelatest(lease.value, messages, session)
        while !istaskdone(task)
            yield()
        end
        release!(lease)
        istaskfailed(task) && return (ok=false, text=sprint(showerror, task.result))
        reply = task.result
        reply isa Reply || return (ok=false, text="Provider returned an invalid reply.")
        reply.kind == :error && return (ok=false, text=reply.content)
        lock(session.lock) do
            push!(session.messages, Message(:assistant, reply.content))
        end
        reply.kind == :answer && return (ok=true, text=reply.content)
        reply.kind == :code || return (ok=false, text="Unknown reply kind: $(reply.kind)")
        result = evaluate!(session, reply.content)
        lock(session.lock) do
            push!(session.messages, Message(:code_result, result.text))
        end
    end
    return (ok=false, text="Agent reached the step limit.")
end

function spawn_agent!(session::Session, prompt::AbstractString; max_steps::Int=20)
    child = Session(session.kernel)
    return (session=child, result=run_turn!(child, prompt; max_steps))
end

function use_component(fallback, session::Session, name::Symbol, args...)
    lease = acquire!(session.kernel, name)
    isnothing(lease) && return Base.invokelatest(fallback, session, args...)
    try
        return Base.invokelatest(lease.value, session, args...)
    finally
        release!(lease)
    end
end

evaluate!(session::Session, code::AbstractString) = use_component(default_evaluate!, session, :executor, code)
run_turn!(session::Session, prompt::AbstractString; max_steps::Int=20) = use_component(default_loop!, session, :loop, prompt, max_steps)
