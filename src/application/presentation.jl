using Printf: @sprintf

usage_snapshot(session::Session) = usage_snapshot(session.conversation)

"""Format usage for legacy callers without giving the frontend mutable state."""
usage_label(usage::NamedTuple)::String = usage.reported ? render(usage) : ""

function render(usage::NamedTuple)
    output = IOBuffer()
    usage.partial && print(output, '~')
    print(output, '↑', usage.input_tokens, " ↓", usage.output_tokens)
    usage.cache_read_tokens > 0 && print(output, " R", usage.cache_read_tokens)
    usage.cache_write_tokens > 0 && print(output, " W", usage.cache_write_tokens)
    if (usage.cache_read_tokens > 0 || usage.cache_write_tokens > 0) && !isnothing(usage.cache_hit_rate)
        print(output, " CH", @sprintf("%.1f", usage.cache_hit_rate), '%')
    end
    usage.cost_known && print(output, " \$", round(usage.cost; digits=4))
    return String(take!(output))
end

usage_label(conversation::Conversation) = usage_label(usage_snapshot(conversation))

"""Compact count formatter matching Pi's footer thresholds."""
function footer_tokens(count::Integer)
    count < 1_000 && return string(count)
    count < 10_000 && return @sprintf("%.1fk", count / 1_000)
    count < 1_000_000 && return string(div(count + 500, 1_000), 'k')
    count < 10_000_000 && return @sprintf("%.1fM", count / 1_000_000)
    return string(div(count + 500_000, 1_000_000), 'M')
end

footer_context_window(value) = nothing
footer_context_window(::Bool) = nothing
footer_context_window(value::Integer) = 0 < value <= typemax(Int) ? Int(value) : nothing

footer_thinking(metadata) = nothing
function footer_thinking(metadata::AbstractDict)
    level = get(metadata, "thinkingLevel", get(metadata, "reasoningEffort", nothing))
    if level isa AbstractString && !isempty(level)
        return String(level)
    end
    return get(metadata, "reasoning", false) === true ? "off" : nothing
end

"""Return a stable model/status contract; external providers may extend this method."""
provider_footer_status(::Nothing) = (provider="", model="no-model", thinking=nothing,
    context_window=nothing, subscription=false)
provider_footer_status(provider) = (provider="", model=String(Base.invokelatest(provider_detail, provider)),
    thinking=nothing, context_window=nothing, subscription=false)

provider_footer_status(::DemoProvider) = (provider="demo", model="offline · /settings to connect",
    thinking=nothing, context_window=nothing, subscription=false)

provider_footer_status(provider::CodexProvider) = (provider="openai-codex", model=provider.model,
    thinking=provider.reasoning, context_window=nothing, subscription=true)

provider_footer_status(provider::OpenRouterProvider) = (provider="openrouter", model=provider.model,
    thinking=nothing, context_window=nothing, subscription=false)

function provider_footer_status(provider::OpenAIProvider)
    selected = lock(provider.catalog.lock) do
        !isempty(provider.model) ? provider.model :
            isempty(provider.catalog.models) ? "auto" : first(provider.catalog.models)
    end
    return (provider="chatgpt", model=selected, thinking=nothing,
        context_window=nothing, subscription=true)
end

function provider_footer_status(provider::ModelProvider)
    metadata = model_metadata(provider.model)
    limit = get(metadata, "contextWindow", get(metadata, "context_window", nothing))
    return (provider=string(provider.model.provider), model=provider.model.id,
        thinking=footer_thinking(metadata), context_window=footer_context_window(limit),
        subscription=get(metadata, "subscription", false) === true)
end

"""Capture one immutable UI snapshot from session accounting and the selected provider."""
function session_footer_snapshot(session::Session)
    model = with_component(session.kernel, :provider) do provider
        Base.invokelatest(provider_footer_status, provider)
    end
    return (usage=usage_snapshot(session), provider=model)
end

"""Format the model on the right; omit provider prefixes before sacrificing model text."""
function footer_model_label(model; include_provider=true)
    result = model.model
    if !isnothing(model.thinking)
        result *= model.thinking == "off" ? " • thinking off" : " • " * model.thinking
    end
    return include_provider && !isempty(model.provider) ? "($(model.provider)) " * result : result
end

"""Format lifetime totals separately from current prompt context and billing mode."""
function footer_usage_label(usage::NamedTuple, model)
    values = String[]
    if usage.reported
        prefix = usage.partial ? "~" : ""
        push!(values, prefix * "↑" * footer_tokens(usage.input_tokens))
        push!(values, "↓" * footer_tokens(usage.output_tokens))
        usage.cache_read_tokens > 0 && push!(values, "R" * footer_tokens(usage.cache_read_tokens))
        usage.cache_write_tokens > 0 && push!(values, "W" * footer_tokens(usage.cache_write_tokens))
        if (usage.cache_read_tokens > 0 || usage.cache_write_tokens > 0) && !isnothing(usage.cache_hit_rate)
            push!(values, @sprintf("CH%.1f%%", usage.cache_hit_rate))
        end
    end
    if usage.cost_known && (usage.cost > 0 || model.subscription)
        push!(values, "\$" * @sprintf("%.3f", usage.cost) * (model.subscription ? " (sub)" : ""))
    elseif model.subscription
        push!(values, "(sub)")
    end
    window = model.context_window
    if isnothing(window)
        push!(values, "?/?")
    elseif isnothing(usage.context_tokens)
        push!(values, "?/" * footer_tokens(window))
    else
        push!(values, @sprintf("%.1f%%", usage.context_tokens / window * 100) *
            "/" * footer_tokens(window))
    end
    return join(values, " ")
end
