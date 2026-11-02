# A single IO adapter for the existing Tachikoma input owner, never a competing stdin reader.
public ThemeTerminalInput, theme_input_attach!, theme_input_detach!, theme_input_poll!, theme_input_feed!
public theme_input_reserve_device_reply!

const THEME_INPUT_PASTE_START = UInt8[0x1b,0x5b,0x32,0x30,0x30,0x7e]
const THEME_INPUT_PASTE_END = UInt8[0x1b,0x5b,0x32,0x30,0x31,0x7e]

Base.@kwdef mutable struct ThemeTerminalInput{I,L,C} <: IO
    source::I
    lifecycle::L
    clock::C = time
    lock::ReentrantLock = ReentrantLock()
    ready::IOBuffer = PipeBuffer()
    pending::Vector{UInt8} = UInt8[]
    reports::Vector{String} = String[]
    last_input::Float64 = 0.0
    paste::Bool = false
    paste_buffer::Vector{UInt8} = UInt8[]
    closed::Bool = false
    reserved_da1::Int = 0
    installed::Bool = false
    previous_input::Union{Nothing,IO} = nothing
end

"""Detect only terminal reports this lifecycle owns; unrelated negotiation replies remain ordinary bytes."""
function theme_input_owned(input::ThemeTerminalInput,sequence::String)
    owned = false
    if isvalid(sequence)
        lifecycle = input.lifecycle
        active = lifecycle.started && !lifecycle.closed
        scheme = terminal_color_scheme(sequence)
        device = occursin(r"^\e\[\?[\d;]*c$",sequence)
        reserved = device && input.reserved_da1>0
        if reserved
            input.reserved_da1 -= 1
        end
        queries = lifecycle.queries
        owned = active && !reserved && (!isnothing(scheme) || !isnothing(queries) && !isempty(queries.queue) &&
            (device || !isnothing(terminal_color_response(sequence))))
    end
    owned
end

"""Reserve a known earlier non-color DA1 request before issuing it, rather than guessing reply ownership."""
function theme_input_reserve_device_reply!(input::ThemeTerminalInput,count::Int=1)
    lock(input.lock) do
        input.reserved_da1 += max(0,count)
    end
    nothing
end

"""Recognize an established OSC color-reply header so late bodies never become typed keys."""
function theme_input_color_header(bytes::Vector{UInt8})
    found = false
    if length(bytes)>=5 && bytes[1]==0x1b && bytes[2]==0x5d
        if bytes[3]==0x31 && bytes[4] in (0x30,0x31) && bytes[5]==0x3b
            found = true
        elseif bytes[3]==0x34 && bytes[4]==0x3b
            index = 5
            while index<=min(7,length(bytes)) && 0x30<=bytes[index]<=0x39
                index += 1
            end
            found = 6<=index<=8 && index<=length(bytes) && bytes[index]==0x3b
        end
    end
    found
end

"""Find one complete escape frame, including legacy mouse bytes and cancelled terminal strings."""
function theme_input_frame(bytes::Vector{UInt8})
    count = length(bytes)
    size = 0
    discard = false
    if count>=2
        second = bytes[2]
        if second==0x5b
            if count>=3 && bytes[3]==0x4d
                size = count>=6 ? 6 : 0
            else
                final = findfirst(index -> 0x40<=bytes[index]<=0x7e,3:count)
                size = isnothing(final) ? 0 : final+2
            end
        elseif second in (0x5d,0x50,0x5f,0x5e,0x58)
            recognized = theme_input_color_header(bytes)
            index = 3
            while index<=count && size==0
                value = bytes[index]
                if value==0x07 || value==0x1b && index<count && bytes[index+1]==0x5c
                    size = value==0x07 ? index : index+1
                elseif recognized && value in (0x18,0x1a)
                    size = index
                    discard = true
                elseif recognized && value==0x1b && index<count && bytes[index+1]!=0x5c
                    size = index-1
                    discard = true
                end
                index += 1
            end
        elseif second==0x4f
            size = count>=3 ? 3 : 0
        elseif second==0x1b
            size = 1
        else
            size = 2
        end
    end
    (size=size,discard=discard)
end

"""Match a byte subsequence without decoding, preserving split UTF-8 and bracketed paste contents."""
function theme_input_find(bytes::Vector{UInt8},needle::Vector{UInt8})
    found = nothing
    index = 1
    while isnothing(found) && index<=length(bytes)-length(needle)+1
        if theme_input_matches(bytes,needle,index)
            found = index
        end
        index += 1
    end
    found
end

function theme_input_matches(bytes::Vector{UInt8},needle::Vector{UInt8},index::Int)
    matching = true
    offset = 1
    while matching && offset<=length(needle)
        matching = bytes[index+offset-1]==needle[offset]
        offset += 1
    end
    matching
end

"""Forward paste bytes verbatim, retaining only a possible fragmented end marker."""
function theme_input_paste!(input::ThemeTerminalInput)
    bytes = input.pending
    ending = theme_input_find(bytes,THEME_INPUT_PASTE_END)
    count = 0
    if !isnothing(ending)
        count = ending+length(THEME_INPUT_PASTE_END)-1
        input.paste = false
    else
        retained = 0
        for size in 1:min(length(bytes),length(THEME_INPUT_PASTE_END)-1)
            if bytes[end-size+1:end]==THEME_INPUT_PASTE_END[1:size]
                retained = size
            end
        end
        count = length(bytes)-retained
    end
    if count>0
        append!(input.paste_buffer,bytes[1:count])
        deleteat!(bytes,1:count)
        if !input.paste
            write(input.ready,input.paste_buffer)
            empty!(input.paste_buffer)
        end
    end
    count>0
end

"""Frame only complete reports; stop at a control barrier so following keys cannot overtake it."""
function theme_input_extract!(input::ThemeTerminalInput)
    progressing = true
    while progressing && !isempty(input.pending) && isempty(input.reports)
        if input.paste
            progressing = theme_input_paste!(input)
        elseif first(input.pending)!=0x1b
            next_escape = findfirst(==(0x1b),input.pending)
            count = isnothing(next_escape) ? length(input.pending) : next_escape-1
            write(input.ready,input.pending[1:count])
            deleteat!(input.pending,1:count)
        else
            frame = theme_input_frame(input.pending)
            if frame.size==0
                progressing = false
            else
                bytes = input.pending[1:frame.size]
                deleteat!(input.pending,1:frame.size)
                if !frame.discard
                    sequence = String(copy(bytes))
                    if theme_input_owned(input,sequence)
                        push!(input.reports,sequence)
                    elseif bytes==THEME_INPUT_PASTE_START
                        input.paste = true
                        append!(input.paste_buffer,bytes)
                    else
                        write(input.ready,bytes)
                    end
                end
            end
        end
    end
    nothing
end

"""Bound ambiguous Escape/prefix recovery while retaining recognized color reports across slow links."""
function theme_input_expire!(input::ThemeTerminalInput)
    bytes = input.pending
    if !isempty(bytes) && first(bytes)==0x1b && !input.paste && isempty(input.reports) &&
        theme_input_frame(bytes).size==0 && !theme_input_color_header(bytes)
        timeout = bytes==UInt8[0x1b] ? 0.01 : 0.05
        if input.clock()-input.last_input>=timeout-1e-9
            write(input.ready,bytes)
            empty!(bytes)
        end
    end
    nothing
end

"""Feed bytes from the one existing reader or a deterministic test, preserving non-report bytes exactly."""
function theme_input_feed!(input::ThemeTerminalInput,bytes::AbstractVector{UInt8})
    lock(input.lock) do
        if !input.closed
            theme_input_expire!(input)
            append!(input.pending,bytes)
            isempty(bytes) || (input.last_input=input.clock())
            theme_input_extract!(input)
        end
    end
    nothing
end

"""Pump only already-buffered bytes under one lock; no task reads the upstream stream independently."""
function theme_input_pump!(input::ThemeTerminalInput)
    lock(input.lock) do
        if !input.closed
            theme_input_expire!(input)
            count = min(bytesavailable(input.source),65536)
            if count>0
                append!(input.pending,read(input.source,count))
                input.last_input = input.clock()
            end
            theme_input_extract!(input)
        end
    end
    nothing
end

function Base.bytesavailable(input::ThemeTerminalInput)
    theme_input_pump!(input)
    lock(() -> bytesavailable(input.ready),input.lock)
end
function Base.read(input::ThemeTerminalInput,::Type{UInt8})
    theme_input_pump!(input)
    lock(() -> read(input.ready,UInt8),input.lock)
end
function Base.readavailable(input::ThemeTerminalInput)
    theme_input_pump!(input)
    lock(() -> readavailable(input.ready),input.lock)
end
Base.isopen(input::ThemeTerminalInput) = !input.closed && isopen(input.source)
Base.eof(input::ThemeTerminalInput) = bytesavailable(input)==0 && (input.closed || eof(input.source))

"""Use the same source's wakeup, with bounded polling only while an ambiguous escape prefix is buffered."""
function Base.wait(input::ThemeTerminalInput)
    state = lock(input.lock) do
        (ready=bytesavailable(input.ready)>0 || !isempty(input.reports),
            ambiguous=!isempty(input.pending) && !input.paste && !theme_input_color_header(input.pending))
    end
    if !input.closed && !state.ready
        if state.ambiguous
            sleep(0.001)
        else
            theme_input_wait_source(input.source)
        end
    else
        yield()
    end
    nothing
end
theme_input_wait_source(source::Base.LibuvStream) = Base.wait_readnb(source, 1)
theme_input_wait_source(source::IO) = sleep(0.001)

"""Apply queued reports on the UI owner before releasing later key/mouse bytes."""
function theme_input_poll!(input::ThemeTerminalInput)
    changed = theme_lifecycle_poll!(input.lifecycle)
    theme_input_pump!(input)
    progressing = true
    while progressing && !input.closed
        sequence = lock(input.lock) do
            bytesavailable(input.ready)==0 && !isempty(input.reports) ? popfirst!(input.reports) : nothing
        end
        if isnothing(sequence)
            progressing = false
        else
            consumed = theme_lifecycle_input!(input.lifecycle,sequence)
            if !consumed
                lock(input.lock) do
                    write(input.ready,sequence)
                end
            end
            changed = theme_lifecycle_poll!(input.lifecycle) || changed
            theme_input_pump!(input)
        end
    end
    changed
end

"""Close only the adapter; the existing terminal owner retains its source and lifecycle."""
function Base.close(input::ThemeTerminalInput)
    lock(input.lock) do
        input.closed = true
        empty!(input.pending)
        empty!(input.paste_buffer)
        empty!(input.reports)
    end
    nothing
end

"""Install after Tachikoma enter_tui!/probes, using the exact input source the current terminal already owns."""
function theme_input_attach!(lifecycle::ThemeLifecycle)
    result = (ok=false,input=nothing,reason="Theme input must attach after the current Tachikoma terminal starts")
    if Tachikoma.INPUT_ACTIVE[] && !Sys.iswindows() && !lifecycle.closed
        previous = Tachikoma.INPUT_IO[]
        source = something(previous,stdin)
        if source isa ThemeTerminalInput
            result = (ok=false,input=nothing,reason="A theme input adapter already owns this terminal")
        else
            input = ThemeTerminalInput(;source,lifecycle,installed=true,previous_input=previous)
            Tachikoma.INPUT_IO[] = input
            result = (ok=true,input=input,reason="")
        end
    end
    result
end

"""Restore only our own input binding; never close the caller-owned stream or overwrite a newer owner."""
function theme_input_detach!(input::ThemeTerminalInput)
    restored = false
    if input.installed && Tachikoma.INPUT_IO[]===input
        Tachikoma.INPUT_IO[] = input.previous_input
        restored = true
    end
    input.installed = false
    close(input)
    stopped = (ok=true,value=nothing,reason="")
    if restored && !Tachikoma.INPUT_ACTIVE[] && input.source isa Base.LibuvStream
        stopped = theme_lifecycle_attempt() do
            Base.stop_reading(input.source)
            while bytesavailable(input.source)>0
                read(input.source,UInt8)
            end
            nothing
        end
    end
    (restored=restored,ok=stopped.ok,reason=stopped.reason)
end
