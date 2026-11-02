# Native semantic navigation derived from Pi (MIT), copyright (c) 2025 Mario Zechner.
# Pinned upstream: 2c8d1feb147f6b3d97e855da803bfe7b19f3c403; license: licenses/pi-LICENSE.
"""Keep trusted rendered component boundaries separate from untrusted text and terminal escape programs."""
Base.@kwdef mutable struct TerminalPromptRows
    archived::Vector{Int}=Int[]
    document::Vector{Int}=Int[]
    owner::String=""
end

terminal_prompt_tool(block)=false
function terminal_prompt_tool(block::AbstractDict)
    kind=get(block,"type",nothing)
    kind isa AbstractString && kind=="toolCall"
end
terminal_prompt_tools(content)=false
terminal_prompt_tools(content::AbstractVector)=any(terminal_prompt_tool,content)
terminal_prompt_text(content::AbstractString)::String=String(content)
terminal_prompt_text(content)::String=""
terminal_prompt_block_text(block)::String=""
function terminal_prompt_block_text(block::AbstractDict)::String
    kind=get(block,"type",nothing)
    kind isa AbstractString && kind=="text" ? terminal_prompt_text(get(block,"text",nothing)) : ""
end
terminal_prompt_text(content::AbstractVector)::String=join(terminal_prompt_block_text(block) for block in content)
terminal_prompt_space(char::Char)=Int(char) in (9,10,11,12,13,32,160,0x1680,0x2028,0x2029,0x202f,0x205f,0x3000,0xfeff) || 0x2000<=Int(char)<=0x200a

"""Match component-generated semantic starts, including the source's one-row end-prefix suppression."""
function terminal_prompt_boundary(kind::Symbol,message::AbstractDict,row_count::Integer)
    content=get(message,"content",nothing)
    valid=content isa AbstractString || content isa AbstractVector
    nonempty_user=kind==:user && any(char->!terminal_prompt_space(char),session_display_safe(terminal_prompt_text(content)))
    row_count>1 && valid && (nonempty_user || kind==:assistant && !terminal_prompt_tools(content))
end
terminal_prompt_boundary(kind::Symbol,message,row_count::Integer)=false

"""Record only a boundary reported after actual native component layout, never raw OSC in model output."""
function terminal_prompt_record!(rows::Vector{Int},kind::Symbol,message,start::Integer,row_count::Integer)
    if start>=0 && terminal_prompt_boundary(kind,message,row_count)
        push!(rows,Int(start))
    end
    nothing
end

"""Offset actual archive boundaries and a real answer preview into the current composed document."""
function terminal_prompt_publish!(state::TerminalPromptRows,owner::AbstractString,prefix_rows::Integer,
        archive_rows::Integer,preview_rows::Integer;preview_kind::Union{Nothing,Symbol}=nothing)
    state.owner=String(owner)
    state.document=Int[Int(prefix_rows)+row for row in state.archived if 0<=row<archive_rows]
    if preview_kind==:answer && preview_rows>1
        push!(state.document,Int(prefix_rows+archive_rows))
    end
    state.document
end

"""Find the next strict semantic boundary from the viewport top, not the caret or selection."""
function terminal_prompt_target(rows::AbstractVector{<:Integer},top::Integer,total::Integer,direction::Integer)
    target=nothing
    for row in rows
        eligible=0<=row<total && (direction==-1 && row<top || direction==1 && row>top)
        if eligible && (isnothing(target) || direction==-1 && row>target || direction==1 && row<target)
            target=Int(row)
        end
    end
    target
end

"""Normalize the original default semantic-navigation packets without inventing custom bindings."""
function terminal_prompt_packet(packet::AbstractString)
    text=String(packet)::String
    direction=0;released=false
    if text in ("\eOa","\eOb")
        direction=text=="\eOa" ? -1 : 1
    else
        matched=match(r"^\e\[1;(\d+)(?::(\d+))?([AB])$",text)
        if !isnothing(matched)
            modifier=something(tryparse(Int,something(matched.captures[1],"")),0)-1
            if (modifier & ~192) in (4,5)
                direction=matched.captures[3]=="A" ? -1 : 1
                released=matched.captures[2]=="3"
            end
        else
            keypad=match(r"^\e\[(57419|57420)(?::(\d*))?(?::(\d+))?(?:;(\d+))?(?::(\d+))?u$",text)
            if !isnothing(keypad)
                modifier=something(tryparse(Int,something(keypad.captures[4],"1")),0)-1
                if (modifier & ~192) in (4,5)
                    direction=keypad.captures[1]=="57419" ? -1 : 1
                    released=keypad.captures[5]=="3"
                end
            end
        end
    end
    (;direction,released)
end

"""Move the real scroll owner only for an uncaptured matching press; releases remain consumed."""
function terminal_prompt_input!(control::TerminalScrollControl,rows::AbstractVector{<:Integer},packet::AbstractString;
        capture::Bool=false,now::Real=time_ns()/1e9)
    command=terminal_prompt_packet(packet)
    handled=!control.closed && control.snapshot.fullscreen && !capture && command.direction!=0
    target=nothing
    if handled && !command.released
        snapshot=control.snapshot
        target=terminal_prompt_target(rows,snapshot.top,snapshot.content_height,command.direction)
        isnothing(target) || terminal_scroll_control_to!(control,target;now)
    end
    (;handled,target,released=command.released)
end
