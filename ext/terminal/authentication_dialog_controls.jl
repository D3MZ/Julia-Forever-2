# Native login dialog presentation. Credentials and callback contents never enter display spans.
public auth_dialog_layout, auth_dialog_input!, auth_dialog_copy!, auth_dialog_owned

"""Style a native login span from the current theme, without changing active global colors."""
function auth_dialog_span(app,text::AbstractString,token::Symbol=:default;bold::Bool=false,hyperlink::String="")
    base=auth_menu_style(app,token)
    style=Tachikoma.Style(;fg=base.fg,bg=base.bg,bold=base.bold || bold,dim=base.dim,
        italic=base.italic,underline=base.underline,strikethrough=base.strikethrough,hyperlink)
    Tachikoma.Span(String(text),style)
end

auth_dialog_margin_style(base::Tachikoma.Style)=Tachikoma.Style(;fg=base.fg,bg=base.bg,bold=base.bold,dim=base.dim,
    italic=base.italic,underline=base.underline,strikethrough=base.strikethrough)

"""Wrap text with the reference dialog's one-column margin and ANSI-aware style carry."""
function auth_dialog_text(spans::AbstractVector{Tachikoma.Span},width::Int; padding::Int=1)
    margin=min(padding,max(0,fld(width-1,2)))
    lines=Vector{Tachikoma.Span}[]
    leading=Tachikoma.Style()
    for row in model_menu_wrap(spans,max(1,width-2margin))
        trailing=isempty(row) ? Tachikoma.Style() : auth_dialog_margin_style(last(row).style)
        if !isempty(row)
            padding_span=last(row)
            row[end]=Tachikoma.Span(padding_span.content,auth_dialog_margin_style(padding_span.style))
        end
        push!(lines,Tachikoma.Span[Tachikoma.Span(repeat(" ",margin),leading);row;Tachikoma.Span(repeat(" ",margin),trailing)])
        leading=trailing
    end
    lines
end

"""Only the current native authorization URL may become a web hyperlink or clipboard target."""
function auth_dialog_url(app)
    value=app.settings.auth_url
    safe=isvalid(value) && ncodeunits(value)<=16384 && !any(c->iscntrl(c) || isspace(c),value) && occursin(r"^https?://[^/?#@]+(?:[/?#]|$)",value)
    safe ? value : ""
end

auth_dialog_owned(app,::Nothing)=app.page==:auth && !app.operations.closing[] && !isnothing(app.settings.auth_flow)
auth_dialog_owned(app,control::AuthMenuControl)=auth_menu_owned(app,control) && app.page==:auth && control.stage==:auth && !isnothing(control.flow) && app.settings.auth_flow===control.flow

"""Copy only the announced authorization link through the actual terminal clipboard service."""
function auth_dialog_copy!(app,control;copy=copy_terminal_text!)
    url=auth_dialog_url(app)
    if auth_dialog_owned(app,control) && !isempty(url)
        copy(app,url)
    else
        false
    end
end

function auth_dialog_copy_hint(app,url::String)
    hint=Sys.isapple() ? "Cmd+click to open" : "Ctrl+click to open"
    spans=[auth_dialog_span(app,hint,:dim;hyperlink=url),auth_dialog_span(app," "),auth_dialog_span(app,"•",:dim),auth_dialog_span(app," ")]
    if app.status=="Copied to clipboard"
        push!(spans,auth_dialog_span(app,"Copied URL to clipboard",:success))
    elseif app.status in ("Clipboard transfer failed.","No supported clipboard destination")
        push!(spans,auth_dialog_span(app,app.status,:error))
    elseif app.status=="Clipboard transfer sent to terminal; confirmation unavailable"
        push!(spans,auth_dialog_span(app,"Clipboard transfer sent; confirmation unavailable",:dim))
    else
        append!(spans,[auth_dialog_span(app,"ctrl+x",:dim),auth_dialog_span(app," to copy",:muted)])
    end
    spans
end

function auth_dialog_cancel_hint(app)
    [auth_dialog_span(app,"("),auth_dialog_span(app,"escape/ctrl+c",:dim),auth_dialog_span(app," to cancel",:muted),auth_dialog_span(app,")")]
end

auth_dialog_provider_name(::Nothing,id::Symbol)=string(id)
auth_dialog_provider_name(descriptor::JuliaForever2.ProviderDescriptor,::Symbol)=descriptor.label

"""Return a real native dialog plus relative cursor; host scene composition owns placement."""
function auth_dialog_layout(app,control,width::Integer)
    columns=max(1,Int(width))
    lines=Vector{Tachikoma.Span}[]
    cursor=nothing
    if auth_dialog_owned(app,control) && control isa AuthMenuControl && !isnothing(control.key_method)
        key_layout=api_key_dialog_layout(app,control,columns)
        lines=key_layout.lines
        cursor=key_layout.cursor
    elseif auth_dialog_owned(app,control)
        border=[auth_dialog_span(app,repeat("─",columns),:menu_border)]
        push!(lines,border)
        descriptor=provider_descriptor(app.settings.registry,app.settings.auth_provider)
        name=auth_dialog_provider_name(descriptor,app.settings.auth_provider)::String
        append!(lines,auth_dialog_text([auth_dialog_span(app,"Login to "*name,:accent;bold=auth_menu_bold(app.menus.theme_runtime))],columns))
        url=auth_dialog_url(app)
        if !isempty(url)
            push!(lines,Tachikoma.Span[])
            append!(lines,auth_dialog_text([auth_dialog_span(app,url,:accent;hyperlink=url)],columns))
            append!(lines,auth_dialog_text(auth_dialog_copy_hint(app,url),columns))
        elseif !isempty(app.settings.auth_url)
            push!(lines,Tachikoma.Span[])
            append!(lines,auth_dialog_text([auth_dialog_span(app,"Authorization URL is unavailable or unsafe.",:error)],columns))
        end
        if control isa AuthMenuControl && auth_menu_manual_active(app,control)
            input=control.callback_input
            push!(lines,Tachikoma.Span[])
            prompt="Complete login in your browser, or paste the final redirect URL here:"
            append!(lines,auth_dialog_text([auth_dialog_span(app,prompt,:dim)],columns))
            if input.received
                append!(lines,auth_dialog_text([auth_dialog_span(app,"> Callback received; verifying sign-in…")],columns;padding=0))
            else
                # A separate display-only editor contains bullets, never callback bytes.
                masked=MenuSearchInput(;value=repeat("•",input.used),cursor=input.cursor)
                row=menu_search_spans(masked,columns)
                cursor=(x=min(2+masked.cursor-masked.rendered_start_column,columns-1),y=length(lines))
                push!(lines,row)
            end
            if input.warning!=:none
                append!(lines,auth_dialog_text([auth_dialog_span(app,auth_callback_notice(Val(input.warning)),:error)],columns))
            end
            append!(lines,auth_dialog_text(auth_dialog_cancel_hint(app),columns))
        end
        push!(lines,border)
    end
    (;lines,cursor)
end

"""Keep cancellation, URL-copy and private paste inside the same owned authentication dialog."""
function auth_dialog_input!(app,control,event::KeyEvent,raw::AbstractVector{UInt8}=UInt8[];copy=copy_terminal_text!)
    handled=auth_dialog_owned(app,control)
    if handled && control isa AuthMenuControl && !isnothing(control.key_method)
        api_key_dialog_input!(app,control,event,raw)
    elseif handled
        packet=menu_packet(event,raw)
        pasting=control isa AuthMenuControl && control.callback_input.pasting
        if !pasting && packet=="\x18"
            auth_dialog_copy!(app,control;copy)
        elseif control isa AuthMenuControl && auth_menu_manual_active(app,control)
            auth_menu_manual_input!(app,control,event,raw)
        elseif packet in ("\e","\x03")
            if control isa AuthMenuControl
                auth_menu_cancel_auth!(app,control)
            else
                flow=app.settings.auth_flow
                if !isnothing(flow)
                    cancel_auth!(flow)
                    app.status="Cancelling sign-in…"
                end
            end
        end
    end
    handled
end
