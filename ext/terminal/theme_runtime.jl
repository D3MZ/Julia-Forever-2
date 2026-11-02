# Julia-owned theme loading, preview and persistence; Pi-compatible immutable assets are MIT attributed.
public NativeTheme, ThemeCatalog, ThemeRuntime, theme_catalog, theme_available, theme_load
public theme_preview!, theme_apply!, theme_revert!, theme_refresh!, theme_terminal!, theme_style, theme_store!
public theme_auto_setting, theme_resolve_setting, theme_read_document, theme_restore, theme_token_style, activate_theme_runtime!

const THEME_TOKEN_METADATA = JSON.parsefile(joinpath(@__DIR__,"theme_assets","tokens.json"))
const THEME_STYLE_ALIASES = Dict(:menu_border=>"border",:border=>"borderAccent",:text_dim=>"dim",:text=>"text",
    :accent=>"accent",:muted=>"muted",:success=>"success",:warning=>"warning",:error=>"error")

Base.@kwdef struct NativeTheme
    name::String
    colors::Dict{String,Tachikoma.AbstractColor}
    dim::Set{String} = Set{String}()
    appearance::Symbol = :dark
    source::Union{Nothing,String} = nothing
    export_colors::Dict{String,Tachikoma.AbstractColor} = Dict{String,Tachikoma.AbstractColor}()
    mode::Symbol = :truecolor
    bold::Bool = false
    native_extra::Union{Nothing,Tachikoma.Theme} = nothing
end
Base.@kwdef struct ThemeLoadResult
    ok::Bool = false
    theme::Union{Nothing,NativeTheme} = nothing
    reason::String = ""
end
Base.@kwdef mutable struct ThemeCatalog
    directory::String = ""
    registered::Dict{String,NativeTheme} = Dict{String,NativeTheme}()
    extras::Dict{String,NativeTheme} = Dict{String,NativeTheme}()
    diagnostics::Vector{String} = String[]
    background::Union{Nothing,NTuple{3,Int}} = nothing
    foreground::Union{Nothing,NTuple{3,Int}} = nothing
    palette::Vector{NTuple{3,Int}} = NTuple{3,Int}[]
    mode::Symbol = :truecolor
    bold::Bool = haskey(ENV,"FORCE_COLOR") ? get(ENV,"FORCE_COLOR","0")!="0" : stdout isa Base.TTY
    pending::Bool = false
    appearance::Symbol = :dark
end
Base.@kwdef mutable struct ThemeRuntime
    catalog::ThemeCatalog
    active::NativeTheme
    committed::String
    requested::String
    owner_name::String
    settings_path::String = ""
    last_error::String = ""
    native_baseline::Tachikoma.Theme = Tachikoma.theme()
end

"""Resolve color variables with explicit missing/cycle diagnostics and no recursive stack growth."""
function theme_variable(value,vars)
    seen = Set{String}()
    result = value
    valid = true
    while valid && result isa AbstractString && !isempty(result) && !startswith(result,"#") && !occursin(r"^ok(lch|hsl)\("i,result)
        key = String(result)
        if key in seen || !haskey(vars,key)
            valid = false
        else
            push!(seen,key)
            result = vars[key]
        end
    end
    valid ? theme_color(result) : nothing
end

"""Validate and resolve a complete Pi-compatible JSON theme without silently replacing invalid tokens."""
function theme_read_document(data;source=nothing,mode::Symbol=:truecolor,bold::Bool=false)
    result = ThemeLoadResult(;reason="Theme must be a JSON object with name and colors")
    if data isa AbstractDict
        name,raw = get(data,"name",nothing),get(data,"colors",nothing)
        vars = get(data,"vars",Dict{String,Any}())
        appearance = get(data,"appearance",nothing)
        exports = get(data,"export",Dict{String,Any}())
        fields = Set(["\$schema","name","appearance","vars","colors","export"])
        valid = name isa AbstractString && !isempty(name) && !occursin('/',name) && raw isa AbstractDict && vars isa AbstractDict &&
            exports isa AbstractDict && (isnothing(appearance) || appearance in ("dark","light")) && all(key -> key in fields,keys(data)) &&
            (!haskey(data,"\$schema") || data["\$schema"] isa AbstractString) && all(theme_valid_value,values(vars))
        if valid
            missing = [key for (key,description) in THEME_TOKEN_METADATA if !haskey(raw,key) && !haskey(description,"fallback")]
            unknown = [key for key in keys(raw) if !haskey(THEME_TOKEN_METADATA,key)]
            colors = Dict{String,Tachikoma.AbstractColor}()
            invalid = String[]
            for (key,value) in raw
                color = theme_variable(value,vars)
                if isnothing(color)
                    push!(invalid,string(key))
                else
                    colors[string(key)] = color
                end
            end
            for (key,description) in THEME_TOKEN_METADATA
                if !haskey(colors,key) && haskey(description,"fallback") && haskey(colors,description["fallback"])
                    colors[key] = colors[description["fallback"]]
                end
            end
            export_colors = Dict{String,Tachikoma.AbstractColor}()
            for (key,value) in exports
                color = theme_variable(value,vars)
                if !(key in ("pageBg","cardBg","infoBg")) || isnothing(color)
                    push!(invalid,"export/"*(string(key)::String))
                else
                    export_colors[string(key)] = color
                end
            end
            if isempty(missing) && isempty(unknown) && isempty(invalid)
                resolved_appearance = isnothing(appearance) ? theme_infer_appearance(colors) : Symbol(appearance)
                result = ThemeLoadResult(;ok=true,theme=NativeTheme(;name=String(name),colors,appearance=resolved_appearance,source,export_colors,mode,bold))
            else
                result = ThemeLoadResult(;reason="Invalid theme $(name): missing=$(join(sort(missing),',')); unknown=$(join(sort(string.(unknown)),',')); invalid=$(join(sort(invalid),','))")
            end
        else
            result = ThemeLoadResult(;reason="Invalid theme metadata, name, variables or colors")
        end
    end
    result
end

"""Infer background appearance from concrete theme colors, excluding mutable ANSI palette slots."""
function theme_infer_appearance(colors)
    foreground,background = Float64[],Float64[]
    for (token,color) in colors
        if color isa Tachikoma.ColorRGB || color isa Tachikoma.Color256 && color.code>=16
            values = THEME_TOKEN_METADATA[token]["slot"]=="foreground" ? foreground : background
            push!(values,first(theme_lab(theme_rgb(color))))
        end
    end
    fg = isempty(foreground) ? nothing : sum(foreground)/length(foreground)
    bg = isempty(background) ? nothing : sum(background)/length(background)
    if !isnothing(fg) && !isnothing(bg)
        bg < fg ? :dark : :light
    elseif !isnothing(bg)
        bg < 0.5 ? :dark : :light
    elseif !isnothing(fg)
        fg > 0.5 ? :dark : :light
    else
        :dark
    end
end

"""Read a theme document after validating JSON syntax and the regular-file boundary."""
function theme_read_path(path::AbstractString;mode::Symbol=:truecolor,bold::Bool=false)
    result = ThemeLoadResult(;reason="Theme file not found: $path")
    if isfile(path) && !islink(path)
        text = replace(read(path,String),r"^\ufeff"=>"")
        data = JSON.isvalidjson(text) ? JSON.parse(text) : nothing
        result = theme_read_document(data;source=String(path),mode,bold)
    end
    result
end

"""Retain every existing Tachikoma theme as a real selectable Julia extension."""
function theme_native_extra(native::Tachikoma.Theme)
    mapping = Dict("accent"=>native.accent,"border"=>native.border,"borderAccent"=>native.border_focus,
        "borderMuted"=>native.border,"success"=>native.success,"error"=>native.error,"warning"=>native.warning,
        "muted"=>native.text_dim,"dim"=>native.text_dim,"text"=>native.text,"mdHeading"=>native.title,
        "mdLink"=>native.primary,"mdCode"=>native.secondary,"thinkingHigh"=>native.accent)
    colors = Dict{String,Tachikoma.AbstractColor}(token=>get(mapping,token,descriptor["slot"]=="background" ? native.bg : native.text) for (token,descriptor) in THEME_TOKEN_METADATA)
    NativeTheme(;name=native.name,colors,appearance=native in Tachikoma.LIGHT_THEMES ? :light : :dark,native_extra=native)
end

"""Create a replaceable catalog, preserving native extras without disguising them as Pi builtins."""
function theme_catalog(directory::AbstractString="";preserve_extras::Bool=true)
    extras = preserve_extras ? Dict(theme.name=>theme_native_extra(theme) for theme in Tachikoma.ALL_THEMES) : Dict{String,NativeTheme}()
    ThemeCatalog(;directory=String(directory),extras)
end

"""Sort Latin names with case/diacritic-aware keys while always listing system first."""
function theme_name_key(name::AbstractString)
    base = Base.Unicode.normalize(name;casefold=true,stripmark=true)
    accents = Base.Unicode.normalize(name;casefold=true,decompose=true)
    cases = join(isuppercase(c) ? '1' : '0' for c in name)
    (name=="system" ? 0 : 1,base,accents,cases)
end

"""Discover valid custom files and retain diagnostics for files that cannot be applied."""
function theme_available(catalog::ThemeCatalog)
    names = Set(["system","dark","light"])
    empty!(catalog.diagnostics)
    if !isempty(catalog.directory) && isdir(catalog.directory)
        for filename in readdir(catalog.directory)
            if endswith(filename,".json")
                result = theme_read_path(joinpath(catalog.directory,filename))
                if result.ok
                    push!(names,result.theme.name)
                else
                    push!(catalog.diagnostics,result.reason)
                end
            end
        end
    end
    union!(names,keys(catalog.extras),keys(catalog.registered))
    sort!(collect(names);by=theme_name_key)
end

"""Load one real palette with system, registered, builtin, custom and native-extra precedence."""
function theme_load(catalog::ThemeCatalog,name::AbstractString)
    if name=="system"
        ThemeLoadResult(;ok=true,theme=theme_system_palette(catalog))
    elseif haskey(catalog.registered,name)
        ThemeLoadResult(;ok=true,theme=catalog.registered[name])
    elseif name in ("dark","light")
        theme_read_path(joinpath(@__DIR__,"theme_assets",name*".json");mode=catalog.mode,bold=catalog.bold)
    elseif !occursin('/',name) && !occursin('\\',name) && !isempty(catalog.directory) && isfile(joinpath(catalog.directory,name*".json"))
        theme_read_path(joinpath(catalog.directory,name*".json");mode=catalog.mode,bold=catalog.bold)
    elseif haskey(catalog.extras,name)
        ThemeLoadResult(;ok=true,theme=catalog.extras[name])
    else
        ThemeLoadResult(;reason="Theme not found: $name")
    end
end

"""Parse an automatic pair only when both sides are present and exactly one slash exists."""
theme_auto_setting(::Nothing) = nothing
function theme_auto_setting(setting::AbstractString)
    parts = split(setting,'/';keepempty=true)
    length(parts)==2 && all(part -> !isempty(strip(part)),parts) ? (light=String(strip(parts[1])),dark=String(strip(parts[2]))) : nothing
end
theme_resolve_setting(::Nothing,appearance) = nothing
function theme_resolve_setting(setting::AbstractString,appearance::Symbol)
    automatic = theme_auto_setting(setting)
    isnothing(automatic) ? (occursin('/',setting) ? nothing : String(setting)) : (appearance==:light ? automatic.light : automatic.dark)
end

"""Construct runtime state from an actual persisted setting, falling back visibly on invalid input."""
function ThemeRuntime(catalog::ThemeCatalog;setting::AbstractString="system",settings_path::AbstractString="")
    name = theme_resolve_setting(setting,catalog.appearance)
    loaded = isnothing(name) ? ThemeLoadResult(;reason="Invalid automatic theme setting: $setting") : theme_load(catalog,name)
    palette = loaded.theme
    active = isnothing(palette) ? theme_system_palette(catalog) : palette
    ThemeRuntime(;catalog,active,committed=String(setting),requested=String(setting),owner_name=isnothing(name) ? "system" : name,settings_path=String(settings_path),last_error=loaded.reason)
end

"""Map all theme tokens and existing Julia style aliases to the actual active palette."""
function theme_style(theme::NativeTheme,token::Symbol;bold::Bool=false)
    if token==:terminal_default
        Tachikoma.Style(;bold)
    else
        name = get(THEME_STYLE_ALIASES,token,String(token))
        value = get(theme.colors,name,Tachikoma.NoColor())
        color = theme.mode==:indexed ? theme_indexed(value) : value
        background = haskey(THEME_TOKEN_METADATA,name) && THEME_TOKEN_METADATA[name]["slot"]=="background"
        background ? Tachikoma.Style(;bg=color,bold) : Tachikoma.Style(;fg=color,bold,dim=name in theme.dim)
    end
end
theme_style(runtime::ThemeRuntime,token::Symbol;kwargs...) = theme_style(runtime.active,token;kwargs...)

"""Apply a real preview without touching persistent settings or the committed selection."""
function theme_preview!(runtime::ThemeRuntime,setting::AbstractString)
    name = theme_resolve_setting(setting,runtime.catalog.appearance)
    resolved = isnothing(name) ? runtime.owner_name : name
    result = theme_load(runtime.catalog,resolved)
    palette = result.theme
    runtime.active = isnothing(palette) ? theme_system_palette(runtime.catalog) : palette
    runtime.requested = String(setting)
    runtime.last_error = result.reason
    theme_sync_native!(runtime)
    (ok=result.ok,reason=result.reason,setting=String(setting),active=runtime.active.name)
end

"""Atomically persist only the theme preference while preserving unrelated terminal settings."""
function theme_store!(path::AbstractString,setting::AbstractString)
    result = (ok=false,reason="Theme settings path is empty or unsafe")
    directory = dirname(path)
    if !isempty(path) && !islink(path) && !islink(directory) && !isdir(path)
        data = isfile(path) ? JSON.isvalidjson(read(path,String)) ? JSON.parsefile(path) : nothing : Dict{String,Any}()
        if data isa AbstractDict
            data["theme"] = String(setting)
            mkpath(directory;mode=0o700)
            mktemp(directory) do temporary,io
                chmod(temporary,0o600)
                write(io,JSON.json(data))
                close(io)
                Base.Filesystem.rename(temporary,path)
            end
            result = (ok=true,reason="")
        else
            result = (ok=false,reason="Existing terminal settings are invalid JSON; not overwritten")
        end
    end
    result
end

"""Commit only after palette validation and real persistence succeed; retain failures unchanged."""
function theme_apply!(runtime::ThemeRuntime,setting::AbstractString;persist=theme_store!)
    name = theme_resolve_setting(setting,runtime.catalog.appearance)
    loaded = isnothing(name) ? ThemeLoadResult(;reason="Invalid automatic theme setting: $setting") : theme_load(runtime.catalog,name)
    result = (ok=false,reason=loaded.reason)
    if loaded.ok
        saved = persist(runtime.settings_path,String(setting))
        result = saved
        if saved.ok
            runtime.committed = String(setting)
            runtime.owner_name = something(name,"system")
            theme_preview!(runtime,setting)
        else
            runtime.last_error = saved.reason
        end
    else
        runtime.last_error = loaded.reason
    end
    result
end

theme_revert!(runtime::ThemeRuntime) = theme_preview!(runtime,runtime.committed)
theme_refresh!(runtime::ThemeRuntime) = theme_preview!(runtime,runtime.requested)

"""Re-resolve automatic/system themes when the terminal reports a genuine appearance change."""
function theme_terminal!(runtime::ThemeRuntime;background=missing,foreground=missing,palette=missing,pending=false,reported=nothing,colorfgbg="")
    catalog = runtime.catalog
    if !ismissing(background) && !isnothing(background)
        catalog.background = background
    end
    if !ismissing(foreground) && !isnothing(foreground)
        catalog.foreground = foreground
    end
    if !ismissing(palette) && !isempty(palette)
        catalog.palette = palette
    end
    catalog.pending = pending
    catalog.appearance = theme_detect_appearance(;background=catalog.background,foreground=catalog.foreground,reported,colorfgbg)
    theme_refresh!(runtime)
end

"""Style an exact Pi token without translating the existing Julia style aliases."""
function theme_token_style(theme::NativeTheme,token::AbstractString;bold=false,italic=false,underline=false,strike=false)
    value = get(theme.colors,token,Tachikoma.NoColor())
    color = theme.mode==:indexed ? theme_indexed(value) : value
    background = haskey(THEME_TOKEN_METADATA,token) && THEME_TOKEN_METADATA[token]["slot"]=="background"
    background ? Tachikoma.Style(;bg=color,bold,italic,underline,strikethrough=strike) :
        Tachikoma.Style(;fg=color,bold,italic,underline,strikethrough=strike,dim=token in theme.dim)
end
theme_token_style(runtime::ThemeRuntime,token::AbstractString;kwargs...) = theme_token_style(runtime.active,token;kwargs...)

const ACTIVE_NATIVE_THEME = Ref{Union{Nothing,ThemeRuntime}}(nothing)
"""Install the native palette used by the owner's existing style entrypoints."""
activate_theme_runtime!(runtime::ThemeRuntime) = (ACTIVE_NATIVE_THEME[]=runtime; theme_sync_native!(runtime); runtime)

"""Apply native extras and restore the captured framework theme when their preview ends."""
function theme_sync_native!(runtime::ThemeRuntime)
    extra = runtime.active.native_extra
    Tachikoma.set_theme!(isnothing(extra) ? runtime.native_baseline : extra)
end

"""Validate even unused variable values so invalid metadata cannot masquerade as a usable theme."""
theme_valid_value(value) = false
theme_valid_value(value::AbstractString) = true
theme_valid_value(value::Bool) = false
theme_valid_value(value::Real) = isfinite(value) && isinteger(value) && 0<=value<=255

"""Restore the saved theme from its actual settings file while keeping malformed data untouched."""
function theme_restore(catalog::ThemeCatalog,path::AbstractString;fallback::AbstractString="system")
    setting = String(fallback)
    error = ""
    if islink(path)
        error = "Theme settings symlink is not read"
    elseif isfile(path)
        text = read(path,String)
        data = JSON.isvalidjson(text) ? JSON.parse(text) : nothing
        if data isa AbstractDict && get(data,"theme",fallback) isa AbstractString
            setting = String(get(data,"theme",fallback))
        else
            error = "Invalid saved theme settings; existing file is unchanged"
        end
    end
    runtime = ThemeRuntime(catalog;setting,settings_path=path)
    if !isempty(error)
        runtime.last_error = error
    end
    runtime
end

"""Construct a typed system palette directly so failure fallback never depends on an optional result field."""
function theme_system_palette(catalog::ThemeCatalog)
    generated=theme_system_colors(;catalog.background,catalog.foreground,catalog.palette,catalog.pending,catalog.appearance)
    NativeTheme(;name="system",colors=generated.colors,dim=generated.dim,appearance=generated.appearance,mode=catalog.mode,bold=catalog.bold)
end
