# Capability behavior follows Pi 2c8d1feb147f6b3d97e855da803bfe7b19f3c403 terminal-image.ts (MIT).
"""Detect positive hyperlink support without spawning terminal probes or changing global terminal state."""
function session_markdown_hyperlinks(environment::AbstractDict{<:AbstractString,<:AbstractString}=ENV;tmux_forwards::Bool=false)
    override=get(environment,"JF2_HYPERLINKS",get(environment,"PI_HYPERLINKS",""))
    term=lowercase(String(get(environment,"TERM","")))
    program=lowercase(String(get(environment,"TERM_PROGRAM","")))
    present(key)=!isempty(String(get(environment,key,"")))
    if override in ("0","1")
        override=="1"
    elseif present("TMUX")||startswith(term,"tmux")
        tmux_forwards
    elseif startswith(term,"screen")
        false
    else
        program in ("herdr","rex","kitty","ghostty","wezterm","warpterminal","iterm.app","alacritty","vscode","zed") ||
            program=="orca"&&get(environment,"ORCA_IMAGE_PROTOCOL","")=="kitty" || occursin("ghostty",term) ||
            any(present,("KITTY_WINDOW_ID","GHOSTTY_RESOURCES_DIR","WEZTERM_PANE","WARP_SESSION_ID","WARP_TERMINAL_SESSION_UUID","ITERM_SESSION_ID","WT_SESSION"))
    end
end

"""Only bounded, control-free HTTP(S) destinations become native terminal hyperlinks; no URL is opened."""
function session_markdown_link_target(value::AbstractString)
    target=String(value)
    valid=isvalid(target)&&ncodeunits(target)<=16384&&!any(c->iscntrl(c)||isspace(c),target)&&occursin(r"^https?://[^/?#@]+(?:[/?#]|$)",target)
    valid ? target : ""
end
