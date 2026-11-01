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
        themes=["system", "dark", "light"])
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
        choose("http-idle-timeout", "HTTP idle timeout", ["30s", "5m", "Off"]),
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
        menu_node("model", "Model"; children=model_options),
        menu_node("level", "Level"; children=[menu_node(level, level) for level in levels]),
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
    theme_items(selected) = [menu_node(theme, (theme == selected ? "✓ " : "") * theme)
        for theme in themes]
    single_themes = [menu_node(theme, (theme == current_theme ? "✓ " : "") * theme)
        for theme in themes]
    system = findfirst(item -> item["id"] == "system", single_themes)
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
        menu_node("single", "Single"; children=single_themes),
        menu_node("automatic", "Automatic"; children=auto_items)]))
    return nodes
end

"""Find exactly one visible menu item by a series of stable identifiers."""
function lookup_menu(nodes, path::AbstractVector{<:AbstractString})
    isempty(path) && return nothing
    item = findfirst(node -> node["id"] == first(path), nodes)
    isnothing(item) && return nothing
    node = nodes[item]
    length(path) == 1 && return node
    if haskey(node, "choices") && length(path) == 2 && last(path) in node["choices"]
        return menu_node(last(path), last(path))
    end
    return haskey(node, "children") ? lookup_menu(node["children"], path[2:end]) : nothing
end

"""Every selectable leaf resolves to a real Julia callback, not an inert menu label."""
function menu_action(app::App, path::AbstractVector{<:AbstractString};
        models=nothing,
        themes=["system", "dark", "light"])
    isempty(path) && return nothing
    first(path) == "settings" || return nothing
    node = length(path) == 1 ? menu_node("settings", "Settings"; children=menu_snapshot(app; models, themes)) :
        lookup_menu(menu_snapshot(app; models, themes), path[2:end])
    isnothing(node) && return nothing
    return () -> activate_menu_path!(app, path)
end

"""Apply a chosen setting through the same API used by keyboard and mouse navigation."""
function activate_menu_path!(app::App, path::AbstractVector{<:AbstractString})
    length(path) < 3 && return nothing
    name = String(path[2])
    value = String(last(path))
    if name == "skill-commands" && value in ("true", "false")
        set_skill_commands!(app, value == "true")
    elseif name == "theme"
        if length(path) >= 4 && path[3] == "single" && value != "/"
            app.menus.preferences["theme"] = value
        elseif length(path) >= 5 && path[3] == "automatic"
            app.menus.preferences[string("theme/", path[4])] = value
        end
    elseif name == "model-thinking"
        app.menus.preferences[string("model-thinking/", path[end - 1])] = value
    end
    if name != "theme"
        app.menus.preferences[name] = value
    end
    app.status = string(name, ": ", value)
    return nothing
end

"""Register a prompt template as a discoverable, replaceable command."""
function register_prompt!(app::App, name::AbstractString, description::AbstractString="")
    item = RegisteredPrompt(String(name), String(description))
    index = findfirst(prompt -> prompt.name == item.name, app.menus.prompts)
    if isnothing(index)
        push!(app.menus.prompts, item)
    else
        app.menus.prompts[index] = item
    end
    return item
end

"""Register a skill whose invocation inserts the current SKILL.md into the editor."""
function register_skill!(app::App, name::AbstractString, path::AbstractString; description="")
    item = RegisteredSkill(String(name), String(path), String(description))
    index = findfirst(skill -> skill.name == item.name, app.menus.skills)
    if isnothing(index)
        push!(app.menus.skills, item)
    else
        app.menus.skills[index] = item
    end
    return item
end

function remove_skill!(app::App, name::AbstractString)
    filter!(item -> item.name != name, app.menus.skills)
    return app
end

set_skill_commands!(app::App, enabled::Bool) = (app.menus.skill_commands_enabled = enabled; app)

function prompt_command!(app::App, name)
    Tachikoma.set_text!(app.input, "/" * String(name) * " ")
    app.status = "Prompt template ready"
    return nothing
end

function skill_command!(app::App, name)
    index = findfirst(skill -> skill.name == name, app.menus.skills)
    if !isnothing(index)
        skill = app.menus.skills[index]
        if isfile(skill.path)
            Tachikoma.set_text!(app.input, read(skill.path, String))
            app.status = "Skill loaded: " * skill.name
        else
            app.status = "Skill file unavailable: " * skill.path
        end
    end
    nothing
end

"""Compose built-ins, user prompts, extension commands, and enabled skills in Pi order."""
function discover_commands(app::App)
    builtin = CommandSpec[cmd for cmd in app.commands if cmd.visible && cmd.origin == :builtin]
    prompts = CommandSpec[CommandSpec(item.name, item.description,
        (app, arguments) -> prompt_command!(app, item.name); origin=:prompt)
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
            (app, arguments) -> skill_command!(app, item.name); origin=:skill)
            for item in app.menus.skills] : CommandSpec[]
    return [builtin; prompts; extension; skills]
end

"""A command page is a menu whose child list comes from live model/session state."""
function menu_page_items(app::App)
    path = app.menus.path
    isempty(path) && return Dict{String,Any}[]
    root = first(path)
    if root == "settings"
        nodes = menu_snapshot(app)
        length(path) == 1 && return nodes
        node = lookup_menu(nodes, path[2:end])
        if isnothing(node)
            return Dict{String,Any}[]
        elseif haskey(node, "children")
            return node["children"]
        elseif haskey(node, "choices")
            return [menu_node(value, value) for value in node["choices"]]
        end
        return Dict{String,Any}[]
    elseif root == "thinking"
        return [menu_node(value, value) for value in
            ("off", "minimal", "low", "medium", "high", "xhigh", "max")]
    elseif root == "model" || root == "scoped-models"
        models = provider_models(app.settings.registry)
        return [menu_node(string(model.provider, "/", model.id),
            string(model.id, " [", model.provider, "]"))
            for model in models]
    elseif root == "tree" || root == "fork"
        messages = history_snapshot(app.session).messages
        return [menu_node(string(index), string(index, " · ", message.role, " · ",
            first(message.content, min(length(message.content), 48))))
            for (index, message) in enumerate(messages)]
    elseif root == "login" || root == "logout"
        return [menu_node(string(provider.id), provider.label)
            for provider in app.settings.providers]
    elseif root == "resume"
        return Dict{String,Any}[]
    end
    return Dict{String,Any}[]
end

"""Enter a native menu page; the active path drives breadcrumbs and nested actions."""
function open_menu!(app::App, name::AbstractString)
    app.menu = false
    app.page = :pi_menu
    app.menus.path = [String(name)]
    app.menus.cursor = 1
    return nothing
end

function menu_select!(app::App, selected::AbstractString)
    path = [app.menus.path; String(selected)]
    nodes = menu_page_items(app)
    node = findfirst(item -> item["id"] == selected, nodes)
    isnothing(node) && return nothing
    entry = nodes[node]
    if haskey(entry, "children") || haskey(entry, "choices")
        app.menus.path = path
        app.menus.cursor = 1
    elseif first(path) == "settings"
        activate_menu_path!(app, path)
        app.menus.path = ["settings"]
        app.menus.cursor = 1
    elseif first(path) == "thinking"
        app.menus.preferences["thinking"] = String(selected)
        app.status = "Thinking: " * String(selected)
        app.page = :chat
    elseif first(path) == "model"
        parts = split(selected, "/"; limit=2)
        if length(parts) == 2
            result = select_provider_model!(app.session.kernel, Symbol(parts[1]), parts[2];
                dir=app.settings.directory, registry=app.settings.registry)
            app.status = result.ok ? "Model selected: " * selected : result.reason
            result.ok && (app.page = :chat)
        end
    elseif first(path) == "scoped-models"
        if selected in app.menus.scoped_models
            delete!(app.menus.scoped_models, String(selected))
        else
            push!(app.menus.scoped_models, String(selected))
        end
        app.status = "Scoped models: " * string(length(app.menus.scoped_models))
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
        app.status = join(path, " / ")
        app.page = :chat
    end
    return nothing
end

function page_input!(app::App, ::Val{:pi_menu}, event::KeyEvent)
    items = menu_page_items(app)
    if event.key == :escape
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
    area, buffer = frame.area, frame.buffer
    x, y, width, height = area.x, area.y, area.width, area.height
    drawline!(buffer, x + 1, y, width - 2, "◆ JULIA FOREVER", :accent)
    drawline!(buffer, x + 1, y + 2, width - 2, join(app.menus.path, " / "), :accent)
    items = menu_page_items(app)
    count = min(length(items), max(0, height - 7))
    first_item = max(1, min(app.menus.cursor - count + 1, length(items) - count + 1))
    for offset in 0:(count - 1)
        index = first_item + offset
        item = items[index]
        chosen = index == app.menus.cursor
        suffix = haskey(item, "choices") || haskey(item, "children") ? "  ›" : ""
        drawline!(buffer, x + 1, y + 3 + offset, width - 2,
            (chosen ? "→ " : "  ") * item["label"] * suffix,
            chosen ? :accent : :text)
    end
    drawline!(buffer, x + 1, y + height - 2, width - 2, "↑↓ select · Enter open · Esc back", :text_dim)
    draw_footer!(buffer, x, y + height - 1, width, app)
    return nothing
end

function page_mouse!(app::App, ::Val{:pi_menu}, event::MouseEvent)
    items = menu_page_items(app)
    count = min(length(items), max(0, app.area.height - 7))
    first_item = max(1, min(app.menus.cursor - count + 1, length(items) - count + 1))
    index = first_item + event.y - (app.area.y + 3)
    if first_item <= index < first_item + count
        app.menus.cursor = index
        menu_select!(app, items[index]["id"])
    end
    return nothing
end

"""Read skill/prompt metadata from Pi-compatible project and user directories."""
function resource_metadata(path::AbstractString, key::AbstractString, default::AbstractString="")
    for line in eachline(path)
        startswith(line, "---") && continue
        if startswith(strip(line), key * ":")
            return strip(split(line, ":"; limit=2)[2], [' ', '\t', '"', '\''])
        end
    end
    return String(default)
end

function discover_disk_resources!(app::App; directory::AbstractString=working_directory(app.session),
        agent_dir::AbstractString=joinpath(homedir(), ".pi", "agent"))
    for skill_dir in (joinpath(agent_dir, "skills"), joinpath(directory, ".pi", "skills"))
        isdir(skill_dir) || continue
        for (root, child_dirs, filenames) in walkdir(skill_dir; follow_symlinks=false)
            if "SKILL.md" in filenames
                skill_file = joinpath(root, "SKILL.md")
                name = resource_metadata(skill_file, "name", basename(root))
                description = resource_metadata(skill_file, "description")
                register_skill!(app, name, skill_file; description)
                empty!(child_dirs)
            elseif root == skill_dir
                for file in filenames
                    endswith(file, ".md") || continue
                    path = joinpath(root, file)
                    name = resource_metadata(path, "name", splitext(file)[1])
                    register_skill!(app, name, path; description=resource_metadata(path, "description"))
                end
            end
        end
    end
    for prompt_dir in (joinpath(agent_dir, "prompts"), joinpath(directory, ".pi", "prompts"))
        isdir(prompt_dir) || continue
        for filename in readdir(prompt_dir)
            endswith(filename, ".md") || continue
            path = joinpath(prompt_dir, filename)
            isfile(path) || continue
            register_prompt!(app, splitext(filename)[1], resource_metadata(path, "description"))
        end
    end
    return app
end
