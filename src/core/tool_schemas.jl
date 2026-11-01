import JSON

"""Opt into enforced JSON Schema tool arguments without changing existing opaque tool schemas."""
struct CheckedJSONSchema{S}
    definition::S

    function CheckedJSONSchema{S}(definition::S) where {S}
        validate_checked_schema(definition)
        new{S}(definition)
    end
end

const CHECKED_SCHEMA_TYPES = Set(("object", "array", "string", "number", "integer", "boolean", "null"))
const CHECKED_SCHEMA_ANNOTATIONS = Set(("description", "title", "default", "examples"))

json_number(value) = false
json_number(value::Real) = isfinite(value) && !(iszero(value) && signbit(value))
json_number(::Bool) = false

json_lossless(::Nothing) = true
json_lossless(::Bool) = true
json_lossless(::AbstractString) = true
json_lossless(value::Real) = json_number(value)
json_lossless(value::AbstractVector) = all(json_lossless, value)
json_lossless(value::AbstractDict) = all(key isa AbstractString && json_lossless(item) for (key, item) in value)
json_lossless(value::NamedTuple) = all(json_lossless, values(value))
json_lossless(value) = false

json_object(value) = false
json_object(value::AbstractDict) = true
json_object(value::NamedTuple) = true
json_property(value::AbstractDict, key) = get(value, key, missing)
json_property(value::NamedTuple, key) = get(value, Symbol(key), missing)
json_has_property(value::AbstractDict, key) = haskey(value, key)
json_has_property(value::NamedTuple, key) = haskey(value, Symbol(key))

json_scalar_equal(left, right) = left === right
json_scalar_equal(left::AbstractString, right::AbstractString) = left == right
json_scalar_equal(left::Real, right::Real) = left == right
json_scalar_equal(left::Bool, right::Real) = false
json_scalar_equal(left::Real, right::Bool) = false
json_scalar_equal(left::Bool, right::Bool) = left === right

json_schema_matches(kind, value) = false
json_schema_matches(kind, ::Nothing) = kind == "null"
json_schema_matches(kind, ::Bool) = kind == "boolean"
json_schema_matches(kind, ::AbstractString) = kind == "string"
json_schema_matches(kind, value::Real) = json_number(value) && (kind == "number" || kind == "integer" && isinteger(value))
json_schema_matches(kind, ::Union{AbstractDict,NamedTuple}) = kind == "object"
json_schema_matches(kind, ::AbstractVector) = kind == "array"
"""Reject schema keywords that this opt-in validator cannot enforce."""
validate_checked_schema(node, path="schema") = error("$path must be a JSON Schema object")

validate_checked_schema(node::AbstractDict, path="schema") = all(key isa AbstractString for key in keys(node)) ? validateschema(node, path) : error("$path must use string property names")

function validateschema(node, path)
    kind = get(node, "type", missing)
    branches = get(node, "oneOf", missing)
    allowed = copy(CHECKED_SCHEMA_ANNOTATIONS)
    if !ismissing(branches)
        branches!(allowed, branches, path)
    elseif !ismissing(kind)
        keywords!(allowed, kind, node, path)
    end
    foreach(key -> key in allowed ? nothing : error("$path.$key is not supported by checked JSON tool schemas"), keys(node))
    nothing
end

function branches!(allowed, branches, path)
    if branches isa AbstractVector && length(branches) >= 2
        push!(allowed, "oneOf")
        for (index, branch) in enumerate(branches)
            validate_checked_schema(branch, "$path.oneOf[$(index - 1)]")
        end
    else
        error("$path.oneOf must contain at least two schemas")
    end
    nothing
end

function keywords!(allowed, kind, node, path)
    if kind in CHECKED_SCHEMA_TYPES
        push!(allowed, "type")
        fields!(allowed, kind, node, path)
    else
        error("$path.type is not supported")
    end
    nothing
end

function fields!(allowed, kind, node, path)
    if kind == "object"
        properties!(allowed, node, path)
    elseif kind == "array"
        push!(allowed, "items")
        if haskey(node, "items")
            validate_checked_schema(node["items"], "$path.items")
        end
    else
        literals!(allowed, kind, node, path)
    end
    nothing
end

function properties!(allowed, node, path)
    union!(allowed, ("properties", "required", "additionalProperties"))
    children = properties(get(node, "properties", Dict{String,Any}()), path)
    for (name, child) in children
        validate_checked_schema(child, "$path.properties.$name")
    end
    required(get(node, "required", String[]), children, path)
    additional(get(node, "additionalProperties", true), path)
    nothing
end

properties(value, path) = value isa AbstractDict && all(key isa AbstractString for key in keys(value)) ? value : error("$path.properties must be a dictionary with string keys")

required(value, properties, path) = value isa AbstractVector && all(name -> name isa AbstractString && haskey(properties, name), value) ? value : error("$path.required must name declared string properties")

additional(value::Bool, path) = value
additional(value, path) = error("$path.additionalProperties must be a boolean")

function literals!(allowed, kind, node, path)
    union!(allowed, ("enum", "const"))
    if haskey(node, "enum")
        choices(node["enum"], kind, path)
    end
    if haskey(node, "const")
        constant(node, kind, path)
    end
    nothing
end

choices(value, kind, path) = value isa AbstractVector && !isempty(value) && all(item -> json_schema_matches(kind, item), value) ? value : error("$path.enum must contain values of the declared type")

function constant(node, kind, path)
    if !json_schema_matches(kind, node["const"])
        error("$path.const has the wrong type")
    elseif haskey(node, "enum") && !any(value -> json_scalar_equal(value, node["const"]), node["enum"])
        error("$path.const must be included in enum")
    else
        node["const"]
    end
end
CheckedJSONSchema(schema::AbstractDict) = checked(deepcopy(schema))
checked(schema::S) where {S<:AbstractDict} = CheckedJSONSchema{S}(schema)
"""The model sees the underlying schema; plugins may project their own schema wrapper types."""
tool_schema_definition(schema) = schema
tool_schema_definition(schema::CheckedJSONSchema) = schema.definition

"""Plugins may specialize argument validation by their own schema types."""
tool_argument_violations(schema, arguments) = String[]
tool_argument_violations(schema::CheckedJSONSchema, arguments) = checked_json_violations(schema.definition, arguments, "arguments")

"""Plugins may specialize validation of successful values with their own output schema types."""
tool_output_violations(schema, value) = String[]
tool_output_violations(schema::CheckedJSONSchema, value) = checked_json_violations(schema.definition, value, "result")

quoted_json_path(path) = "\"$path\""
json_value_violation(path) = [string(quoted_json_path(path), " must be a lossless JSON value")]

function json_literal_violations(node, value, path)
    if haskey(node, "enum") && !any(candidate -> json_scalar_equal(candidate, value), node["enum"])
        [string(quoted_json_path(path), " must be one of ", JSON.json(node["enum"]))]
    elseif haskey(node, "const") && !json_scalar_equal(node["const"], value)
        [string(quoted_json_path(path), " must be ", JSON.json(node["const"]))]
    else
        String[]
    end
end
function checked_json_violations(node::AbstractDict, value, path::String)
    if haskey(node, "oneOf")
        count_matching = count(branch -> isempty(checked_json_violations(branch, value, path)), node["oneOf"])
        count_matching == 1 ? String[] : [string(quoted_json_path(path), " must match exactly one oneOf branch (matched $count_matching)")]
    else
        violations(get(node, "type", nothing), node, value, path)
    end
end

violations(::Nothing, node, value, path) = json_lossless(value) ? String[] : json_value_violation(path)
violations(kind, node, value, path) = checked_json_violations(Val(Symbol(kind)), node, value, path)

"""Check only values not already covered by declared property schemas."""
function json_unchecked_properties_lossless(value, properties)
    all(pairs(value)) do (key, item)
        name = propertyname(value, key)
        !isnothing(name) && !ismissing(item) && (haskey(properties, name) || json_lossless(item))
    end
end

propertyname(value, key) = nothing
propertyname(value, key::AbstractString) = key
propertyname(value::NamedTuple, key::Symbol) = String(key)

checked_json_violations(::Val{:object}, node, value, path) = [string(quoted_json_path(path), " must be an object")]

function checked_json_violations(::Val{:object}, node, value::Union{AbstractDict,NamedTuple}, path)
    properties = get(node, "properties", Dict{String,Any}())
    violations = String[]
    for key in get(node, "required", String[])
        if !json_has_property(value, key) || ismissing(json_property(value, key))
            location = isempty(path) ? key : "$path.$key"
            push!(violations, "missing required property \"$location\"")
        end
    end
    for key in sort!(collect(keys(properties)))
        child = json_property(value, key)
        if !ismissing(child)
            location = isempty(path) ? key : "$path.$key"
            append!(violations, checked_json_violations(properties[key], child, location))
        end
    end
    if get(node, "additionalProperties", true) === false
        for key in sort!(collect(string.(keys(value))))
            if !haskey(properties, key)
                location = isempty(path) ? key : "$path.$key"
                push!(violations, "\"$location\" is not a declared property (additionalProperties: false)")
            end
        end
    end
    if isempty(violations) && !json_unchecked_properties_lossless(value, properties)
        push!(violations, string(quoted_json_path(path), " must be a lossless JSON object"))
    end
    violations
end

checked_json_violations(::Val{:array}, node, value, path) = [string(quoted_json_path(path), " must be an array")]

function checked_json_violations(::Val{:array}, node, value::AbstractVector, path)
    violations = String[]
    if haskey(node, "items")
        for (index, item) in enumerate(value)
            append!(violations, checked_json_violations(node["items"], item, "$path[$(index - 1)]"))
        end
    end
    if isempty(violations) && !haskey(node, "items") && !json_lossless(value)
        push!(violations, string(quoted_json_path(path), " must be a dense lossless JSON array"))
    end
    violations
end

checked_json_violations(::Val{:string}, node, value, path) = [string(quoted_json_path(path), " must be a string")]
checked_json_violations(::Val{:string}, node, value::AbstractString, path) = json_literal_violations(node, value, path)
checked_json_violations(::Val{:number}, node, value, path) = [string(quoted_json_path(path), " must be a number")]
checked_json_violations(::Val{:number}, node, value::Bool, path) = [string(quoted_json_path(path), " must be a number")]
checked_json_violations(::Val{:number}, node, value::Real, path) = json_number(value) ? json_literal_violations(node, value, path) : [string(quoted_json_path(path), " must be a finite JSON number")]
checked_json_violations(::Val{:integer}, node, value, path) = [string(quoted_json_path(path), " must be an integer")]
checked_json_violations(::Val{:integer}, node, value::Real, path) = json_number(value) && isinteger(value) ? json_literal_violations(node, value, path) : [string(quoted_json_path(path), " must be an integer")]
checked_json_violations(::Val{:boolean}, node, value, path) = [string(quoted_json_path(path), " must be a boolean")]
checked_json_violations(::Val{:boolean}, node, value::Bool, path) = json_literal_violations(node, value, path)
checked_json_violations(::Val{:null}, node, value, path) = [string(quoted_json_path(path), " must be null")]
checked_json_violations(::Val{:null}, node, ::Nothing, path) = json_literal_violations(node, nothing, path)
