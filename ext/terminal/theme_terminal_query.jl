# Native terminal report parsing and FIFO color queries; no terminal or theme singleton is assumed.
public TerminalColors, TerminalColorQueries, terminal_color_response, terminal_color_scheme
public terminal_color_query!, terminal_color_input!, terminal_color_poll!, terminal_color_close!, terminal_color_settled

Base.@kwdef struct TerminalColors
    foreground::Union{Nothing,NTuple{3,Int}} = nothing
    background::Union{Nothing,NTuple{3,Int}} = nothing
    palette::Vector{NTuple{3,Int}} = NTuple{3,Int}[]
end
Base.:(==)(a::TerminalColors,b::TerminalColors) = a.foreground==b.foreground && a.background==b.background && a.palette==b.palette

const TERMINAL_COLOR_QUERY_BYTES = "\e]10;?\a\e]11;?\a"*join("\e]4;$index;?\a" for index in 0:15)*"\e[c"
const TERMINAL_QUERY_SECONDS = 0.1

"""Normalize the terminal's variable-width hexadecimal RGB channels to eight-bit color."""
function terminal_hex_channel(channel::AbstractString)
    value = nothing
    if occursin(r"^[0-9a-f]+$"i,channel)
        maximum_value = big(16)^length(channel)-1
        scaled = Float64(parse(BigInt,channel;base=16))/Float64(maximum_value)*255
        if isfinite(scaled)
            value = floor(Int,scaled+0.5)
        end
    end
    value
end

"""Parse supported OSC color forms without treating a malformed color as an absent reply."""
function terminal_color_value(raw::AbstractString)
    value = strip(raw)
    channels = SubString{String}[]
    if startswith(value,'#')
        hex = value[2:end]
        if occursin(r"^[0-9a-f]{6}$"i,hex)
            channels = [SubString(hex,start,start+1) for start in (1,3,5)]
        elseif occursin(r"^[0-9a-f]{12}$"i,hex)
            channels = [SubString(hex,start,start+3) for start in (1,5,9)]
        end
    else
        parts = split(replace(value,r"^rgba?:"i=>""),'/')
        if length(parts)>=3
            channels = parts[1:3]
        end
    end
    parsed = terminal_hex_channel.(channels)
    length(parsed)==3 ? terminal_rgb(parsed[1],parsed[2],parsed[3]) : nothing
end

terminal_rgb(red,green,blue) = nothing
terminal_rgb(red::Int,green::Int,blue::Int) = (red,green,blue)

"""Recognize OSC 10, 11 and 4 replies terminated by BEL or ST, including invalid RGB payloads."""
function terminal_color_response(data::AbstractString)
    matched = match(r"^\e\](?:(1[01])|4;(\d{1,3}));([^\a\e]*)(?:\a|\e\\)$"i,data)
    if isnothing(matched)
        nothing
    else
        target = matched[1]=="10" ? "foreground" : matched[1]=="11" ? "background" : string(parse(Int,something(matched[2],"0")))
        (target=target,rgb=terminal_color_value(something(matched[3],"")))
    end
end

"""Accept the terminal's complete light/dark notification, using the last coalesced report."""
function terminal_color_scheme(data::AbstractString)
    matched = match(r"^(?:\e\[\?997;(1|2)n)+$",data)
    isnothing(matched) ? nothing : matched[1]=="2" ? :light : :dark
end

Base.@kwdef mutable struct TerminalColorQuery
    id::UInt64
    foreground::Union{Nothing,NTuple{3,Int}} = nothing
    background::Union{Nothing,NTuple{3,Int}} = nothing
    palette::Vector{Union{Nothing,NTuple{3,Int}}} = Union{Nothing,NTuple{3,Int}}[nothing for _ in 1:16]
    replied::Set{String} = Set{String}()
    phase::Symbol = :waiting
    timer::Any = nothing
end

native_theme_timer(seconds,callback) = Timer(_ -> callback(),seconds)
native_theme_cancel(::Nothing) = nothing
native_theme_cancel(timer) = close(timer)

Base.@kwdef mutable struct TerminalColorQueries{W,D,S,C}
    write::W
    deliver::D
    schedule::S = native_theme_timer
    cancel::C = native_theme_cancel
    queue::Vector{TerminalColorQuery} = TerminalColorQuery[]
    lock::ReentrantLock = ReentrantLock()
    expired::Vector{UInt64} = UInt64[]
    next_id::UInt64 = UInt64(0)
    settled::Set{UInt64} = Set{UInt64}()
    closed::Bool = false
    last_error::String = ""
end

"""Contain recoverable device/file failures in an owned task without hiding the outcome."""
function theme_lifecycle_attempt(operation)
    worker = @async operation()
    wait(worker;throw=false)
    istaskfailed(worker) ? (ok=false,value=nothing,reason=sprint(showerror,TaskFailedException(worker))) :
        (ok=true,value=fetch(worker),reason="")
end

"""Start one real color query; its native timer only queues work for the UI owner."""
function terminal_color_query!(queries::TerminalColorQueries)
    id = UInt64(0)
    if !queries.closed
        queries.next_id += 1
        id = queries.next_id
        query = TerminalColorQuery(;id)
        push!(queries.queue,query)
        query.timer = queries.schedule(TERMINAL_QUERY_SECONDS,() -> lock(queries.lock) do
            if !queries.closed
                push!(queries.expired,id)
            end
        end)
        sent = theme_lifecycle_attempt(() -> queries.write(TERMINAL_COLOR_QUERY_BYTES))
        if !sent.ok
            queries.last_error = sent.reason
            queries.cancel(query.timer)
            query.phase = :complete
            pop!(queries.queue)
            push!(queries.settled,id)
            queries.deliver(id,:initial,TerminalColors())
        end
    end
    id
end

"""Only publish a palette after every ANSI slot supplied a valid RGB value."""
function terminal_color_result(query::TerminalColorQuery)
    valid = NTuple{3,Int}[value for value in query.palette if value isa NTuple{3,Int}]
    palette = length(valid)==16 ? valid : NTuple{3,Int}[]
    TerminalColors(;query.foreground,query.background,palette)
end

"""Settle initial delivery once, retaining late replies until all targets or DA1 complete."""
function terminal_color_complete!(queries::TerminalColorQueries,query::TerminalColorQuery)
    if query.phase in (:waiting,:late)
        phase = query.phase==:waiting ? :initial : :late
        query.phase = :complete
        queries.cancel(query.timer)
        push!(queries.settled,query.id)
        queries.deliver(query.id,phase,terminal_color_result(query))
    end
    nothing
end

"""Consume only reports owned by the first outstanding query, preserving the trailing DA1 boundary."""
function terminal_color_input!(queries::TerminalColorQueries,data::AbstractString)
    consumed = false
    if !queries.closed && !isempty(queries.queue)
        query = first(queries.queue)
        if occursin(r"^\e\[\?[\d;]*c$",data)
            popfirst!(queries.queue)
            terminal_color_complete!(queries,query)
            consumed = true
        else
            response = terminal_color_response(data)
            if !isnothing(response)
                consumed = true
                target,rgb = response.target,response.rgb
                if query.phase in (:waiting,:late) && !(target in query.replied)
                    push!(query.replied,target)
                    if target=="foreground"
                        query.foreground = rgb
                    elseif target=="background"
                        query.background = rgb
                    else
                        index = parse(Int,target)
                        if index<16
                            query.palette[index+1] = rgb
                        end
                    end
                    if length(query.replied)==18
                        terminal_color_complete!(queries,query)
                    end
                end
            end
        end
    end
    consumed
end

"""Apply expired query timers on the caller's thread, not the terminal reader or timer task."""
function terminal_color_poll!(queries::TerminalColorQueries)
    expired = lock(queries.lock) do
        values = copy(queries.expired)
        empty!(queries.expired)
        values
    end
    for id in expired
        index = findfirst(query -> query.id==id,queries.queue)
        if !queries.closed && !isnothing(index)
            query = queries.queue[index]
            if query.phase==:waiting
                query.phase = :late
                push!(queries.settled,id)
                queries.deliver(id,:initial,terminal_color_result(query))
            end
        end
    end
    nothing
end
terminal_color_settled(queries::TerminalColorQueries,id::Integer) = queries.closed || id==0 || id in queries.settled

"""Cancel every owned timer and suppress all initial/late callbacks after teardown."""
function terminal_color_close!(queries::TerminalColorQueries)
    lock(queries.lock) do
        queries.closed = true
        empty!(queries.expired)
    end
    for query in queries.queue
        queries.cancel(query.timer)
        query.phase = :cancelled
    end
    empty!(queries.queue)
    nothing
end
