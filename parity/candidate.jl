using JuliaForever2
using JSON

function fixture_model(model)
    return JuliaForever2.ModelSpec(Symbol(model["provider"]), model["id"];
        api=get(model, "api", ""), kind=Symbol(get(model, "type", "chat")), metadata=model)
end

function scripted_descriptor(specification)
    models = [fixture_model(model) for model in specification["models"]]
    catalog = () -> get(specification, "catalog_error", false) ? error("scripted catalog failure") : models
    backend = (model, request, context) -> begin
        text = specification["prefix"] * "/" * specification["id"] * "/" * model.id * "/" * last(request.messages).content
        ProviderResult(Reply(:answer, text), nothing)
    end
    select = (directory, id) -> begin
        index = findfirst(model -> model.id == id && model.kind == :chat, models)
        isnothing(index) ? nothing : JuliaForever2.ModelProvider(models[index], backend)
    end
    factory = JuliaForever2.ProviderFactory(Returns(nothing); models=catalog, select)
    return JuliaForever2.ProviderDescriptor(Symbol(specification["id"]), specification["id"], factory)
end

function registry_scenario(scenario)
    registry = JuliaForever2.ProviderRegistry()
    outputs = Any[]
    for step in scenario["steps"]
        operation = step["operation"]
        if operation == "register"
            JuliaForever2.register_provider!(registry, scripted_descriptor(step["provider"]))
        elseif operation == "delete"
            JuliaForever2.unregister_provider!(registry, Symbol(step["provider"]))
        elseif operation == "clear"
            for descriptor in JuliaForever2.provider_descriptors(registry)
                JuliaForever2.unregister_provider!(registry, descriptor.id)
            end
        elseif operation == "providers"
            push!(outputs, [string(descriptor.id) for descriptor in JuliaForever2.provider_descriptors(registry)])
        elseif operation == "models"
            models = JuliaForever2.provider_models(registry; provider=get(step, "provider", nothing), kind=Symbol(get(step, "kind", "chat")))
            push!(outputs, deepcopy([model.metadata for model in models]))
        elseif operation == "lookup"
            model = JuliaForever2.provider_model(registry, Symbol(step["provider"]), step["id"]; kind=Symbol(get(step, "kind", "chat")))
            push!(outputs, isnothing(model) ? nothing : deepcopy(model.metadata))
        elseif operation == "dispatch"
            model = JuliaForever2.provider_model(registry, Symbol(step["provider"]), step["id"])
            if isnothing(model)
                push!(outputs, Dict("missing" => true))
            else
                provider = JuliaForever2.provider_from_name(Symbol(step["provider"]); dir="", registry, model=step["id"])
                request = ModelRequest([Message(:user, step["prompt"])], "", nothing, nothing, nothing)
                reply = if get(step, "legacy", false)
                    session = Session(Kernel())
                    result = provider(request.messages, session)
                    close(session)
                    result
                else
                    JuliaForever2.response_reply(JuliaForever2.respond(provider, request, ExecutionContext()))
                end
                push!(outputs, Dict("text" => reply.content, "stopReason" => (reply.kind == :answer ? "stop" : "error")))
            end
        else
            error("Unknown registry operation: $operation")
        end
    end
    return outputs
end

fixture_key(parent, key) = key
fixture_key(parent::AbstractVector, key::Integer) = key + 1
function mutate_fixture!(value, path, replacement)
    parent = value
    for key in path[1:end-1]
        parent = parent[fixture_key(parent, key)]
    end
    parent[fixture_key(parent, last(path))] = replacement
    return nothing
end

function store_scenario(scenario)
    store = JuliaForever2.MemoryModelStore()
    variables = Dict{String,Any}()
    outputs = Any[]
    for step in scenario["steps"]
        operation = step["operation"]
        if operation == "write"
            value = deepcopy(step["entry"])
            variables[step["variable"]] = value
            JuliaForever2.write_model_catalog!(store, Symbol(step["provider"]), value)
        elseif operation == "read"
            value = JuliaForever2.read_model_catalog(store, Symbol(step["provider"]))
            variables[step["variable"]] = value
            push!(outputs, deepcopy(value))
        elseif operation == "mutate"
            mutate_fixture!(variables[step["variable"]], step["path"], step["value"])
        elseif operation == "delete"
            JuliaForever2.delete_model_catalog!(store, Symbol(step["provider"]))
        else
            error("Unknown store operation: $operation")
        end
    end
    return outputs
end

function wire_scenario(scenario)
    metadata = scenario["model"]
    model = fixture_model(metadata)
    protocol = JuliaForever2.OpenAIChatProtocol(; compatibility=metadata["compat"])
    backend = JuliaForever2.HTTPModelBackend(protocol, scenario["endpoint"];
        credentials=Returns(["Authorization" => "Bearer fixture-only"]), options=scenario["options"])
    request = ModelRequest([Message(:user, scenario["prompt"])], scenario["instructions"], nothing, nothing, nothing)
    events = Any[]
    context = ExecutionContext(; emit=event -> event.kind == :model_stream && push!(events, deepcopy(event.data)))
    response = JuliaForever2.respond(JuliaForever2.ModelProvider(model, backend), request, context)
    close(context)
    return Dict("message" => response.message, "events" => events)
end

function run_scenarios(scenarios)
    outputs = Any[]
    for scenario in scenarios
        family = scenario["family"]
        result = family == "registry" ? registry_scenario(scenario) :
            family == "store" ? store_scenario(scenario) : wire_scenario(scenario)
        push!(outputs, Dict("id" => scenario["id"], "result" => result))
    end
    return outputs
end
print(JSON.json(run_scenarios(JSON.parse(read(stdin, String)))))
