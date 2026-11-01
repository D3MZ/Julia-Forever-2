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

"""Evaluate source with an explicit path so Julia resolves nested includes within the workspace."""
function execute_julia!(executor::JuliaExecutor, code::AbstractString, filename::AbstractString)
    truncate(executor.output, 0)
    seekstart(executor.output)
    value = Base.include_string(executor.scope, code, filename)
    output = String(take!(executor.output))
    rendered = isnothing(value) ? "" : Base.invokelatest(repr, value)::String
    return ExecutionResult(true, output * rendered, value)
end

execute!(executor::JuliaExecutor, code::AbstractString, ::ExecutionContext) =
    execute_julia!(executor, code, "agent-code.jl")

execute!(executor::JuliaExecutor, action::RunJulia, context::ExecutionContext) =
    execute!(executor, action.source, context)

execute!(executor::JuliaExecutor, session, code::AbstractString, ::ExecutionContext) =
    execute_julia!(executor, code, joinpath(working_directory(session), "agent-code.jl"))

execute!(executor::JuliaExecutor, session, action::RunJulia, context::ExecutionContext) =
    execute!(executor, session, action.source, context)
