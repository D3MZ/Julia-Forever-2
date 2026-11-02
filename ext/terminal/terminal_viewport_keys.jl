# Native fullscreen key normalization derived from pinned Pi keys.ts (MIT, licenses/pi-LICENSE).
terminal_viewport_modifier(::Nothing)=0
terminal_viewport_modifier(value::AbstractString)=something(tryparse(Int,value),0)-1

"""Recognize only original default viewport packets, retaining modifiers and release ownership."""
function terminal_viewport_action(packet::AbstractString)::Symbol
    text=String(packet)::String
    action=:none
    if !occursin("\e[200~",text)
        if occursin(r":3[u~ABCDHFPQS]",text)
            action=:release
        elseif text in ("\e[7^","\e[8^")
            action=text=="\e[7^" ? :top : :bottom
        else
            functional=match(r"^\e\[(5|6|7|8)(?:;(\d+))?(?::(\d+))?~$",text)
            home_end=match(r"^\e\[1;(\d+)(?::(\d+))?([HF])$",text)
            if !isnothing(functional)
                code=functional.captures[1]
                modifiers=terminal_viewport_modifier(functional.captures[2])
                actual=modifiers & ~192
                if code in ("5","6") && actual==0
                    action=code=="5" ? :page_up : :page_down
                elseif code in ("7","8") && actual==4
                    action=code=="7" ? :top : :bottom
                end
            elseif !isnothing(home_end)
                actual=terminal_viewport_modifier(home_end.captures[1]) & ~192
                actual==4 && (action=home_end.captures[3]=="H" ? :top : :bottom)
            end
        end
    end
    action
end
