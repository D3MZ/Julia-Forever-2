"""Load separately hash-bound metadata for implemented API-key providers; rows are not access grants."""
function builtin_api_key_catalog(id::Symbol)
    path=joinpath(@__DIR__,"..","catalog_data","builtin-key-models.json")
    data=parse_json(read(path,String))
    providers=data isa AbstractDict ? get(data,"providers",nothing) : nothing
    rows=providers isa AbstractDict ? get(providers,String(id),nothing) : nothing
    isnothing(rows) ? ModelSpec[] : something(pi_model_catalog(JSON.json(rows),id),ModelSpec[])
end
builtin_api_key_descriptor(::Val{:groq};transport=nothing)=api_key_provider_descriptor(:groq,"Groq";
    models=builtin_api_key_catalog(:groq),endpoint="https://api.groq.com/openai/v1",
    models_url="https://api.groq.com/openai/v1/models",name="Groq API key",transport)
builtin_api_key_descriptor(::Val{:anthropic};transport=nothing)=api_key_provider_descriptor(:anthropic,"Anthropic";
    models=builtin_api_key_catalog(:anthropic),endpoint="https://api.anthropic.com",
    models_url="https://api.anthropic.com/v1/models",name="Anthropic API key",protocol=AnthropicMessagesProtocol(),paginate=true,transport)
builtin_api_key_descriptor(id::Symbol;kwargs...)=builtin_api_key_descriptor(Val(id);kwargs...)
