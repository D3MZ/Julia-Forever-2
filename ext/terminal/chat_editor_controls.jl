"""Resolve double-Escape using the actual elapsed interval and configured empty-editor action."""
function chat_escape_action!(editor::ChatEditorState,action::AbstractString,now_ms::Integer)
    selected=:none
    if isempty(strip(chat_text(editor))) && action in ("tree","fork")
        if now_ms-editor.last_escape_ms<500
            selected=Symbol(action);editor.last_escape_ms=0
        else
            editor.last_escape_ms=now_ms
        end
    end
    selected
end

"""Open the real durable tree or user-message selector only when a verified double-Escape requests it."""
function chat_editor_escape!(app::App,editor::ChatEditorState;now_ms::Integer=floor(Int,time()*1000))
    if app.busy
        restore_pending_input!(app;abort=true)
        (ok=true,reason="",action=:cancel_agent)
    elseif cancel_user_shell!(app)
        (ok=true,reason="",action=:cancel_shell)
    elseif startswith(lstrip(chat_text(editor)),"!")
        chat_completion_set_text!(chat_completion_state!(app),"")
        (ok=true,reason="",action=:clear_shell_draft)
    elseif app.operations.closing[]
        (ok=false,reason="A session operation is active",action=:none)
    else
        selected=chat_escape_action!(editor,menu_preference(app,"double-escape-action","tree"),now_ms)
        if selected==:none
            (ok=true,reason="",action=selected)
        else
            open_menu!(app,String(selected))
            available=selected==:tree ? !isnothing(app.menus.tree_menu) : !isnothing(app.menus.fork_menu)
            reason=available ? "" : "The requested session selector is unavailable"
            available || (app.status=reason)
            (ok=available,reason,action=selected)
        end
    end
end
