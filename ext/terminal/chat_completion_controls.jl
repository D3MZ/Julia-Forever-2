"""Build completions from the live registered command catalog and the actual session workspace."""
function chat_completion_provider(app::App)
    current=() -> begin
        prompts=app.menus.prompts
        [begin
            index=findfirst(prompt->prompt.name==command.name,prompts)
            prompt=isnothing(index) ? nothing : prompts[index]
            hint=!isnothing(prompt) && hasproperty(prompt,:argument_hint) ? getproperty(prompt,:argument_hint) : nothing
            ChatCompletionCommand(;name=command.name,description=command.description,argument_hint=hint,arguments=command.argument_completions)
        end for command in discover_commands(app)]
    end
    ChatCompletionProvider(;commands=current,directory=app.settings.workspace)
end
