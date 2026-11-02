function command_document_state!(state::CommandDocumentState,id::String)
    if state.owner != id
        state.owner=id
        empty!(state.documents)
        state.revision+=UInt(1)
    end
    state
end

function append_command_document!(app::App,title::AbstractString,content::Union{String,JuliaForever2.SessionStatistics,CommandSessionInfo,CommandHotkeyTable})
    timeline=app.archive.timeline
    if isnothing(timeline)
        app.status="No active session archive"
    else
        snapshot=lock(timeline.lock) do
            projection=JuliaForever2.timeline_display_projection(timeline)
            anchor=isempty(projection.items) ? nothing : last(projection.items).source_entry_id
            (;id=timeline.identity.id,anchor)
        end
        state=command_document_state!(app.transcript.documents,snapshot.id)
        push!(state.documents,InlineCommandDocument(String(title),content,snapshot.anchor))
        state.revision+=UInt(1)
        app.transcript.display_key=nothing
        app.scroll=0
        app.page=:chat
        app.menu=false
        app.status=""
    end
    nothing
end

command_number(value::Int)=replace(string(value),r"(?<=\d)(?=(\d{3})+(?!\d))"=>",")
function command_total_label(total::JuliaForever2.ReportedSessionTotal{Int})
    if JuliaForever2.session_total_complete(total)
        command_number(total.value)
    elseif total.reported==0
        "Unknown (not reported)"
    else
        command_number(total.value)*"+ (partial; "*string(total.reported)*"/"*string(total.expected)*" counters reported)"
    end
end
function command_total_label(total::JuliaForever2.ReportedSessionTotal{Float64})
    if JuliaForever2.session_total_complete(total)
        @sprintf("\$%.3f",total.value)
    elseif total.reported==0
        "Unknown (not reported)"
    else
        @sprintf("\$%.3f+ (partial)",total.value)
    end
end
command_cost_source(sources::Set{Symbol}) = isempty(sources) ? "Unknown" :
    sources==Set([:catalog_estimate]) ? "Catalog estimate; not a subscription bill" :
    sources==Set([:legacy_declared]) ? "Declared in archive; not verified billing" : "Mixed estimates/declarations; not verified billing"

function command_stats_rows(stats::JuliaForever2.SessionStatistics,width::Int;cache_mode::AbstractString="off",selected_model::Union{Nothing,AbstractString}=nothing)
    rows=SessionDisplayRows()
    plain=Tachikoma.Style()
    line=(label,value)->session_display_wrap([Tachikoma.Span(repeat(" ",length(label)-length(lstrip(label))),plain),Tachikoma.Span(String(strip(label)),session_display_style(:dim)),Tachikoma.Span(" "*session_display_safe(value),plain)],width,1)
    heading=text->session_display_wrap([Tachikoma.Span(text,session_display_style(:default;bold=true))],width,1)
    blank=()->push!(rows,session_display_blank(width))
    blank();append!(rows,heading("Session Info"));blank()
    !isnothing(stats.name) && append!(rows,line("Name: ",stats.name))
    append!(rows,line("File: ",something(stats.path,"In-memory")))
    append!(rows,line("ID: ",stats.id));blank()
    append!(rows,heading("Messages"))
    for (label,value) in (("Total: ",stats.messages.total),("User: ",stats.messages.user),("Assistant: ",stats.messages.assistant))
        append!(rows,line(label,string(value)))
    end
    append!(rows,line("Tools: ",string(stats.messages.tool_calls)*" calls, "*string(stats.messages.tool_results)*" results"));blank()
    append!(rows,heading("Tokens"))
    input=JuliaForever2.session_combined_total(stats.tokens.input,stats.tokens.cache_read,stats.tokens.cache_write)
    append!(rows,line("Input: ",command_total_label(input)))
    if JuliaForever2.session_total_complete(input) && input.value>0 && stats.tokens.cache_read.value+stats.tokens.cache_write.value>0
        cached=stats.tokens.cache_read.value
        spans=[Tachikoma.Span("  ",plain),Tachikoma.Span("Cached:",session_display_style(:dim)),Tachikoma.Span(" ",plain),Tachikoma.Span(command_number(cached)*" ",plain),Tachikoma.Span(@sprintf("(%.1f%%)",100cached/input.value),session_display_style(:dim))]
        append!(rows,session_display_wrap(spans,width,1))
        uncached=stats.tokens.input.value+stats.tokens.cache_write.value
        spans=[Tachikoma.Span("  ",plain),Tachikoma.Span("Uncached:",session_display_style(:dim)),Tachikoma.Span(" ",plain),Tachikoma.Span(command_number(uncached),plain)]
        stats.tokens.cache_write.value>0 && push!(spans,Tachikoma.Span(" ("*command_number(stats.tokens.cache_write.value)*" written to cache)",session_display_style(:dim)))
        append!(rows,session_display_wrap(spans,width,1))
    end
    append!(rows,line("Output: ",command_total_label(stats.tokens.output)))
    append!(rows,line("Total: ",command_total_label(JuliaForever2.session_combined_total(values(stats.tokens)...))));blank()
    append!(rows,heading("Cache Warming"))
    append!(rows,line("Mode: ",String(cache_mode)))
    append!(rows,line("Status: ","Inactive (cache warming unavailable)"))
    if stats.cost.value>0 || !JuliaForever2.session_total_complete(stats.cost)
        blank();append!(rows,heading("Cost"))
        append!(rows,line("Total: ",command_total_label(stats.cost)))
        if length(stats.breakdown)>1 || isempty(stats.breakdown) || first(stats.breakdown).key!=selected_model
            for item in stats.breakdown
                tokens=JuliaForever2.session_combined_total(values(item.tokens)...)
                spans=[Tachikoma.Span("  ",plain),Tachikoma.Span(session_display_safe(item.key)*":",session_display_style(:dim)),
                    Tachikoma.Span(" "*command_total_label(item.cost)*" ",plain),Tachikoma.Span("("*command_compact_tokens(tokens)*" tokens)",session_display_style(:dim))]
                append!(rows,session_display_wrap(spans,width,1))
            end
        end
        append!(rows,line("Source: ",command_cost_source(stats.cost_sources)))
    end
    blank()
    rows
end

function command_document_rows(document::InlineCommandDocument,width::Int)
    if document.content isa CommandSessionInfo
        command_stats_rows(document.content.statistics,width;cache_mode=document.content.cache_mode,selected_model=document.content.selected_model)
    elseif document.content isa JuliaForever2.SessionStatistics
        command_stats_rows(document.content,width)
    else
        rows=SessionDisplayRows([session_display_blank(width)])
        border=[Tachikoma.Span(repeat("─",width),session_display_style(:border))]
        push!(rows,border)
        append!(rows,session_display_text_rows(document.title,width,1;style=session_display_style(:accent;bold=true)))
        push!(rows,session_display_blank(width))
        push!(rows,session_display_blank(width))
        append!(rows,document.content isa CommandHotkeyTable ? command_hotkeys_rows(document.content.markdown,width) : session_display_markdown(document.content,width,1))
        push!(rows,session_display_blank(width))
        push!(rows,border)
        rows
    end
end

function command_document_rows(state::CommandDocumentState,id::String,anchor,width::Int)
    rows=SessionDisplayRows()
    if state.owner==id
        for document in state.documents
            if isequal(document.anchor,anchor)
                append!(rows,command_document_rows(document,width))
            end
        end
    end
    rows
end

function session_info_command!(app::App)
    timeline=app.archive.timeline
    if isnothing(timeline)
        app.status="No active session archive"
    else
        stats=lock(timeline.lock) do
            entries=JuliaForever2.timeline_entries(timeline)
            names=[get(entry,"name",nothing) for entry in entries if get(entry,"type",nothing)=="session_info"]
            name=isempty(names) ? nothing : last(names)
            JuliaForever2.session_statistics(entries;id=timeline.identity.id,path=timeline.path,name)
        end
        append_command_document!(app,"Session Info",CommandSessionInfo(stats,menu_preference(app,"cache-warming-mode","streaming"),current_menu_model(app)))
    end
    nothing
end

function command_compact_tokens(total::JuliaForever2.ReportedSessionTotal{Int})
    value=total.value
    if !JuliaForever2.session_total_complete(total)
        command_total_label(total)
    elseif value<1000
        string(value)
    elseif value<10000
        @sprintf("%.1fk",value/1000)
    elseif value<1000000
        string(floor(Int,value/1000+0.5))*"k"
    elseif value<10000000
        @sprintf("%.1fM",value/1000000)
    else
        string(floor(Int,value/1000000+0.5))*"M"
    end
end

"""Discard transient command output only when the host deliberately rebuilds or clears the chat."""
function clear_command_documents!(app::App)
    clear_frontend_notices!(app)
    empty!(app.transcript.documents.documents)
    app.transcript.documents.revision+=UInt(1)
    app.transcript.display_key=nothing
    nothing
end
