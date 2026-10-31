struct JuliaExecutor
    scope::Module
    output::IOBuffer
end

JuliaExecutor() = JuliaExecutor(Module(gensym(:Agent)), IOBuffer())
fork_executor(executor) = deepcopy(executor)
fork_executor(::JuliaExecutor) = JuliaExecutor()
close_executor!(executor) = nothing

"""Execute code using backend-owned state; custom backends extend this method."""
execute!(executor, session, code, context::ExecutionContext) = executor(session, code)

function execute!(executor::JuliaExecutor, code::AbstractString, context::ExecutionContext)
    truncate(executor.output, 0)
    seekstart(executor.output)
    value = Base.include_string(executor.scope, code, "agent-code.jl")
    output = String(take!(executor.output))
    rendered = isnothing(value) ? "" : Base.invokelatest(repr, value)::String
    return ExecutionResult(true, output * rendered, value)
end

execute!(executor::JuliaExecutor, action::RunJulia, context::ExecutionContext) =
    execute!(executor, action.source, context)

execute!(executor::JuliaExecutor, session, code::AbstractString, context::ExecutionContext) =
    execute!(executor, code, context)
