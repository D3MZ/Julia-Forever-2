"""Ordered presentation semantics; concrete key assignments come from the installed native handlers."""
const COMMAND_HOTKEY_GROUPS=(
    ("Navigation",[
        (["tui.editor.cursorUp","tui.editor.cursorDown","tui.editor.cursorLeft","tui.editor.cursorRight"],"Move cursor / browse history"),
        (["tui.editor.cursorWordLeft","tui.editor.cursorWordRight"],"Move by word"),
        (["tui.editor.cursorLineStart"],"Start of line"),(["tui.editor.cursorLineEnd"],"End of line"),
        (["tui.editor.jumpForward"],"Jump forward to character"),(["tui.editor.jumpBackward"],"Jump backward to character"),
        (["tui.editor.pageUp","tui.editor.pageDown"],"Scroll by page")]),
    ("Editing",[
        (["tui.input.submit"],"Send message"),(["tui.input.newLine"],"New line"),
        (["tui.editor.deleteWordBackward"],"Delete word backwards"),(["tui.editor.deleteWordForward"],"Delete word forwards"),
        (["tui.editor.deleteToLineStart"],"Delete to start of line"),(["tui.editor.deleteToLineEnd"],"Delete to end of line"),
        (["tui.editor.yank"],"Paste the most-recently-deleted text"),(["tui.editor.yankPop"],"Cycle through the deleted text after pasting"),
        (["tui.editor.undo"],"Undo")]),
    ("Other",[
        (["tui.input.tab"],"Path completion / accept autocomplete"),(["app.interrupt"],"Cancel autocomplete / abort streaming"),
        (["app.clear"],"Clear editor (first) / exit (second)"),(["app.exit"],"Exit (when editor is empty)"),
        (["app.suspend"],"Suspend to background"),(["app.thinking.cycle"],"Cycle thinking level"),
        (["app.model.cycleForward","app.model.cycleBackward"],"Cycle models"),(["app.model.select"],"Open model selector"),
        (["app.tools.expand"],"Toggle tool output expansion"),(["app.thinking.toggle"],"Toggle thinking block visibility"),
        (["app.editor.external"],"Edit message in external editor"),(["app.message.copy"],"Copy selection or last assistant message"),
        (["app.message.followUp"],"Queue follow-up message"),(["app.message.dequeue"],"Restore queued messages"),
        (["app.clipboard.pasteImage"],"Paste files on macOS, images, or text from clipboard"),
        (["command.slash"],"Slash commands"),(["command.bash"],"Run bash command"),(["command.bashExcluded"],"Run bash command (excluded from context)")]))

function command_key_label(keys::AbstractString;macos::Bool=Sys.isapple())
    join((join((uppercasefirst(macos && lowercase(part)=="alt" ? "option" : part) for part in split(key,'+';keepempty=true)),"+") for key in split(keys,'/';keepempty=true)),"/")
end
command_hotkey_safe(value::AbstractString)=replace(session_display_safe(value),'\n'=>" ",'|'=>"\\|",'`'=>"'")

"""Generate the source-equivalent table while marking, not promising, unavailable native actions."""
function command_hotkeys_markdown(bindings::AbstractDict;extensions=Pair{String,String}[],macos::Bool=Sys.isapple(),windows::Bool=Sys.iswindows())
    output=String[]
    for (group,items) in COMMAND_HOTKEY_GROUPS
        lines=["**"*group*"**","| Key | Action |","|-----|--------|"]
        for (actions,description) in items
            keys=String[]
            for action in actions
                value=get(bindings,action,nothing)
                push!(keys,value isa AbstractString && !isempty(value) ? "`"*command_hotkey_safe(command_key_label(value;macos))*"`" : "Unavailable")
            end
            suffix=windows && actions==["tui.input.newLine"] ? " (Ctrl+Enter on Windows Terminal)" : ""
            push!(lines,"| "*join(keys," / ")*" | "*description*suffix*" |")
        end
        push!(output,join(lines,"\n"))
    end
    if !isempty(extensions)
        lines=["**Extensions**","| Key | Action |","|-----|--------|"]
        for (key,description) in extensions
            push!(lines,"| `"*command_hotkey_safe(command_key_label(key;macos))*"` | "*command_hotkey_safe(description)*" |")
        end
        push!(output,join(lines,"\n"))
    end
    join(output,"\n\n")
end

"""Inspect only actual installed editing mappings, excluding actions delegated to an unproven owner."""
function command_editor_bindings()
    specs=[
        ("tui.editor.cursorUp",:up,["\e[A"=>"up"]),("tui.editor.cursorDown",:down,["\e[B"=>"down"]),
        ("tui.editor.cursorLeft",:left,["\e[D"=>"left","\x02"=>"ctrl+b"]),("tui.editor.cursorRight",:right,["\e[C"=>"right","\x06"=>"ctrl+f"]),
        ("tui.editor.cursorWordLeft",:word_left,["\e[1;3D"=>"alt+left","\e[1;5D"=>"ctrl+left","\eb"=>"alt+b"]),
        ("tui.editor.cursorWordRight",:word_right,["\e[1;3C"=>"alt+right","\e[1;5C"=>"ctrl+right","\ef"=>"alt+f"]),
        ("tui.editor.cursorLineStart",:home,["\e[H"=>"home","\x01"=>"ctrl+a"]),("tui.editor.cursorLineEnd",:end,["\e[F"=>"end","\x05"=>"ctrl+e"]),
        ("tui.editor.jumpForward",:jump_forward,["\x1d"=>"ctrl+]"]),("tui.editor.jumpBackward",:jump_backward,["\e\x1d"=>"ctrl+alt+]"]),
        ("tui.editor.pageUp",:page_up,["\e[5~"=>"pageUp","\e[5;5~"=>"ctrl+pageUp"]),("tui.editor.pageDown",:page_down,["\e[6~"=>"pageDown","\e[6;5~"=>"ctrl+pageDown"]),
        ("tui.input.newLine",:newline,["\e[13;2u"=>"shift+enter","\n"=>"ctrl+j"]),
        ("tui.editor.deleteWordBackward",:delete_word_backward,["\x17"=>"ctrl+w","\e\x7f"=>"alt+backspace"]),
        ("tui.editor.deleteWordForward",:delete_word_forward,["\ed"=>"alt+d","\e[3;3~"=>"alt+delete"]),
        ("tui.editor.deleteToLineStart",:delete_start,["\x15"=>"ctrl+u"]),("tui.editor.deleteToLineEnd",:delete_end,["\x0b"=>"ctrl+k"]),
        ("tui.editor.yank",:yank,["\x19"=>"ctrl+y"]),("tui.editor.yankPop",:yank_pop,["\ey"=>"alt+y"]),("tui.editor.undo",:undo,["\x1f"=>"ctrl+-"])]
    bindings=Dict{String,String}()
    for (name,action,keys) in specs
        live=[display for (packet,display) in keys if get(CHAT_EDITOR_KEYS,packet,:none)==action]
        !isempty(live) && (bindings[name]=join(live,"/"))
    end
    bindings
end

function hotkeys_command!(app::App;bindings=Dict{String,String}(),extensions=Pair{String,String}[])
    append_command_document!(app,"Keyboard Shortcuts",CommandHotkeyTable(command_hotkeys_markdown(bindings;extensions)))
end

"""Project the live host registry; unavailable future integrations are not advertised as active."""
function command_installed_bindings(app::App)
    bindings=Dict{String,String}("command.slash"=>"/","tui.input.submit"=>"enter")
    if isdefined(@__MODULE__,:startup_host_bindings)
        merge!(bindings,startup_host_bindings(app))
    end
    if isdefined(@__MODULE__,:chat_host_packet!)
        merge!(bindings,command_editor_bindings())
        bindings["app.clear"]="ctrl+c"
        bindings["app.exit"]="ctrl+d"
    end
    bindings
end
