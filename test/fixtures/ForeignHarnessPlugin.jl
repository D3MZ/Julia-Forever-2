module ForeignHarnessPlugin

using JuliaForever2

struct ForeignProvider{F}
    reply::F
end

JuliaForever2.respond(provider::ForeignProvider, messages, session, context::ExecutionContext) = provider.reply(messages, context)

mutable struct ForeignExecutor{A}
    actions::A
end

JuliaForever2.initialize_executor!(::ForeignExecutor, session) = nothing
JuliaForever2.fork_executor(executor::ForeignExecutor) = ForeignExecutor(empty(executor.actions))
JuliaForever2.close_executor!(::ForeignExecutor) = nothing

function JuliaForever2.execute!(executor::ForeignExecutor, session, action, context::ExecutionContext)
    push!(executor.actions, action)
    JuliaForever2.emit!(context, HarnessEvent(:foreign_execution, action))
    return ExecutionResult(true, "computed", (answer=42,))
end

struct TaggedLoop{F,S}
    inner::F
    seen::S
    tag::Symbol
end

function (loop::TaggedLoop)(session, prompt, limit)
    push!(loop.seen, loop.tag)
    return Base.invokelatest(loop.inner, session, prompt, limit)
end

end
