function syntax_name(node)
    node isa Symbol && return node
    if node isa Expr && node.head === :. && length(node.args) == 2 && node.args[2] isa QuoteNode
        return node.args[2].value
    end
    return nothing
end

function inspect_syntax!(issues, node, line=1)
    node isa Expr || return
    if node.head === :call && syntax_name(node.args[1]) in (:throw, :rethrow)
        push!(issues, (line, string(syntax_name(node.args[1]))))
    elseif node.head === :macrocall && syntax_name(node.args[1]) === Symbol("@assert")
        push!(issues, (line, "@assert"))
    elseif node.head === Symbol("try") && node.args[3] !== false
        push!(issues, (line, "try/catch"))
    elseif node.head in (:error, :incomplete)
        push!(issues, (line, "parse error"))
    end
    for arg in node.args
        if arg isa LineNumberNode
            line = arg.line
        else
            inspect_syntax!(issues, arg, line)
        end
    end
end

function forbidden_syntax(source)
    issues = Tuple{Int, String}[]
    inspect_syntax!(issues, Meta.parseall(source))
    return issues
end

function lint_repository(root)
    issues = Tuple{String, Int, String}[]
    for (dir, dirs, files) in walkdir(root)
        filter!(!=(".git"), dirs)
        for file in files
            endswith(file, ".jl") || continue
            path = joinpath(dir, file)
            for (line, kind) in forbidden_syntax(read(path, String))
                push!(issues, (relpath(path, root), line, kind))
            end
        end
    end
    return issues
end
