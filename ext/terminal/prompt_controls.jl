import JuliaForever2: PromptTemplateData,
    PROMPT_RESOURCE_LIMIT,
    PROMPT_PATH_LIMIT,
    prompt_menu_description,
    prompt_space,
    prompt_strip,
    prompt_parse_args,
    prompt_index,
    prompt_position,
    prompt_replacement,
    prompt_substitute_args,
    prompt_command_parts,
    prompt_expand_template,
    prompt_frontmatter_parts,
    prompt_validate_node,
    prompt_validate_children,
    prompt_metadata_string,
    prompt_validate_yaml_events,
    prompt_yaml_metadata,
    prompt_parse_frontmatter,
    prompt_description,
    prompt_template_from_text,
    prompt_read_file,
    prompt_load_template,
    skill_expand_command,
    prompt_expansion_result,
    prompt_load_result

function prompt_registered_template(item)
    content=hasproperty(item,:content) ? getproperty(item,:content) : nothing
    if isnothing(content)
        error("Prompt template content unavailable: /"*item.name)
    end
    PromptTemplateData(name=item.name,description=item.description,content=String(content),
        argument_hint=hasproperty(item,:argument_hint) ? item.argument_hint : nothing,
        file_path=hasproperty(item,:path) ? item.path : nothing)
end
function expand_registered_resources(app,text::AbstractString)::NamedTuple{(:ok,:reason,:text),Tuple{Bool,String,String}}
    prompt_expansion_result(text) do
        expanded=skill_expand_command(text,app.menus.skills)
        command=prompt_command_parts(expanded)
        index=isnothing(command) ? nothing : findfirst(item->item.name==command.name,app.menus.prompts)
        if isnothing(index)
            expanded
        else
            prompt=prompt_registered_template(app.menus.prompts[index])
            prompt_substitute_args(prompt.content,prompt_parse_args(command.arguments))
        end
    end
end
function invoke_resource_command!(app::App,kind::Symbol,name::AbstractString,args::AbstractString;delivery_kind::Symbol=:steering)
    kind in (:prompt,:skill) || error("Unknown resource command kind")
    original=string(kind==:skill ? "/skill:" : "/",name,isempty(args) ? "" : " "*args)
    registered=kind==:skill ? any(item->item.name==name,app.menus.skills) : any(item->item.name==name,app.menus.prompts)
    result::NamedTuple{(:ok,:reason,:text),Tuple{Bool,String,String}}=registered ? expand_registered_resources(app,original) : (ok=false,reason="Resource is no longer registered: "*String(name),text=original)
    if result.ok
        accepted=submit_literal_input!(app,result.text;kind=delivery_kind)
        if !accepted.ok
            app.status=accepted.reason
            Tachikoma.set_text!(app.input,original)
        end
        accepted
    else
        app.status=result.reason
        Tachikoma.set_text!(app.input,original)
        (ok=false,reason=result.reason)
    end
end
