module SourceStyle

struct Location
    line::Int
    scoped::Bool
    terminal::Bool
end

Location(line::Int=1) = Location(line, false, false)
Location(location::Location, line::LineNumberNode) = Location(line.line, location.scoped, location.terminal)

name(node) = nothing
name(node::Symbol) = node
name(node::QuoteNode) = node.value
name(node::Expr) = node.head === :. && length(node.args) == 2 ? name(last(node.args)) : nothing

signature(node) = false
signature(node::Expr) = node.head === :call || (node.head in (:where, :(::)) && signature(first(node.args)))
definition(node::Expr) = node.head in (:function, :macro, :->) || (node.head === :(=) && signature(first(node.args)))
exits(node) = false
exits(node::Expr) = node.head in (:return, :break, :continue) || (node.head in (:block, :&&, :||) && any(exits, node.args))

function rule(node::Expr, location::Location)
    if node.head === :call && name(first(node.args)) in (:throw, :rethrow)
        string(name(first(node.args)))
    elseif node.head === :macrocall && name(first(node.args)) === Symbol("@assert")
        "@assert"
    elseif node.head === Symbol("try")
        "try"
    elseif node.head in (:error, :incomplete)
        "parse error"
    elseif node.head === :return && location.scoped && !location.terminal
        "early return"
    elseif node.head in (:&&, :||) && any(exits, node.args)
        "guard clause"
    else
        nothing
    end
end

record!(issues, ::Nothing, line) = issues
record!(issues, issue::String, line) = push!(issues, (line, issue))
inspect!(issues, node, location::Location) = issues

function body!(issues, node::Expr, location::Location)
    laststatement = findlast(argument -> !(argument isa LineNumberNode), node.args)
    current = location
    for (index, argument) in enumerate(node.args)
        if argument isa LineNumberNode
            current = Location(current, argument)
        else
            inspect!(issues, argument, Location(current.line, current.scoped, current.terminal && index == laststatement))
        end
    end
    issues
end

function inspect!(issues, node::Expr, location::Location)
    record!(issues, rule(node, location), location.line)
    if definition(node) && length(node.args) >= 2
        inspect!(issues, first(node.args), Location(location.line))
        inspect!(issues, last(node.args), Location(location.line, true, true))
    elseif node.head in (:block, :toplevel)
        body!(issues, node, location)
    else
        current = Location(location.line, node.head === :quote ? false : location.scoped, false)
        for argument in node.args
            if argument isa LineNumberNode
                current = Location(current, argument)
            else
                inspect!(issues, argument, current)
            end
        end
    end
    issues
end

function violations(source::AbstractString; single_exit=false)
    issues = inspect!(Tuple{Int,String}[], Meta.parseall(source), Location())
    single_exit ? issues : filter(issue -> !(last(issue) in ("early return", "guard clause")), issues)
end

function audit(root; single_exit=false)
    issues = Tuple{String,Int,String}[]
    for (directory, directories, files) in walkdir(root)
        filter!(!=(".git"), directories)
        for file in filter(name -> endswith(name, ".jl"), files)
            path = joinpath(directory, file)
            append!(issues, ((relpath(path, root), line, kind) for (line, kind) in violations(read(path, String); single_exit)))
        end
    end
    issues
end

end

syntax_name(node) = SourceStyle.name(node)
forbidden_syntax(source) = SourceStyle.violations(source)
lint_repository(root) = SourceStyle.audit(root)
