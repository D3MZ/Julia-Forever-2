import JSON

"""Opt into enforced JSON Schema tool arguments without changing existing opaque tool schemas."""
struct CheckedJSONSchema{S}
    definition::S
end

const CHECKED_SCHEMA_TYPES = Set(("object", "array", "string", "number", "integer", "boolean", "null"))
const CHECKED_SCHEMA_ANNOTATIONS = Set(("description", "title", "default", "examples"))

json_number(value) = value isa Real && !(value isa Bool) && isfinite(value) &&
    !(iszero(value) && signbit(value))

json_lossless(::Nothing) = true
json_lossless(::Bool) = true
json_lossless(::AbstractString) = true
json_lossless(value::Real) = json_number(value)
json_lossless(value::AbstractVector) = all(json_lossless, value)
json_lossless(value::AbstractDict) = all(key isa AbstractString && json_lossless(item) for (key, item) in value)
json_lossless(value::NamedTuple) = all(json_lossless, values(value))
json_lossless(value) = false

json_object(value) = value isa AbstractDict || value isa NamedTuple
json_property(value::AbstractDict, key) = get(value, key, missing)
json_property(value::NamedTuple, key) = get(value, Symbol(key), missing)
json_has_property(value::AbstractDict, key) = haskey(value, key)
json_has_property(value::NamedTuple, key) = haskey(value, Symbol(key))

json_scalar_equal(left, right) = left === right
json_scalar_equal(left::AbstractString, right::AbstractString) = left == right
json_scalar_equal(left::Real, right::Real) =
    left isa Bool || right isa Bool ? left === right : left == right

function json_schema_matches(kind, value)
    kind == "string" && return value isa AbstractString
    kind == "number" && return json_number(value)
    kind == "integer" && return json_number(value) && isinteger(value)
    kind == "boolean" && return value isa Bool
    kind == "null" && return isnothing(value)
    kind == "object" && return json_object(value)
    kind == "array" && return value isa AbstractVector
    return false
end

"""Reject schema keywords that this opt-in validator cannot enforce."""
function validate_checked_schema(node, path="schema")
    node isa AbstractDict || error("$path must be a JSON Schema object")
    all(key isa AbstractString for key in keys(node)) || error("$path must use string property names")
    kind = get(node, "type", missing)
    branches = get(node, "oneOf", missing)
    allowed = copy(CHECKED_SCHEMA_ANNOTATIONS)
    if !ismissing(branches)
        union!(allowed, ("oneOf",))
        branches isa AbstractVector && length(branches) >= 2 ||
            error("$path.oneOf must contain at least two schemas")
        for (index, branch) in enumerate(branches)
            validate_checked_schema(branch, "$path.oneOf[$(index - 1)]")
        end
    elseif ismissing(kind)
        nothing
    elseif kind in CHECKED_SCHEMA_TYPES
        push!(allowed, "type")
        if kind == "object"
            union!(allowed, ("properties", "required", "additionalProperties"))
            properties = get(node, "properties", Dict{String,Any}())
            properties isa AbstractDict && all(key isa AbstractString for key in keys(properties)) ||
                error("$path.properties must be a dictionary with string keys")
            for (name, child) in properties
                validate_checked_schema(child, "$path.properties.$name")
            end
            required = get(node, "required", String[])
            required isa AbstractVector && all(name -> name isa AbstractString && haskey(properties, name), required) ||
                error("$path.required must name declared string properties")
            get(node, "additionalProperties", true) isa Bool ||
                error("$path.additionalProperties must be a boolean")
        elseif kind == "array"
            push!(allowed, "items")
            haskey(node, "items") && validate_checked_schema(node["items"], "$path.items")
        else
            union!(allowed, ("enum", "const"))
            if haskey(node, "enum")
                choices = node["enum"]
                choices isa AbstractVector && !isempty(choices) && all(value -> json_schema_matches(kind, value), choices) ||
                    error("$path.enum must contain values of the declared type")
            end
            if haskey(node, "const")
                json_schema_matches(kind, node["const"]) || error("$path.const has the wrong type")
                if haskey(node, "enum")
                    any(value -> json_scalar_equal(value, node["const"]), node["enum"]) ||
                        error("$path.const must be included in enum")
                end
            end
        end
    else
        error("$path.type is not supported")
    end
    for key in keys(node)
        key in allowed || error("$path.$key is not supported by checked JSON tool schemas")
    end
    return nothing
end

function CheckedJSONSchema(schema::AbstractDict)
    definition = deepcopy(schema)
    validate_checked_schema(definition)
    return CheckedJSONSchema{typeof(definition)}(definition)
end

"""The model sees the underlying schema; plugins may project their own schema wrapper types."""
tool_schema_definition(schema) = schema
tool_schema_definition(schema::CheckedJSONSchema) = schema.definition

"""Plugins may specialize argument validation by their own schema types."""
tool_argument_violations(schema, arguments) = String[]
tool_argument_violations(schema::CheckedJSONSchema, arguments) =
    checked_json_violations(schema.definition, arguments, "arguments")

quoted_json_path(path) = "\"$path\""
json_value_violation(path) = [string(quoted_json_path(path), " must be a lossless JSON value")]

function json_literal_violations(node, value, path)
    if haskey(node, "enum") && !any(candidate -> json_scalar_equal(candidate, value), node["enum"])
        return [string(quoted_json_path(path), " must be one of ", JSON.json(node["enum"]))]
    end
    if haskey(node, "const") && !json_scalar_equal(node["const"], value)
        return [string(quoted_json_path(path), " must be ", JSON.json(node["const"]))]
    end
    return String[]
end

function checked_json_violations(node::AbstractDict, value, path::String)
    if haskey(node, "oneOf")
        count_matching = count(branch -> isempty(checked_json_violations(branch, value, path)), node["oneOf"])
        return count_matching == 1 ? String[] :
            [string(quoted_json_path(path), " must match exactly one oneOf branch (matched $count_matching)")]
    end
    kind = get(node, "type", nothing)
    isnothing(kind) && return json_lossless(value) ? String[] : json_value_violation(path)
    return checked_json_violations(Val(Symbol(kind)), node, value, path)
end

function checked_json_violations(::Val{:object}, node, value, path)
    json_object(value) || return [string(quoted_json_path(path), " must be an object")]
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
        ismissing(child) && continue
        location = isempty(path) ? key : "$path.$key"
        append!(violations, checked_json_violations(properties[key], child, location))
    end
    if get(node, "additionalProperties", true) === false
        for key in sort!(collect(string.(keys(value))))
            haskey(properties, key) && continue
            location = isempty(path) ? key : "$path.$key"
            push!(violations, "\"$location\" is not a declared property (additionalProperties: false)")
        end
    end
    isempty(violations) && !json_lossless(value) &&
        push!(violations, string(quoted_json_path(path), " must be a lossless JSON object"))
    return violations
end

function checked_json_violations(::Val{:array}, node, value, path)
    value isa AbstractVector || return [string(quoted_json_path(path), " must be an array")]
    violations = String[]
    if haskey(node, "items")
        for (index, item) in enumerate(value)
            append!(violations, checked_json_violations(node["items"], item, "$path[$(index - 1)]"))
        end
    end
    isempty(violations) && !json_lossless(value) &&
        push!(violations, string(quoted_json_path(path), " must be a dense lossless JSON array"))
    return violations
end

function checked_json_violations(::Val{:string}, node, value, path)
    value isa AbstractString || return [string(quoted_json_path(path), " must be a string")]
    return json_literal_violations(node, value, path)
end

function checked_json_violations(::Val{:number}, node, value, path)
    value isa Real && !(value isa Bool) ||
        return [string(quoted_json_path(path), " must be a number")]
    json_number(value) ||
        return [string(quoted_json_path(path), " must be a finite JSON number")]
    return json_literal_violations(node, value, path)
end

function checked_json_violations(::Val{:integer}, node, value, path)
    json_number(value) && isinteger(value) ||
        return [string(quoted_json_path(path), " must be an integer")]
    return json_literal_violations(node, value, path)
end

function checked_json_violations(::Val{:boolean}, node, value, path)
    value isa Bool || return [string(quoted_json_path(path), " must be a boolean")]
    return json_literal_violations(node, value, path)
end

function checked_json_violations(::Val{:null}, node, value, path)
    isnothing(value) || return [string(quoted_json_path(path), " must be null")]
    return json_literal_violations(node, value, path)
end

"""Validate a canonical tool output independently of its input argument schema."""
tool_output_violations(schema, value) = ["No tool output validator for schema type $(typeof(schema))"]
tool_output_violations(schema::CheckedJSONSchema, value) =
    checked_json_violations(schema.definition, value, "output")

tool_output_schema(schema) = schema
tool_output_schema(schema::AbstractDict) = CheckedJSONSchema(schema)
