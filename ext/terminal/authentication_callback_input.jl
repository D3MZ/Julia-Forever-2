# Private callback intake is deliberately not a chat editor, transcript entry or URL preview.
public AuthCallbackInput, auth_callback_input!, auth_callback_clear!, auth_callback_dispose!
public auth_callback_lines, auth_callback_cursor, auth_callback_submit!

"""Bounded ASCII URI storage with redacted inspection and no string retained by the UI."""
Base.@kwdef mutable struct AuthCallbackInput
    bytes::Vector{UInt8} = zeros(UInt8,8192)
    used::Int = 0
    cursor::Int = 0
    pasting::Bool = false
    paste_marker::Int = 0
    discard_paste::Bool = false
    warning::Symbol = :none
    received::Bool = false
    disposed::Bool = false
    width::Int = 0
end
Base.show(io::IO,input::AuthCallbackInput)=print(io,"AuthCallbackInput(<redacted>, received=",input.received,", disposed=",input.disposed,")")
Base.show(io::IO,::MIME"text/plain",input::AuthCallbackInput)=show(io,input)

"""Wipe the entire reserved buffer, including unused capacity and incomplete paste state."""
function auth_callback_clear!(input::AuthCallbackInput)
    fill!(input.bytes,0)
    input.used=0
    input.cursor=0
    input.pasting=false
    input.paste_marker=0
    input.discard_paste=false
    nothing
end
function auth_callback_dispose!(input::AuthCallbackInput)
    auth_callback_clear!(input)
    input.disposed=true
    nothing
end

"""Remove a byte interval; valid callback URIs are ASCII with percent-encoded non-ASCII values."""
function auth_callback_delete!(input::AuthCallbackInput,start::Int,stop::Int)
    count=stop-start
    if count>0
        for index in stop+1:input.used
            input.bytes[index-count]=input.bytes[index]
        end
        fill!(Base.view(input.bytes,input.used-count+1:input.used),0)
        input.used-=count
        input.cursor=start
    end
    nothing
end

"""Insert one printable URI byte without retaining another secret-containing string."""
function auth_callback_byte!(input::AuthCallbackInput,byte::UInt8)
    if input.used<length(input.bytes)
        for index in input.used:-1:input.cursor+1
            input.bytes[index+1]=input.bytes[index]
        end
        input.cursor+=1
        input.used+=1
        input.bytes[input.cursor]=byte
    else
        fill!(input.bytes,0)
        input.used=0
        input.cursor=0
        input.warning=:too_long
        input.discard_paste=true
    end
    nothing
end

const AUTH_CALLBACK_PASTE_END=codeunits("\e[201~")
"""Consume pasted bytes without interpreting embedded control keys as commands or submission."""
function auth_callback_paste!(input::AuthCallbackInput,data::AbstractString)
    ended=false
    for byte in codeunits(data)
        if !ended
            if input.paste_marker>0
                if byte==AUTH_CALLBACK_PASTE_END[input.paste_marker+1]
                    input.paste_marker+=1
                    if input.paste_marker==length(AUTH_CALLBACK_PASTE_END)
                        input.pasting=false
                        input.paste_marker=0
                        input.discard_paste=false
                        ended=true
                    end
                else
                    fill!(input.bytes,0)
                    input.used=0
                    input.cursor=0
                    input.discard_paste=true
                    input.warning=:unsafe_input
                    input.paste_marker=byte==0x1b ? 1 : 0
                end
            elseif byte==0x1b
                input.paste_marker=1
            elseif !(0x20<=byte<=0x7e)
                fill!(input.bytes,0)
                input.used=0
                input.cursor=0
                input.discard_paste=true
                input.warning=:unsafe_input
            elseif !input.discard_paste
                auth_callback_byte!(input,byte)
            end
        end
    end
    nothing
end

"""Edit only private storage; submission and cancellation are returned to the native owner."""
function auth_callback_input!(input::AuthCallbackInput,packet::AbstractString)
    action=:handled
    if !input.disposed
        if packet in ("\e","\x03") && !input.pasting
            auth_callback_clear!(input)
            action=:cancel
        elseif input.received
            nothing
        elseif input.pasting
            auth_callback_paste!(input,packet)
        elseif startswith(packet,"\e[200~")
            input.pasting=true
            input.warning=:none
            auth_callback_paste!(input,SubString(packet,7))
        elseif packet in ("\e","\x03")
            auth_callback_clear!(input)
            action=:cancel
        elseif packet in ("\r","\n")
            action=input.used>0 ? :submit : :handled
        elseif packet in ("\e[D","\x02")
            input.cursor=max(0,input.cursor-1)
        elseif packet in ("\e[C","\x06")
            input.cursor=min(input.used,input.cursor+1)
        elseif packet in ("\e[H","\eOH","\e[1~","\x01")
            input.cursor=0
        elseif packet in ("\e[F","\eOF","\e[4~","\x05")
            input.cursor=input.used
        elseif packet in ("\x7f","\x08")
            auth_callback_delete!(input,max(0,input.cursor-1),input.cursor)
        elseif packet in ("\e[3~","\x04")
            auth_callback_delete!(input,input.cursor,min(input.used,input.cursor+1))
        elseif packet=="\x15"
            auth_callback_delete!(input,0,input.cursor)
        elseif packet=="\x0b"
            auth_callback_delete!(input,input.cursor,input.used)
        elseif all(byte->0x20<=byte<=0x7e,codeunits(packet)) && ncodeunits(packet)+input.used<=length(input.bytes)
            input.warning=:none
            for byte in codeunits(packet)
                auth_callback_byte!(input,byte)
            end
        elseif !isempty(packet)
            oversized=ncodeunits(packet)+input.used>length(input.bytes)
            auth_callback_clear!(input)
            input.warning=oversized ? :too_long : :unsafe_input
        end
    end
    action
end

"""Deliver a transient private copy exactly once; only the service may report login success."""
function auth_callback_submit!(input::AuthCallbackInput,submit)
    if input.disposed || input.received || input.pasting || input.used==0
        (ok=false,reason=:not_ready)
    else
        bytes=copy(Base.view(input.bytes,1:input.used))
        # String construction transfers the temporary buffer; no value is retained in menu state.
        value=String(bytes)
        auth_callback_clear!(input)
        result=submit(value)
        input.received=result.ok
        input.warning=result.ok ? :none : :rejected
        (ok=result.ok,reason=result.ok ? :received : :rejected)
    end
end

auth_callback_notice(::Val{:none})=""
auth_callback_notice(::Val{:unsafe_input})="Use a percent-encoded URL without control characters."
auth_callback_notice(::Val{:too_long})="Callback URL exceeds the 8192-byte limit."
auth_callback_notice(::Val{:rejected})="Callback was rejected; the sign-in is not complete."
auth_callback_notice(::Val)="Callback input is unavailable."

"""Render only masked content and fixed safe messages, never any callback URL or service error."""
function auth_callback_lines(input::AuthCallbackInput,width::Integer;style=Returns(Tachikoma.Style()))
    input.width=max(0,Int(width))
    mask=input.used==0 ? "" : repeat("•",min(input.used,max(0,width-3)))
    message=input.received ? "Callback received; verifying sign-in…" : "Paste the final callback URL here (hidden):"
    prompt="> "*mask
    footer=input.received ? "Waiting for verified authentication completion." : "enter submit · esc cancel · ctrl+u clear"
    messages=[message,prompt,auth_callback_notice(Val(input.warning)),footer]
    [[Tachikoma.Span(menu_search_slice(message,0,max(0,Int(width))),style(index==2 ? :text : :dim))] for (index,message) in enumerate(messages)]
end
function auth_callback_cursor(input::AuthCallbackInput)
    input.received || input.disposed ? nothing : (x=min(2+input.cursor,max(0,input.width-1)),y=1)
end
