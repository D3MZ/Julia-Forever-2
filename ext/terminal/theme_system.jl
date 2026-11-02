# Native terminal-adaptive theme generation. Recipe data is attributed in theme_assets/LICENSE.
const THEME_SYSTEM_RECIPE = JSON.parsefile(joinpath(@__DIR__,"theme_assets","system-recipe.json"))

"""Compute relative luminance without assuming a terminal's foreground or background."""
theme_luminance(rgb) = theme_dot((0.2126,0.7152,0.0722),map(value -> theme_linear(value/255),rgb))
theme_contrast(a,b) = (max(theme_luminance(a),theme_luminance(b))+0.05)/(min(theme_luminance(a),theme_luminance(b))+0.05)

"""Classify a reported terminal surface, honoring readable foreground direction first."""
function theme_terminal_appearance(background,foreground=nothing)
    white,black = theme_contrast((255,255,255),background),theme_contrast((0,0,0),background)
    appearance = white >= black ? :dark : :light
    if !isnothing(foreground)
        difference = first(theme_lab(foreground))-first(theme_lab(background))
        if abs(difference)>0.05 && (difference>0 ? white : black)>=4.5
            appearance = difference>0 ? :dark : :light
        end
    end
    appearance
end

"""Use terminal reports before COLORFGBG and the conservative dark fallback."""
function theme_detect_appearance(;background=nothing,foreground=nothing,reported=nothing,colorfgbg::AbstractString="")
    appearance = reported in (:dark,:light) ? reported : :dark
    if isnothing(reported)
        value = last(split(colorfgbg,';'))
        if occursin(r"^\d{1,2}$",strip(value))
            index = parse(Int,strip(value))
            if index<=15
                appearance = index<=6 || index==8 ? :dark : :light
            end
        end
    end
    isnothing(background) ? appearance : theme_terminal_appearance(background,foreground)
end

theme_bell(value) = (exp(-(value-0.5)^2/(2*0.25^2))-exp(-0.5^2/(2*0.25^2)))/(1-exp(-0.5^2/(2*0.25^2)))
function theme_saturation_curve(family,lightness)
    low,high = family["saturation"]["min"],family["saturation"]["max"]
    floor = high>0 ? low/high : 1
    floor+(1-floor)*theme_bell(lightness)
end
function theme_source(rgb)
    channels = theme_rgb_okhsl(rgb)
    lab = theme_lab(rgb)
    (h=channels.h,s=channels.s,l=channels.l,chroma=hypot(lab[2],lab[3]))
end

"""Keep palette hue and cap chroma so pastel colors never become oversaturated."""
function theme_anchor(source,family,lightness,saturation)
    anchor = theme_saturation_curve(family,source.l)
    falloff = anchor>0 ? min(1,theme_saturation_curve(family,lightness)/anchor) : 1
    rgb = theme_okhsl_rgb(source.h,source.s*falloff*saturation,lightness)
    cap = source.chroma*falloff*saturation
    lab = theme_lab(rgb)
    hypot(lab[2],lab[3]) <= cap ? rgb : theme_oklch_rgb(lab[1],cap,source.h)
end

function theme_level_target(level,appearance,surface)::Union{Nothing,Float64}
    curve = THEME_SYSTEM_RECIPE["levels"][level][String(appearance)]
    low,high = curve["reachable"]
    low <= surface <= high ? sum(coefficient*surface^(index-1) for (index,coefficient) in enumerate(curve["coefficients"])) : nothing
end

"""Relax contrast constraints only as far as a middle-gray surface requires."""
function theme_system_target(level,appearance,surface,relaxation)::Union{Nothing,Float64}
    reached = theme_level_target(level,appearance,surface)
    target = nothing
    if !isnothing(reached) || relaxation!=0
        extreme = appearance==:dark ? 1 : 0
        distance = something(reached,extreme)-surface
        floor = something(theme_level_target(THEME_SYSTEM_RECIPE["readableFloor"][String(appearance)],appearance,surface),extreme)-surface
        compressed = abs(distance)>abs(floor) ? distance-(distance-floor)*min(relaxation,1) : distance
        target = surface+compressed*(1-max(0,relaxation-1))
    end
    target
end

"""Raise text contrast on every underlying panel while retaining its hue."""
function theme_text_contrast(rgb,surfaces,lighter)
    meets(candidate) = all(surface -> theme_contrast(candidate,surface)>=4.5,surfaces)
    result = rgb
    if !meets(rgb)
        hsl = theme_rgb_okhsl(rgb)
        at(lightness) = theme_okhsl_rgb(hsl.h,hsl.s,lightness)
        extreme = lighter ? 1.0 : 0.0
        result = at(extreme)
        if meets(result)
            low,high = hsl.l,extreme
            for _ in 1:20
                middle = (low+high)/2
                if meets(at(middle))
                    high = middle
                else
                    low = middle
                end
            end
            result = at(high)
        end
    end
    result
end

"""Generate concrete native colors from terminal reports, or indexed/default colors without reports."""
function theme_system_colors(;background=nothing,foreground=nothing,palette=Tuple{Int,Int,Int}[],pending::Bool=false,appearance::Symbol=:dark)
    recipe = THEME_SYSTEM_RECIPE
    colors = Dict{String,Tachikoma.AbstractColor}()
    dim = Set{String}()
    saturation = pending ? 0.0 : 1.0
    if isnothing(background)
        for (token,family_name) in recipe["tokenFamilies"]
            family = recipe["families"][family_name]
            neutral = family_name=="neutral"
            colors[token] = token in recipe["panels"] || neutral || pending ? Tachikoma.NoColor() :
                Tachikoma.Color256(Int(get(recipe["tokenSlots"],token,family["slot"])))
            if !(token in recipe["panels"]) && neutral && !(token in recipe["foregroundTokens"])
                push!(dim,token)
            end
        end
    else
        appearance = theme_terminal_appearance(background,foreground)
        lighter = appearance==:dark
        background_l = first(theme_lab(background))
        sources = length(palette)==16 ? theme_source.(palette) : []
        function paint(token,lab_lightness)
            lightness = theme_toe(lab_lightness)
            family = recipe["families"][recipe["tokenFamilies"][token]]
            if isempty(sources)
                low,high = family["saturation"]["min"],family["saturation"]["max"]
                theme_okhsl_rgb(family["hue"],(low+(high-low)*theme_bell(lightness))*saturation,lightness)
            else
                index = Int(get(recipe["tokenSlots"],token,family["slot"]))+1
                theme_anchor(sources[index],family,lightness,saturation)
            end
        end
        function panel(token,lightness)
            result = paint(token,lightness)
            extreme = lighter ? (255,255,255) : (0,0,0)
            if theme_contrast(extreme,result)<4.5
                panel_low,panel_high = background_l,lightness
                for _ in 1:20
                    middle = (panel_low+panel_high)/2
                    if theme_contrast(extreme,paint(token,middle))>=4.5
                        panel_low = middle
                    else
                        panel_high = middle
                    end
                end
                result = paint(token,panel_low)
            end
            result
        end
        function solve(relaxation)
            candidate_colors = Dict{String,NTuple{3,Int}}("background"=>background)
            valid = true
            for token in recipe["solveOrder"]
                constraint_targets = Float64[]
                for rule in recipe["rules"]
                    if rule["token"]==token
                        for surface in rule["on"]
                            surface_l = first(theme_lab(get(candidate_colors,surface,background)))
                            value = theme_system_target(rule["level"],appearance,surface_l,relaxation)
                            if isnothing(value) || !(0<=value<=1)
                                valid = false
                            else
                                push!(constraint_targets,value)
                            end
                        end
                    end
                end
                if valid && !isempty(constraint_targets)
                    lightness = lighter ? maximum(constraint_targets) : minimum(constraint_targets)
                    candidate_colors[token] = token in recipe["panels"] ? panel(token,lightness) : paint(token,lightness)
                end
            end
            valid ? candidate_colors : nothing
        end
        relaxation = 0.0
        solved = solve(0.0)
        if isnothing(solved)
            low,high = 0.0,2.0
            solved = solve(high)
            for _ in 1:20
                middle = (low+high)/2
                attempt = solve(middle)
                if isnothing(attempt)
                    low = middle
                else
                    high,solved = middle,attempt
                end
            end
            relaxation = high
        end
        resolved = isnothing(solved) ? Dict{String,NTuple{3,Int}}() : solved
        for token in keys(recipe["tokenFamilies"])
            colors[token] = haskey(resolved,token) ? Tachikoma.ColorRGB(resolved[token]...) : Tachikoma.NoColor()
        end
        for token in recipe["foregroundTokens"]
            surfaces = [get(resolved,surface,background) for rule in recipe["rules"] if rule["token"]==token for surface in rule["on"]]
            rgb = get(resolved,token,nothing)
            default = false
            if !isnothing(foreground)
                targets = [theme_system_target("emphasis",appearance,first(theme_lab(surface)),relaxation) for surface in surfaces]
                if all(value -> value isa Float64 && 0<=value<=1,targets)
                    values = Float64[something(value,0.0) for value in targets]
                    needed = lighter ? maximum(values) : minimum(values)
                    foreground_l = first(theme_lab(foreground))
                    default = lighter ? foreground_l>=needed : foreground_l<=needed
                    if !default
                        rgb = theme_anchor(theme_source(foreground),recipe["families"]["neutral"],theme_toe(needed),saturation)
                    end
                end
            end
            if default
                colors[token] = Tachikoma.NoColor()
            elseif !isnothing(rgb)
                colors[token] = Tachikoma.ColorRGB(theme_text_contrast(rgb,surfaces,lighter)...)
            end
        end
    end
    (colors=colors,dim=dim,appearance=appearance)
end
