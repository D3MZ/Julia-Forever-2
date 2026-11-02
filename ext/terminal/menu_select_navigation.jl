# Native default selector navigation derived from Pi keys.ts (MIT), pinned
# 2c8d1feb147f6b3d97e855da803bfe7b19f3c403; license: licenses/pi-LICENSE.
"""Match plain selector movement without discarding real terminal modifiers or release events."""
function menu_select_navigation(packet::AbstractString)::Symbol
    text=String(packet)::String
    action=text in ("\e[A","\eOA") ? :up : text in ("\e[B","\eOB") ? :down :
        text in ("\e[5~","\e[[5~") ? :page_up : text in ("\e[6~","\e[[6~") ? :page_down : :none
    if action==:none
        arrow=match(r"^\e\[1;(\d+)(?::(\d+))?([AB])$",text)
        page=match(r"^\e\[(5|6)(?:;(\d+))?(?::(\d+))?~$",text)
        keypad=match(r"^\e\[(57419|57420|57421|57422)(?::(\d*))?(?::(\d+))?(?:;(\d+))?(?::(\d+))?u$",text)
        if !isnothing(arrow)
            modifier=terminal_viewport_modifier(arrow.captures[1]) & ~192
            action=arrow.captures[2]=="3" ? :release : modifier==0 ? (arrow.captures[3]=="A" ? :up : :down) : :none
        elseif !isnothing(page)
            modifier=terminal_viewport_modifier(page.captures[2]) & ~192
            action=page.captures[3]=="3" ? :release : modifier==0 ? (page.captures[1]=="5" ? :page_up : :page_down) : :none
        elseif !isnothing(keypad)
            modifier=terminal_viewport_modifier(keypad.captures[4]) & ~192
            key=keypad.captures[1]
            action=keypad.captures[5]=="3" ? :release : modifier==0 ?
                (key=="57419" ? :up : key=="57420" ? :down : key=="57421" ? :page_up : :page_down) : :none
        end
    end
    action
end
