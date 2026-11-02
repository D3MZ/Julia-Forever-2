struct JuliaExecutor
    scope::Module
    output::IOBuffer
end

JuliaExecutor() = JuliaExecutor(Module(gensym(:Agent)), IOBuffer())
fork_executor(executor) = deepcopy(executor)
fork_executor(::JuliaExecutor) = JuliaExecutor()
close_executor!(executor) = nothing

begin_action_output!(executor, scope::ActionResourceScope) = nothing
function begin_action_output!(executor::JuliaExecutor, scope::ActionResourceScope)
    if !action_uses_executor(scope.parent, executor)
        truncate(executor.output, 0)
        seekstart(executor.output)
    end
    scope.output_start = position(executor.output)
    nothing
end

function julia_action_scope(executor::JuliaExecutor)
    scope = get(task_local_storage(), :JuliaForever2_action_resources, nothing)
    scope isa ActionResourceScope && scope.executor === executor ? scope : nothing
end

function prepare_julia_output!(executor::JuliaExecutor, ::Nothing)
    truncate(executor.output, 0)
    seekstart(executor.output)
    nothing
end
prepare_julia_output!(executor::JuliaExecutor, scope::ActionResourceScope) = nothing

julia_action_output!(executor::JuliaExecutor, ::Nothing) = String(take!(executor.output))
function julia_action_output!(executor::JuliaExecutor, scope::ActionResourceScope)
    output = executor.output
    start = min(scope.output_start, position(output))
    seek(output, start)
    result = String(read(output))
    truncate(output, start)
    seek(output, start)
    result
end

"""Execute code using backend-owned state; custom backends extend this method."""
execute!(executor, session, code, context::ExecutionContext) = executor(session, code)

is_julia_parse_error(node) = false
is_julia_parse_error(node::Expr) = node.head in (:error, :incomplete)

"""Evaluate source with an explicit path so Julia resolves nested includes within the workspace."""
function execute_julia!(executor::JuliaExecutor, code::AbstractString, filename::AbstractString)
    scope = julia_action_scope(executor)
    prepare_julia_output!(executor, scope)
    parsed = Meta.parseall(code; filename)
    invalid = findfirst(is_julia_parse_error, parsed.args)
    if isnothing(invalid)
        value = Base.include_string(executor.scope, code, filename)
        rendered = isnothing(value) ? "" : Base.invokelatest(repr, value)::String
        output = julia_action_output!(executor, scope)
        ExecutionResult(true, output * rendered, value)
    else
        diagnostic = first(parsed.args[invalid].args)
        ExecutionResult(false, sprint(showerror, diagnostic))
    end
end

execute!(executor::JuliaExecutor, code::AbstractString, ::ExecutionContext) = execute_julia!(executor, code, "agent-code.jl")

execute!(executor::JuliaExecutor, action::RunJulia, context::ExecutionContext) = execute!(executor, action.source, context)
