"""Carry only a static image-policy rejection, never request data or credentials."""
struct ModelImagePolicyFailure
    reason::String
end
Base.show(io::IO,failure::ModelImagePolicyFailure)=print(io,"ModelImagePolicyFailure(",failure.reason,")")
const MODEL_IMAGE_MAX_BYTES=32*1024*1024
const MODEL_IMAGE_MAX_DEPTH=64
const MODEL_IMAGE_MAX_NODES=1_000_000
Base.@kwdef mutable struct ModelImageWireBudget
    bytes::Int=0
    nodes::Int=0
    canonical::Bool=true
    native_messages::Bool=false
    reason::String=""
end

function image_wire_add!(budget::ModelImageWireBudget,bytes::Int)
    if bytes<0 || bytes>MODEL_IMAGE_MAX_BYTES-budget.bytes
        budget.reason="Image policy rejected model input exceeding its encoded byte limit."
    else
        budget.bytes+=bytes
    end
    nothing
end
function image_wire_scan!(budget::ModelImageWireBudget,value,depth::Int)
    if isempty(budget.reason)
        budget.nodes+=1
        if depth>MODEL_IMAGE_MAX_DEPTH || budget.nodes>MODEL_IMAGE_MAX_NODES
            budget.reason="Image policy rejected model input exceeding its nesting or node limit."
        else
            image_wire_value!(budget,value,depth)
        end
    end
    nothing
end
image_wire_value!(budget,value,depth)=(budget.reason="Image policy cannot safely inspect this model input shape.";nothing)
image_wire_value!(budget,::Nothing,depth)=image_wire_add!(budget,4)
image_wire_value!(budget,value::Bool,depth)=image_wire_add!(budget,5)
image_wire_value!(budget,value::Integer,depth)=(budget.reason="Image policy rejected unsupported integer storage.";nothing)
image_wire_value!(budget,value::Union{Int8,Int16,Int32,Int64,Int128,UInt8,UInt16,UInt32,UInt64,UInt128,BigInt},depth)=image_wire_add!(budget,ndigits(value)+1)
image_wire_value!(budget,value::AbstractFloat,depth)=(budget.reason="Image policy rejected unsupported floating-point storage.";nothing)
function image_wire_value!(budget,value::Union{Float16,Float32,Float64},depth)
    isfinite(value) ? image_wire_add!(budget,64) : (budget.reason="Image policy rejected a non-finite JSON number.";nothing)
end
function image_wire_value!(budget,value::AbstractString,depth)
    if codeunit(value)!==UInt8
        budget.reason="Image policy rejected unsupported non-UTF-8 string storage."
    else
        image_wire_add!(budget,2)
        for byte in codeunits(value)
            if !isempty(budget.reason)
                break
            end
            image_wire_add!(budget,byte<0x20 ? 6 : byte in (0x22,0x5c) ? 2 : 1)
        end
    end
    nothing
end
function image_wire_value!(budget,value::Symbol,depth)
    budget.canonical=false
    image_wire_value!(budget,String(value),depth)
end
function image_wire_value!(budget,::Missing,depth)
    budget.canonical=false
    image_wire_add!(budget,4)
end
function image_wire_array!(budget,values,depth)
    count=length(values)
    if count>MODEL_IMAGE_MAX_BYTES-2
        budget.reason="Image policy rejected model input exceeding its encoded byte limit."
    else
        image_wire_add!(budget,2+count)
    end
    index=firstindex(values)
    while isempty(budget.reason) && index<=lastindex(values)
        image_wire_scan!(budget,values[index],depth+1)
        index+=1
    end
    nothing
end
image_wire_value!(budget,values::AbstractVector,depth)=image_wire_array!(budget,values,depth)
function image_wire_value!(budget,values::Tuple,depth)
    budget.canonical=false
    image_wire_array!(budget,values,depth)
end
function image_wire_object!(budget,values,depth)
    count=length(values)
    if count>div(MODEL_IMAGE_MAX_BYTES-2,2)
        budget.reason="Image policy rejected model input exceeding its encoded byte limit."
    else
        image_wire_add!(budget,2+2*count)
    end
    seen=Set{String}()
    for (key,value) in pairs(values)
        if !isempty(budget.reason)
            break
        else
            if !(key isa Union{AbstractString,Symbol})
                budget.reason="Image policy rejected an unsupported JSON object key."
            elseif key isa AbstractString && codeunit(key)!==UInt8
                budget.reason="Image policy rejected unsupported non-UTF-8 string storage."
            else
                effective=String(key)
                if effective in seen
                    budget.reason="Image policy rejected duplicate effective JSON keys."
                else
                    push!(seen,effective)
                    key isa AbstractString || (budget.canonical=false)
                    image_wire_scan!(budget,effective,depth+1)
                    image_wire_scan!(budget,value,depth+1)
                end
            end
        end
    end
    nothing
end
image_wire_value!(budget,value::AbstractDict,depth)=image_wire_object!(budget,value,depth)
function image_wire_value!(budget,value::NamedTuple,depth)
    budget.canonical=false
    image_wire_object!(budget,value,depth)
end
function image_wire_value!(budget,value::Message,depth)
    if budget.native_messages && depth==1
        image_wire_scan!(budget,value.content,depth+1)
    else
        budget.reason="Image policy rejected a native message object embedded in wire JSON."
    end
    nothing
end
function image_wire_budget(value;native_messages::Bool=false)
    budget=ModelImageWireBudget(;native_messages)
    image_wire_scan!(budget,value,0)
    budget
end

"""Normalize supported noncanonical JSON only after bounded, duplicate-key-aware inspection."""
function normalize_model_image_json(value)
    budget=image_wire_budget(value)
    if !isempty(budget.reason)
        ModelImagePolicyFailure(budget.reason)
    elseif budget.canonical
        value
    else
        task=Task() do
            output=IOBuffer(;maxsize=MODEL_IMAGE_MAX_BYTES)
            JSON.json(output,value;bufsize=8192)
            JSON.parse(String(take!(output));maxdepth=MODEL_IMAGE_MAX_DEPTH)
        end
        schedule(task)
        wait(task;throw=false)
        istaskfailed(task) ? ModelImagePolicyFailure("Image policy could not normalize bounded JSON model input.") : fetch(task)
    end
end
