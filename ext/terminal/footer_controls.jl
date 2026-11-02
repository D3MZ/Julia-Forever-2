public FooterHostState, refresh_footer_controls!, footer_control_snapshot, footer_control_lines, footer_control_draw!

"""UI-owned footer caches; credential, catalog and location refreshes happen outside rendering."""
Base.@kwdef mutable struct FooterHostState
    key::Any=nothing
    accounting::FooterAccounting=FooterAccounting()
    context_tokens::Union{Nothing,Float64}=0.0
    context_estimated::Bool=false
    name::Union{Nothing,String}=nothing
    usage_unknown::Bool=false
    usage_partial::Bool=false
    cost_unknown::Bool=false
    cost_estimated::Bool=false
    models::Vector{JuliaForever2.ModelSpec}=JuliaForever2.ModelSpec[]
    subscriptions::Dict{Symbol,Bool}=Dict{Symbol,Bool}()
    branch::Union{Nothing,String}=nothing
    home::Union{Nothing,String}=nothing
    statuses::Vector{Pair{String,String}}=Pair{String,String}[]
    experimental::Bool=false
    routed::Union{Nothing,FooterModel}=nothing
    routed_thinking::Union{Nothing,String}=nothing
    scans::Int=0
end

"""Lazily attach state to the transcript owner, which is replaced on session transitions."""
function footer_control_state!(app::App)
    if isnothing(app.transcript.footer)
        app.transcript.footer=FooterHostState(;home=homedir())
    end
    app.transcript.footer::FooterHostState
end

"""Refresh an explicitly available cached catalog and verified auth facts, never credentials themselves."""
function refresh_footer_controls!(app::App,state::FooterHostState=footer_control_state!(app);
        models=state.models,subscriptions=state.subscriptions,branch=state.branch,home=state.home)
    state.models=JuliaForever2.ModelSpec[deepcopy(model) for model in models if model.kind==:chat]
    state.subscriptions=Dict{Symbol,Bool}(subscriptions)
    state.branch=isnothing(branch) ? nothing : String(branch)
    state.home=isnothing(home) ? nothing : String(home)
    state
end

"""Prepare replacement-only footer facts under supervision, never retain the previous account or archive cache."""
function prepare_footer_controls(app::App, session::Session)
    operation = Task() do
        state = FooterHostState(; home=homedir())
        workspace = working_directory(session)
        refresh_footer_controls!(app, state; models=menu_model_snapshot(app; kernel=session.kernel),
            branch=startup_host_branch(workspace))
        (; state, directory=directory_label(workspace; branch=state.branch))
    end
    schedule(operation)
    wait(operation; throw=false)
    if istaskfailed(operation)
        state = FooterHostState(; home=homedir(), statuses=["jf2.footer"=>"Session footer unavailable"])
        (; state, directory=directory_label(working_directory(session); branch=nothing))
    else
        fetch(operation)
    end
end

footer_control_field(value,key,default=nothing)=default
footer_control_field(value::AbstractDict,key,default=nothing)=get(value,key,default)
footer_control_chars(value)=0
footer_control_chars(value::AbstractString)=sum(character->Int(character)>0xffff ? 2 : 1,value;init=0)
function footer_control_content_chars(content::AbstractVector)
    sum(block->get(block,"type","")=="image" ? 4800 : get(block,"type","")=="text" ? footer_control_chars(get(block,"text","")) : 0,content;init=0)
end
footer_control_content_chars(content)=footer_control_chars(content)

footer_control_assistant_block_chars(block)=0
function footer_control_assistant_block_chars(block::AbstractDict)
    kind=get(block,"type","")
    kind=="text" ? footer_control_chars(get(block,"text","")) : kind=="thinking" ? footer_control_chars(get(block,"thinking","")) :
        kind=="toolCall" ? footer_control_chars(get(block,"name",""))+footer_control_chars(JSON.json(get(block,"arguments",Dict()))) : 0
end
footer_control_assistant_chars(content)=footer_control_chars(content)
footer_control_assistant_chars(content::AbstractVector)=sum(footer_control_assistant_block_chars,content;init=0)

"""Estimate only the effective projected content, using UTF-16 character counts and declared image cost."""
function footer_control_estimate(message::AbstractDict)
    role=get(message,"role","")
    content=get(message,"content",Any[])
    chars=0
    if role in ("system","user","custom","toolResult")
        chars=footer_control_content_chars(content)
        if role=="system"
            sections=get(message,"sections",Dict())
            chars+=sum(footer_control_chars,values(sections);init=0)
            tools=get(message,"toolsAdded",nothing)
            isnothing(tools) || (chars+=footer_control_chars(JSON.json(tools)))
        end
    elseif role=="assistant"
        chars=footer_control_assistant_chars(content)
    elseif role=="bashExecution"
        chars=footer_control_chars(get(message,"command",""))+footer_control_chars(get(message,"output",""))
    elseif role in ("branchSummary","compactionSummary")
        chars=footer_control_chars(get(message,"summary",""))
    end
    Float64(cld(chars,4))
end

footer_control_text(content::AbstractString)=String(content)
footer_control_text(content::AbstractVector)=join((get(block,"text","") for block in content if get(block,"type","")=="text"),"\n")

"""Fold system deltas before estimating the active prompt, including removed sections and tools."""
function footer_control_system(messages)
    texts=String[]
    sections=Dict{String,Any}()
    tools=Dict{String,Any}()
    present=false
    for message in messages
        if get(message,"role","")=="system"
            present|=haskey(message,"timestamp")
            text=footer_control_text(get(message,"content",""))
            isempty(text) || push!(texts,text)
            for (name,value) in get(message,"sections",Dict())
                isnothing(value) ? delete!(sections,name) : (sections[name]=value)
            end
            for tool in get(message,"toolsRemoved",Any[])
                delete!(tools,tool["name"])
            end
            for tool in get(message,"toolsAdded",Any[])
                tools[tool["name"]]=tool
            end
        end
    end
    count=0.0
    if present || !isempty(tools)
        message=Dict{String,Any}("role"=>"system","content"=>join(texts,"\n\n"),"sections"=>sections)
        isempty(tools) || (message["toolsAdded"]=collect(values(tools)))
        count=footer_control_estimate(message)
    end
    count
end

function footer_control_usage_tokens(message)
    usage=footer_control_field(message,"usage")
    total=footer_control_field(usage,"totalTokens")
    accounting=JuliaForever2.message_usage_accounting(message)
    report=accounting.report
    accounting.provenance==:native && (total=nothing)
    complete=all(!isnothing,(report.input_tokens,report.output_tokens,report.cache_read_tokens,report.cache_write_tokens))
    tokens=total isa Real && !(total isa Bool) && isfinite(total) && total>0 ? Float64(total) : complete ?
        Float64(something(report.input_tokens,0))+Float64(something(report.output_tokens,0))+Float64(something(report.cache_read_tokens,0))+Float64(something(report.cache_write_tokens,0)) : 0.0
    get(message,"role","")=="assistant" && !(get(message,"stopReason","") in ("aborted","error")) ? tokens : 0.0
end

"""Invalidate pre-edit usage and show unknown after compaction until a valid later assistant report."""
function footer_control_context(entries,leaf)
    projection=JuliaForever2.timeline_projection(entries;leaf)
    indices=Dict(entry["id"]=>index for (index,entry) in enumerate(entries))
    path=JuliaForever2.timeline_path_entries(entries,indices,leaf)
    order=Dict(entry["id"]=>index for (index,entry) in enumerate(path))
    invalidating=findlast(entry->entry["type"] in ("compaction","context_edit"),path)
    compact=findlast(entry->entry["type"]=="compaction",path)
    latest_tokens=0.0
    latest_message=0
    latest_entry=0
    cursor=0
    for entry in projection.entries
        for message in entry.messages
            cursor+=1
            count=footer_control_usage_tokens(message)
            if count>0
                latest_tokens=count
                latest_message=cursor
                latest_entry=get(order,entry.source_entry["id"],0)
            end
        end
    end
    tokens=nothing
    estimated=false
    if isnothing(compact) || latest_entry>compact
        if latest_message>0 && (isnothing(invalidating) || latest_entry>invalidating)
            trailing=projection.messages[latest_message+1:end]
            tokens=latest_tokens+sum(footer_control_estimate,trailing;init=0.0)
            estimated=!isempty(trailing)
        else
            tokens=footer_control_system(projection.messages)+sum(footer_control_estimate,
                [message for message in projection.messages if get(message,"role","")!="system"];init=0.0)
            estimated=!isempty(projection.messages)
        end
    end
    (;tokens,estimated)
end

function footer_control_accounting(entries)
    events=FooterUsageEvent[]
    unknown=partial=cost_unknown=cost_estimated=false
    latest_prompt_known=true
    name=nothing
    for entry in entries
        kind=Symbol(entry["type"]::AbstractString)::Symbol
        message=get(entry,"message",nothing)
        role=footer_control_field(message,"role")
        accepted=kind in (:usage,:branch_summary,:compaction) || kind==:message && role in ("assistant","toolResult")
        payload=kind==:message ? message : entry
        raw=footer_control_field(payload,"usage")
        observed=JuliaForever2.message_usage_accounting(payload)
        report=observed.report
        unreported=observed.provenance==:native && all(isnothing,
            (report.input_tokens,report.output_tokens,report.cache_read_tokens,report.cache_write_tokens,report.cost))
        if accepted && unreported
            unknown=true
            kind==:message && role=="assistant" && (latest_prompt_known=false)
        elseif accepted && (!isnothing(raw) || observed.provenance==:native)
            cost_estimated|=observed.cost_source==:catalog_estimate
            values=(report.input_tokens,report.output_tokens,report.cache_read_tokens,report.cache_write_tokens)
            partial|=any(isnothing,values)
            if kind==:message && role=="assistant"
                latest_prompt_known=all(!isnothing,(report.input_tokens,report.cache_read_tokens,report.cache_write_tokens))
            end
            cost_unknown|=isnothing(report.cost)
            usage=FooterUsage(;input=something(report.input_tokens,0),output=something(report.output_tokens,0),
                cache_read=something(report.cache_read_tokens,0),cache_write=something(report.cache_write_tokens,0),cost=something(report.cost,0.0))
            push!(events,FooterUsageEvent(;kind,role=isnothing(role) ? nothing : Symbol(role),usage))
        elseif kind==:message && role=="assistant"
            unknown=true
            latest_prompt_known=false
        end
        if kind==:session_info
            value=get(entry,"name",nothing)
            name=value isa AbstractString && !isempty(strip(value)) ? String(strip(value)) : nothing
        end
    end
    total=footer_native_totals(events)
    accounting=FooterAccounting(;usage=total.usage,cache_rate=latest_prompt_known ? total.cache_rate : nothing)
    (;accounting,unknown,partial,cost_unknown,cost_estimated,name)
end

"""Copy an archive only when its immutable entry vector or durable leaf changes; never lock execution."""
function footer_control_archive!(state::FooterHostState,timeline::JuliaForever2.SessionTimeline)
    changed=lock(timeline.lock) do
        key=(timeline.identity.id,objectid(timeline),objectid(timeline.entries),length(timeline.entries),timeline.leaf,timeline.disk_digest)
        key==state.key ? nothing : (;key,entries=deepcopy(timeline.entries),leaf=timeline.leaf)
    end
    if !isnothing(changed)
        total=footer_control_accounting(changed.entries)
        context=footer_control_context(changed.entries,changed.leaf)
        state.key=changed.key
        state.accounting=total.accounting
        state.context_tokens=context.tokens
        state.context_estimated=context.estimated
        state.name=total.name
        state.usage_unknown=total.unknown
        state.usage_partial=total.partial
        state.cost_unknown=total.cost_unknown
        state.cost_estimated=total.cost_estimated
        state.scans+=1
    end
    state
end
function footer_control_archive!(state::FooterHostState,::Nothing)
    state.key=nothing
    state.accounting=FooterAccounting()
    state.context_tokens=nothing
    state.context_estimated=false
    state.name=nothing
    state.usage_unknown=true
    state.usage_partial=false
    state.cost_unknown=false
    state.cost_estimated=false
    state
end

footer_control_selected(provider)=nothing
footer_control_selected(provider::Union{JuliaForever2.ConfiguredModelProvider,JuliaForever2.ModelProvider})=provider.model
footer_control_subscription_unknown(provider)=false
footer_control_subscription_unknown(provider::Union{JuliaForever2.CodexProvider,JuliaForever2.OpenAIProvider})=true
footer_control_subscription_unknown(provider::JuliaForever2.ConfiguredModelProvider)=footer_control_subscription_unknown(provider.backend)
footer_control_model(::Nothing,state::FooterHostState)=(model=nothing,thinking=nothing,subscription=false,auth_unknown=false)
footer_control_model(::JuliaForever2.DemoProvider,state::FooterHostState)=(model=FooterModel(;id="offline · /settings to connect",provider="demo"),thinking=nothing,subscription=false,auth_unknown=false)
function footer_control_model(provider,state::FooterHostState)
    identity=JuliaForever2.provider_model_identity(provider)
    selected=footer_control_selected(provider)
    if isnothing(selected)
        index=findfirst(model->model.provider==identity.provider_id && model.id==identity.model_id,state.models)
        selected=isnothing(index) ? nothing : state.models[index]
    end
    model=isempty(identity.model_id) ? nothing : isnothing(selected) ? FooterModel(;id=identity.model_id,provider=String(identity.provider_id)) :
        FooterModel(;id=selected.id,provider=String(selected.provider),reasoning=JuliaForever2.model_reasoning(selected),context_window=JuliaForever2.model_context_window(selected))
    subscription=get(state.subscriptions,identity.provider_id,false)
    auth_unknown=footer_control_subscription_unknown(provider) && !haskey(state.subscriptions,identity.provider_id)
    (;model,thinking=JuliaForever2.current_thinking_level(provider),subscription,auth_unknown)
end

"""Project factual App state without credential reads, network, execution locks or mutable archive retention."""
function footer_control_snapshot(app::App,state::FooterHostState=footer_control_state!(app))
    footer_control_archive!(state,app.archive.timeline)
    current=with_component(app.session.kernel,:provider;fallback=footer_control_model(nothing,state)) do provider
        footer_control_model(provider,state)
    end
    statuses=copy(state.statuses)
    state.usage_unknown && push!(statuses,"jf2.usage"=>"Usage unreported")
    state.usage_partial && push!(statuses,"jf2.usage.partial"=>"Usage partial")
    state.cost_unknown && push!(statuses,"jf2.cost"=>"Cost unknown")
    state.cost_estimated && push!(statuses,"jf2.cost.estimate"=>"Cost estimate")
    current.auth_unknown && push!(statuses,"jf2.subscription"=>"Subscription status unknown")
    app.status in ("Ready","") || push!(statuses,"jf2.status"=>app.status)
    model=current.model
    window=isnothing(state.routed) ? footer_native_window(model) : footer_native_window(state.routed)
    tokens=state.context_tokens
    context=window>0 ? FooterContext(;percent=isnothing(tokens) ? nothing : tokens/window*100,window) : nothing
    available=state.models
    enabled=app.menus.enabled_models
    if !isnothing(enabled) && !isempty(enabled)
        scoped=filter(model->string(model.provider,"/",model.id) in enabled,available)
        isempty(scoped) || (available=scoped)
    end
    count=length(unique(model.provider for model in available))
    FooterSnapshot(;cwd=app.settings.workspace,home=state.home,branch=state.branch,name=state.name,model,thinking=current.thinking,
        routed=state.routed,routed_thinking=state.routed_thinking,context,accounting=state.accounting,subscription=current.subscription,
        available_providers=count,auto_compact=JuliaForever2.session_compaction_settings(app.session).enabled,experimental=state.experimental,statuses)
end

footer_control_style(app::App,token::Symbol)=isnothing(app.menus.theme_runtime) ? pi_style(token) : theme_style(app.menus.theme_runtime.active,token)
function footer_control_lines(app::App,width::Integer,state::FooterHostState=footer_control_state!(app))
    snapshot=footer_control_snapshot(app,state)
    footer_native_lines(snapshot,width;style=token->footer_control_style(app,token),bold=!isnothing(app.menus.theme_runtime) && app.menus.theme_runtime.catalog.bold)
end
function footer_control_draw!(buffer::Tachikoma.Buffer,x::Int,y::Int,width::Int,app::App,state::FooterHostState=footer_control_state!(app))
    snapshot=footer_control_snapshot(app,state)
    footer_native_draw!(buffer,x,y,width,snapshot;style=token->footer_control_style(app,token),bold=!isnothing(app.menus.theme_runtime) && app.menus.theme_runtime.catalog.bold)
end
