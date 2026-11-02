"""Native command/menu metadata and actions, independent of the Pi oracle."""
menu_node(id, label; choices=nothing, children=nothing) = begin
    item = Dict{String,Any}("id" => String(id), "label" => String(label))
    isnothing(choices) || (item["choices"] = String.(choices))
    isnothing(children) || (item["children"] = children)
    item
end

menu_preference(app::App, name::AbstractString, fallback::AbstractString) =
    get(app.menus.preferences, String(name), String(fallback))

"""Build the current settings tree from the actual terminal state and capabilities."""
function menu_snapshot(app::App; images::Bool=app.menus.images, models=nothing,
        themes::AbstractVector{<:AbstractString}=["system", "dark", "light"])
    available_models = isnothing(models) ?
        [(provider=string(model.provider), id=model.id, reasoning=true)
            for model in provider_models(app.settings.registry)] : models
    choose(id, label, options) = menu_node(id, label; choices=options)
    flag(id, label) = choose(id, label, ["true", "false"])
    nodes = Dict{String,Any}[
        flag("autocompact", "Auto-compact"),
    ]
    if images
        append!(nodes, [flag("show-images", "Show images"),
            choose("image-width-cells", "Image width", ["60", "80", "120"])])
    end
    append!(nodes, [
        flag("auto-resize-images", "Auto-resize images"),
        flag("block-images", "Block images"),
        flag("skill-commands", "Skill commands"),
        flag("show-hardware-cursor", "Show hardware cursor"),
        choose("editor-padding", "Editor padding", ["0", "1", "2", "3"]),
        choose("output-padding", "Output padding", ["0", "1"]),
        choose("autocomplete-max-visible", "Autocomplete max items", ["3", "5", "7", "10", "15", "20"]),
        flag("clear-on-shrink", "Clear on shrink"),
        flag("terminal-progress", "Terminal progress"),
        choose("steering-mode", "Steering mode", ["one-at-a-time", "all"]),
        choose("follow-up-mode", "Follow-up mode", ["one-at-a-time", "all"]),
        choose("transport", "Transport", ["sse", "websocket", "websocket-cached", "auto"]),
        choose("share-destination", "Session share destination", ["auto", "gist", "radius"]),
        choose("http-idle-timeout", "HTTP idle timeout", ["30 sec", "1 min", "2 min", "5 min", "disabled"]),
        choose("cache-warming-mode", "Cache warming", ["off", "streaming", "idle"]),
        flag("hide-thinking", "Hide thinking"),
        choose("mermaid-rendering", "Mermaid diagrams", ["off", "final", "streaming"]),
        flag("cache-miss-notices", "Cache miss notices"),
        flag("collapse-changelog", "Collapse changelog"),
        choose("quiet-startup", "Quiet startup", ["true", "header", "false"]),
        flag("install-telemetry", "Install telemetry"),
        choose("default-project-trust", "Default project trust", ["Ask", "Always trust", "Never trust"]),
        choose("double-escape-action", "Double-escape action", ["tree", "fork", "none"]),
        choose("tree-filter-mode", "Tree filter mode", ["default", "no-tools", "user-only", "labeled-only", "all"]),
        menu_node("warnings", "Warnings"; children=[
            flag("anthropic-extra-usage", "Anthropic extra usage")]),
    ])
    thinking_levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    model_options = isempty(available_models) ? [menu_node("__none__", "No models available")] :
        [menu_node(string(model.provider, "/", model.id), string(model.id, " [", model.provider, "]"))
            for model in available_models]
    selected_model = isempty(available_models) ? nothing : first(available_models)
    levels = isnothing(selected_model) ? String[] :
        selected_model.reasoning ? thinking_levels : ["off"]
    push!(nodes, menu_node("model-thinking", "Default thinking level per model"; children=[
        Dict{String,Any}("id" => "model", "children" => model_options),
        Dict{String,Any}("id" => "level", "children" => [menu_node(level, level) for level in levels]),
    ]))
    append!(nodes, [
        choose("tui-mode", "TUI mode", ["regular", "fullscreen"]),
        choose("fullscreen-exit-output", "Fullscreen exit output", ["transcript", "resume-hint"]),
        choose("fullscreen-scrollbar", "Fullscreen scrollbar", ["auto", "always", "hidden"]),
        flag("fullscreen-copy-on-select", "Fullscreen copy on select"),
        choose("fullscreen-wheel-scroll-lines", "Fullscreen wheel scrolling", ["auto", "1", "2", "3", "5", "10"]),
    ])
    # Theme has a second level when automatic light/dark appearance is selected.
    current_theme = menu_preference(app, "theme", "dark")
    theme_items(selected) = Dict{String,Any}[menu_node(theme, (theme == selected ? "✓ " : "") * theme)
        for theme in themes]
    single_themes = Dict{String,Any}[menu_node(theme, (theme == current_theme ? "✓ " : "") * theme)
        for theme in themes]
    system = menu_identifier_index(single_themes, "system")
    if !isnothing(system)
        top = popat!(single_themes, system)
        pushfirst!(single_themes, top)
    end
    insert!(single_themes, isnothing(system) ? 1 : 2, menu_node("/", "automatic"))
    auto_items = [menu_node("light-theme", "Light theme"; children=theme_items("dark")),
        menu_node("dark-theme", "Dark theme"; children=theme_items("dark")),
        choose("apply", "Apply", ["save and go back"]),
        choose("single-mode", "Change mode", ["switch to single theme"])]
    push!(nodes, menu_node("theme", "Theme"; children=[
        Dict{String,Any}("id" => "single", "children" => single_themes),
        Dict{String,Any}("id" => "automatic", "children" => auto_items)]))
    return nodes
end

"""Find exactly one visible menu item by a series of stable identifiers."""
lookup_menu(nodes, path::AbstractVector{<:AbstractString}) = nothing

function lookup_menu(nodes::Vector{Dict{String,Any}}, path::AbstractVector{<:AbstractString})
    item = isempty(path) ? nothing : findfirst(node -> node["id"] == first(path), nodes)
    if isnothing(item)
        nothing
    else
        node = nodes[item]
        if length(path) == 1
            node
        elseif haskey(node, "choices") && length(path) == 2 && last(path) in node["choices"]
            menu_node(last(path), last(path))
        else
            haskey(node, "children") ? lookup_menu(node["children"], path[2:end]) : nothing
        end
    end
end

"""Resolve a declared settings path; runtime effect tests independently verify each action."""
function menu_action(app::App, path::AbstractVector{<:AbstractString}; models=nothing, themes::AbstractVector{<:AbstractString}=["system", "dark", "light"])
    if isempty(path) || first(path) != "settings"
        nothing
    else
        node = length(path) == 1 ? menu_node("settings", "Settings"; children=menu_snapshot(app; models, themes)) :
            lookup_menu(menu_snapshot(app; models, themes), path[2:end])
        isnothing(node) ? nothing : () -> activate_menu_path!(app, path)
    end
end

"""Route programmatic settings selection through the same effects as keyboard activation."""
function activate_menu_path!(app::App, path::AbstractVector{<:AbstractString})
    if length(path) >= 3
        name = String(path[2])
        value = String(last(path))
        if name == "theme"
            if length(path) >= 4 && path[3] == "single" && value != "/"
                set_setting_value!(app, "theme", value)
            elseif length(path) >= 5 && path[3] == "automatic"
                set_setting_value!(app, string("theme/", path[4]), value)
            end
        elseif name == "model-thinking"
            parts = split(String(path[end - 1]), "/"; limit=2)
            if length(parts) == 2
                persist_thinking_default!(app, parts[1], parts[2], value == "__clear__" ? nothing : value)
            end
        else
            set_setting_value!(app, name, value)
        end
    end
    nothing
end

"""Register a prompt template as a discoverable, replaceable command."""
function register_prompt!(app::App, name::AbstractString, description::AbstractString=""; content=nothing, path=nothing, argument_hint=nothing)
    loaded = isnothing(content) && !isnothing(path) ? prompt_load_template(path) : nothing
    body = isnothing(loaded) ? content : loaded.content
    summary = isempty(description) && !isnothing(loaded) ? loaded.description : String(description)
    hint = isnothing(argument_hint) && !isnothing(loaded) ? loaded.argument_hint : argument_hint
    item = RegisteredPrompt(String(name), summary, isnothing(body) ? nothing : String(body), isnothing(path) ? nothing : abspath(path), isnothing(hint) ? nothing : String(hint))
    index = findfirst(prompt -> prompt.name == item.name, app.menus.prompts)
    if isnothing(index)
        push!(app.menus.prompts, item)
    else
        app.menus.prompts[index] = item
    end
    resource_registered!(app, :prompt, item.name)
    return item
end

"""Register inert skill metadata; explicit invocation submits its current source to the model."""
function register_skill!(app::App, name::AbstractString, path::AbstractString; description="")
    item = RegisteredSkill(String(name), abspath(path), String(description))
    index = findfirst(skill -> skill.name == item.name, app.menus.skills)
    if isnothing(index)
        push!(app.menus.skills, item)
    else
        app.menus.skills[index] = item
    end
    resource_registered!(app, :skill, item.name)
    return item
end

function remove_skill!(app::App, name::AbstractString)
    filter!(item -> item.name != name, app.menus.skills)
    return app
end

set_skill_commands!(app::App, enabled::Bool) = (app.menus.skill_commands_enabled = enabled; app)

function prompt_command!(app::App,name::AbstractString,arguments::AbstractString="";delivery_kind=:steering)
    invoke_resource_command!(app,:prompt,name,arguments;delivery_kind)
end

function skill_command!(app::App,name::AbstractString,arguments::AbstractString="";delivery_kind=:steering)
    invoke_resource_command!(app,:skill,name,arguments;delivery_kind)
end

"""Compose built-ins, user prompts, extension commands, and enabled skills in Pi order."""
function discover_commands(app::App)
    builtin = CommandSpec[cmd for cmd in app.commands if cmd.visible && cmd.origin == :builtin]
    prompts = CommandSpec[CommandSpec(item.name, prompt_menu_description(item.description, item.argument_hint),
        (app, arguments) -> prompt_command!(app, item.name, arguments); origin=:prompt)
        for item in app.menus.prompts]
    extension = CommandSpec[cmd for cmd in app.commands if cmd.visible && cmd.origin != :builtin]
    contributed = component(app.session.kernel, :slash_commands)
    if contributed isa AbstractVector
        for candidate in contributed
            candidate isa CommandSpec && candidate.visible && push!(extension, candidate)
        end
    end
    names = Set(cmd.name for cmd in builtin)
    filter!(command -> !(command.name in names), extension)
    seen = Set{String}()
    filter!(command -> command.name in seen ? false : (push!(seen, command.name); true), extension)
    skills = app.menus.skill_commands_enabled ?
        CommandSpec[CommandSpec("skill:" * item.name, item.description,
            (app, arguments) -> skill_command!(app, item.name, arguments); origin=:skill)
            for item in app.menus.skills] : CommandSpec[]
    return [builtin; prompts; extension; skills]
end

"""A command page is a menu whose child list comes from live model/session state."""
function menu_page_items(app::App)
    isempty(app.menus.path) ? Dict{String,Any}[] : menu_page_items(app, Val(Symbol(first(app.menus.path))))
end

menu_page_items(app::App, ::Val) = Dict{String,Any}[]

function menu_page_items(app::App, ::Val{:settings})
    path = app.menus.path
    nodes = menu_snapshot(app)
    if length(path) == 1
        nodes
    else
        node = lookup_menu(nodes, path[2:end])
        if isnothing(node)
            Dict{String,Any}[]
        elseif haskey(node, "children")
            node["children"]
        elseif haskey(node, "choices")
            [menu_node(value, value) for value in node["choices"]]
        else
            Dict{String,Any}[]
        end
    end
end

menu_page_items(app::App, ::Val{:thinking}) = [menu_node(value, value) for value in
    ("off", "minimal", "low", "medium", "high", "xhigh", "max")]
menu_page_items(app::App, ::Union{Val{:model},Val{Symbol("scoped-models")}}) =
    [menu_node(string(model.provider, "/", model.id), string(model.id, " [", model.provider, "]"))
        for model in provider_models(app.settings.registry)]
function menu_page_items(app::App, ::Val{:resume})
    [menu_node(item.id, something(item.name, item.id) * " · " * string(item.messages) * " messages") for item in app.archive.sessions]
end

function menu_page_items(app::App, ::Union{Val{:tree},Val{:fork}})
    timeline = app.archive.timeline
    entries = isnothing(timeline) ? Dict{String,Any}[] : JuliaForever2.timeline_entries(timeline)
    fork = first(app.menus.path) == "fork"
    selected = filter(entry -> entry["type"] == "message" && (!fork || entry["message"]["role"] == "user"), entries)
    [menu_node(entry["id"], string(entry["message"]["role"], " · ", first(JSON.json(get(entry["message"], "content", get(entry["message"], "output", ""))), 64))) for entry in selected]
end
menu_page_items(app::App, ::Val{:login}) =
    [menu_node(string(provider.id), provider.label) for provider in app.settings.providers]

menu_page_items(app::App, ::Val{:logout}) =
    [menu_node(string(provider.id), provider.label) for provider in app.settings.providers
        if haskey(app.menus.logout_revisions, String(provider.id))]

"""Enter a native menu page; the active path drives breadcrumbs and nested actions."""
function open_menu!(app::App, name::AbstractString;refresh=true,query="",login_reference="",auth_login=auth_menu_start_login!)
    previous=app.menus.auth_menu_control
    if previous isa AuthMenuControl && previous.stage==:auth
        auth_menu_cancel_auth!(app,previous)
    end
    auth_menu_dispose!(previous)
    app.menus.auth_menu_control=nothing
    close_session_selectors!(app)
    app.menus.chat_press=nothing
    app.menus.generation += UInt(1)
    app.menu = false
    app.page = :pi_menu
    app.menus.path = [String(name)]
    app.menus.cursor = 1
    Tachikoma.clear!(app.menus.search)
    empty!(app.menus.parents)
    open_model_controls!(app, name;refresh,query)
    name in ("login","logout") && (app.menus.auth_menu_control=auth_menu_open!(app,name;on_login=auth_login))
    if name=="login" && !isempty(login_reference)
        auth_menu_reference!(app,app.menus.auth_menu_control,login_reference)
    end
    name == "theme" && open_theme_control!(app; standalone=true)
    name == "tree" && open_tree_control!(app)
    name in ("resume", "fork") && open_session_selector!(app, name)
    name == "settings" && (app.menus.settings_cursor_style = pi_style(:accent))
    return nothing
end

function menu_select!(app::App, selected::AbstractString)
    path = [app.menus.path; String(selected)]
    nodes = menu_page_items(app)
    node = findfirst(item -> item["id"] == selected, nodes)
    if !isnothing(node)
    entry = nodes[node]
    if haskey(entry, "children") || haskey(entry, "choices")
        app.menus.path = path
        app.menus.cursor = 1
    elseif first(path) == "settings"
        activate_menu_path!(app, path)
        app.menus.path = ["settings"]
        app.menus.cursor = 1
    elseif first(path) == "thinking"
        current = current_menu_model(app)
        if isnothing(current)
            app.status = "Select a model before changing thinking."
        else
            configuration_action!(app, current; thinking=String(selected))
        end
    elseif first(path) == "model"
        configuration_action!(app, selected)
    elseif first(path) == "scoped-models"
        menu = app.menus.scoped_menu
        if !isnothing(menu)
            index = findfirst(model -> selector_key(model) == selected, menu.models)
            if !isnothing(index)
                scoped_models_change!(menu, scoped_models_enabled(menu, selected) ? :clear : :enable, [String(selected)])
                app.menus.enabled_models = deepcopy(menu.enabled)
            end
        end
    elseif first(path) in ("resume", "fork", "tree")
        session_action!(app, Symbol(first(path)), selected)
    elseif first(path) == "logout"
        start_logout!(app, selected)
    elseif first(path) == "login"
        index = findfirst(provider -> String(provider.id) == selected, app.settings.providers)
        if !isnothing(index)
            app.selected = index
            descriptor = app.settings.providers[index]
            if !isnothing(descriptor.auth)
                start_sign_in!(app, descriptor.id; action=descriptor.auth)
            else
                select_provider!(app)
            end
        end
    else
        app.status = join(path, " / ")::String
        app.page = :chat
    end
    end
    return nothing
end

function page_input!(app::App, ::Val{:pi_menu}, event::KeyEvent, raw::AbstractVector{UInt8}=UInt8[])
    items = menu_page_items(app)
    control=app.menus.auth_menu_control
    if control isa AuthMenuControl && auth_menu_active(app,control)
        auth_menu_input!(app,control,event,raw)
    elseif selector_active(app)
        session_selector_input!(app, event, raw)
    elseif app.menus.path == ["tree"]
        tree_controls_input!(app, event, raw)
    elseif thinking_defaults_active(app)
        thinking_defaults_controls_input!(app, event, raw)
    elseif theme_controls_active(app)
        theme_controls_input!(app, event, raw)
    elseif app.menus.path in (["model"], ["scoped-models"], ["thinking"])
        model_controls_input!(app, event, raw)
    elseif app.menus.path in (["settings"], ["settings", "warnings"])
        settings_input!(app, event, raw)
    elseif event.key == :escape
        if length(app.menus.path) > 1
            pop!(app.menus.path)
            app.menus.cursor = 1
        else
            app.page = :chat
        end
    elseif event.key in (:up, :down) && !isempty(items)
        app.menus.cursor = mod1(app.menus.cursor + (event.key == :up ? -1 : 1), length(items))
    elseif event.key == :enter && !isempty(items)
        menu_select!(app, items[clamp(app.menus.cursor, 1, length(items))]["id"])
    end
    return nothing
end

function page_view!(app::App, ::Val{:pi_menu}, frame::Frame)
    startup_host_view!(app,frame)
    nothing
end

function page_mouse!(app::App, ::Val{:pi_menu}, event::MouseEvent)
    if selector_active(app)
        session_selector_mouse!(app, event)
    elseif app.menus.path == ["tree"]
        nothing
    elseif thinking_defaults_active(app)
        nothing
    elseif theme_controls_active(app)
        theme_controls_mouse!(app, event)
    elseif app.menus.path in (["model"], ["scoped-models"], ["thinking"])
        model_controls_mouse!(app, event)
    elseif app.menus.path in (["settings"], ["settings", "warnings"])
        settings_mouse!(app, event)
    elseif event.button == Tachikoma.mouse_left && event.action == Tachikoma.mouse_press
        items = menu_page_items(app)
        count = min(length(items), max(0, app.area.height - 7))
        first_item = max(1, min(app.menus.cursor - count + 1, length(items) - count + 1))
        geometry=startup_editor_geometry(app)
        local_row=startup_editor_row(app,event,geometry)
        index=first_item+local_row-2
        if local_row>=2 && first_item <= index < first_item + count
            app.menus.cursor = index
            menu_select!(app, items[index]["id"])
        end
    end
    return nothing
end

"""Read skill/prompt metadata from Pi-compatible project and user directories."""
function resource_metadata(path::AbstractString, key::AbstractString, default::AbstractString="")
    lines = readlines(path)
    index = findfirst(line -> startswith(strip(line), key * ":"), lines)
    isnothing(index) ? String(default) : strip(split(lines[index], ":"; limit=2)[2], [' ', '\t', '"', '\''])
end

function discover_disk_resources!(app::App; directory::AbstractString=app.settings.workspace,
        agent_dir::AbstractString=joinpath(homedir(), ".pi", "agent"))
    empty!(app.menus.resource_warnings)
    for skill_dir in (joinpath(agent_dir, "skills"), joinpath(directory, ".pi", "skills"))
        if isdir(skill_dir)
            for (root, child_dirs, filenames) in walkdir(skill_dir; follow_symlinks=false)
                if "SKILL.md" in filenames
                    skill_file = joinpath(root, "SKILL.md")
                    name = resource_metadata(skill_file, "name", basename(root))
                    description = resource_metadata(skill_file, "description")
                    register_skill!(app, name, skill_file; description)
                    empty!(child_dirs)
                elseif root == skill_dir
                    for file in filter(name -> endswith(name, ".md"), filenames)
                        path = joinpath(root, file)
                        name = resource_metadata(path, "name", splitext(file)[1])
                        register_skill!(app, name, path; description=resource_metadata(path, "description"))
                    end
                end
            end
        end
    end
    for prompt_dir in (joinpath(agent_dir, "prompts"), joinpath(directory, ".pi", "prompts"))
        if isdir(prompt_dir)
            for filename in filter(name -> endswith(name, ".md"), readdir(prompt_dir))
                path = joinpath(prompt_dir, filename)
                if isfile(path)
                    outcome = prompt_load_result(path)
                    if outcome.ok
                        template = outcome.value
                        register_prompt!(app, template.name, template.description; content=template.content, path=template.file_path, argument_hint=template.argument_hint)
                    else
                        push!(app.menus.resource_warnings, outcome.reason)
                    end
                end
            end
        end
    end
    return app
end

"""Find an item in an explicitly typed menu without generic bit-array predicate inference."""
function menu_identifier_index(items::Vector{Dict{String,Any}}, id::AbstractString)
    result = nothing
    for index in eachindex(items)
        if items[index]["id"] == id && isnothing(result)
            result = index
        end
    end
    result
end
