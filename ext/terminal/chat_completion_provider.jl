"""One actual command or filesystem completion, with no executable UI placeholder."""
Base.@kwdef struct ChatCompletionItem
    value::String
    label::String=value
    description::Union{Nothing,String}=nothing
end
Base.@kwdef struct ChatCompletionResult
    prefix::String
    items::Vector{ChatCompletionItem}
end
Base.@kwdef struct ChatCompletionCommand
    name::String
    description::String=""
    argument_hint::Union{Nothing,String}=nothing
    arguments::Union{Nothing,Function}=nothing
end
Base.@kwdef struct ChatCompletionProvider
    commands::Function
    directory::String
    home::String=homedir()
    finder::Union{Nothing,String}=chat_completion_find_fd()
end
chat_completion_context(editor::ChatEditorState)=(text=chat_text(editor),cursor=editor.input.cursor)
function chat_completion_before(snapshot)
    before=chat_prefix(snapshot.text,snapshot.cursor)
    String(last(split(before,'\n';keepempty=true)))
end
chat_completion_separator(char::Char)=isspace(char) || char in ('，','。','；','：','！','？','、','（','）','【','】','《','》')
const CHAT_PATH_WRAPPERS=Dict('('=>')','['=>']','{'=>'}','<'=>'>','`'=>'`')
function chat_completion_token(text::AbstractString)
    chars=collect(text);start=1
    for (index,char) in enumerate(chars)
        (char in (' ','\t','"','\'','=') || chat_completion_separator(char)) && (start=index+1)
    end
    token=join(chars[start:end]);stripping=true
    while stripping && !isempty(token)
        closer=get(CHAT_PATH_WRAPPERS,first(token),nothing)
        stripping=!isnothing(closer) && !occursin(string(closer),chat_suffix(token,1))
        stripping && (token=chat_suffix(token,1))
    end
    token
end
function chat_completion_quoted(text::AbstractString)
    chars=collect(text);opened=0
    for (index,char) in enumerate(chars)
        char=='"' && (opened=opened==0 ? index : 0)
    end
    if opened==0
        nothing
    else
        start=opened>1 && chars[opened-1]=='@' ? opened-1 : opened
        preceding=start-1
        while preceding>0 && haskey(CHAT_PATH_WRAPPERS,chars[preceding])
            preceding-=1
        end
        valid=preceding==0 || chars[preceding] in (' ','\t','"','\'','=') || chat_completion_separator(chars[preceding])
        valid ? join(chars[start:end]) : nothing
    end
end
function chat_completion_prefix(text::AbstractString;force=false,attachment=false)
    quoted=chat_completion_quoted(text)
    token=chat_completion_token(text)
    if !isnothing(quoted) && (!attachment || startswith(quoted,"@\""))
        quoted
    elseif attachment
        startswith(token,"@") ? token : nothing
    elseif force || occursin('/',token) || startswith(token,'.') || startswith(token,"~/") || isempty(token) && !isempty(text) && chat_completion_separator(last(text))
        token
    else
        nothing
    end
end
chat_completion_path_parts(prefix::AbstractString)=chat_completion_path_parts(String(prefix))
function chat_completion_path_parts(prefix::String)
    at=startswith(prefix,"@");rest=at ? chat_suffix(prefix,1) : String(prefix)
    quoted=startswith(rest,'"');raw=String(quoted ? chat_suffix(rest,1) : rest)
    (raw,at,quoted)
end
chat_completion_value(path::AbstractString,at::Bool,quoted::Bool)=chat_completion_value(String(path),at,quoted)
function chat_completion_value(path::String,at::Bool,quoted::Bool)
    quote_path=quoted || any(chat_completion_separator,path)
    (at ? "@" : "")*(quote_path ? "\""*path*"\"" : path)
end
function chat_completion_file_items(provider::ChatCompletionProvider,prefix::AbstractString)
    raw,at,quoted=chat_completion_path_parts(prefix)
    expanded=raw=="~" ? provider.home : startswith(raw,"~/") ? joinpath(provider.home,chat_suffix(raw,2)) : raw
    root=isempty(raw) || raw in ("./","../","~","~/","/") || endswith(raw,'/')
    directory=root ? expanded : dirname(expanded)
    directory=isabspath(directory) ? directory : joinpath(provider.directory,directory)
    filter_prefix=root ? "" : basename(expanded)
    items=ChatCompletionItem[]
    if isdir(directory)
        for name in readdir(directory)
            if startswith(lowercase(name),lowercase(filter_prefix))
                is_directory=isdir(joinpath(directory,name))
                path=if endswith(raw,'/')
                    raw*name
                elseif occursin('/',raw) || occursin('\\',raw)
                    relative=joinpath(dirname(raw),name)
                    startswith(raw,"./") && !startswith(relative,"./") ? "./"*relative : relative
                elseif startswith(raw,'~')
                    "~/"*name
                else
                    name
                end
                display=String(replace(String(path),'\\'=>'/'))*(is_directory ? "/" : "")
                push!(items,ChatCompletionItem(;value=chat_completion_value(display,at,quoted),label=name*(is_directory ? "/" : "")))
            end
        end
        sort!(items;by=item->(!endswith(item.label,'/'),lowercase(item.label),item.label))
    end
    items
end
function chat_completion_command_items(commands::Vector{ChatCompletionCommand},prefix::AbstractString)
    bare=selector_filter(commands,prefix,command->startswith(command.name,"skill:") ? chat_suffix(command.name,6) : command.name)
    included=Set(command.name for command in bare)
    others=selector_filter(filter(command->startswith(command.name,"skill:") && !(command.name in included),commands),prefix,command->command.name)
    [ChatCompletionItem(;value=command.name,label=command.name,description=isempty(command.description) ? command.argument_hint : isnothing(command.argument_hint) ? command.description : command.argument_hint*" — "*command.description) for command in vcat(bare,others)]
end
"""Resolve current commands and actual local directory entries without mutating files or invoking a model."""
function chat_completion_suggest(provider::ChatCompletionProvider,snapshot,force::Bool,cancelled)
    text=chat_completion_before(snapshot);command=lstrip(text)
    attachment=chat_completion_prefix(text;attachment=true)
    result=nothing
    if !cancelled[]
        if !isnothing(attachment)
            result=chat_completion_attachment(provider,attachment,cancelled)
        elseif !force && startswith(command,'/')
            commands=provider.commands()::Vector{ChatCompletionCommand}
            separator=findfirst(==(' '),command)
            if isnothing(separator)
                items=chat_completion_command_items(commands,chat_suffix(command,1))
                isempty(items) || (result=ChatCompletionResult(;prefix=command,items))
            else
                name=String(SubString(command,nextind(command,firstindex(command)),prevind(command,separator)))
                index=findfirst(item->item.name==name,commands)
                arguments=String(SubString(command,nextind(command,separator)))
                callback=isnothing(index) ? nothing : commands[index].arguments
                if !isnothing(callback)
                    items=chat_completion_argument_items(Base.invokelatest(callback,arguments))
                    if items isa Vector{ChatCompletionItem} && !isempty(items)
                        result=ChatCompletionResult(;prefix=arguments,items)
                    end
                end
            end
        else
            prefix=chat_completion_prefix(text;force)
            if !isnothing(prefix)
                items=chat_completion_file_items(provider,prefix)
                isempty(items) || (result=ChatCompletionResult(;prefix,items))
            end
        end
    end
    result
end
"""Replace only the selected prefix and return an owned text/cursor result for atomic editor installation."""
function chat_completion_apply(provider,snapshot,item::ChatCompletionItem,prefix::AbstractString)
    before=chat_prefix(snapshot.text,snapshot.cursor);line=chat_completion_before(snapshot)
    initial=chat_prefix(line,length(line)-length(prefix));after=chat_suffix(snapshot.text,snapshot.cursor)
    quoted=startswith(prefix,'"') || startswith(prefix,"@\"")
    adjusted=quoted && endswith(item.value,'"') && startswith(after,'"') ? chat_suffix(after,1) : after
    slash=startswith(prefix,'/') && isempty(strip(initial)) && !occursin('/',chat_suffix(prefix,1))
    directory=endswith(item.label,'/')
    insertion=slash ? "/"*item.value*" " : item.value*(startswith(prefix,'@') && !directory ? " " : "")
    base=chat_prefix(before,length(before)-length(prefix))
    cursor=length(base)+length(insertion)-(directory && endswith(item.value,'"') && !slash ? 1 : 0)
    (text=base*insertion*adjusted,cursor)
end
function chat_completion_should_force(provider,snapshot)
    before=strip(chat_completion_before(snapshot))
    !(startswith(before,'/') && !occursin(' ',before))
end
"""Locate only an installed standard file finder; never delegate to a reference harness."""
chat_completion_find_fd() = JuliaForever2.FileSearchTools.find_fd()
function chat_completion_fd_pattern(query::String)
    normalized=replace(query,'\\'=>'/')
    escaped(value)=replace(value,r"[.*+?^$(){}|\[\]\\]"=>text->"\\"*text)
    if occursin('/',normalized)
        components=split(strip(normalized,'/'),'/';keepempty=false)
        isempty(components) ? normalized : join(escaped.(components),"[\\\\/]")*(endswith(normalized,'/') ? "[\\\\/]" : "")
    else
        escaped(normalized)
    end
end
"""Run one owned, cancellable fd lookup with bounded results and argv-only parameters."""
function chat_completion_fd_entries(finder::Union{Nothing,String},directory::String,query::String,cancelled;depth=nothing)
    isnothing(finder) && error("Attachment completion requires an installed fd or fdfind executable")
    args=String[finder,"--print0","--strip-cwd-prefix","--base-directory",directory,"--max-results","100","--type","f","--type","d","--follow","--hidden","--exclude",".git","--exclude",".git/*","--exclude",".git/**"]
    isnothing(depth) || append!(args,["--max-depth",string(depth)])
    occursin('/',replace(query,'\\'=>'/')) && push!(args,"--full-path")
    isempty(query) || append!(args,["--",chat_completion_fd_pattern(query)])
    records=NamedTuple{(:path,:directory),Tuple{String,Bool}}[]
    if !cancelled[]
        output=IOBuffer();errors=IOBuffer();process=run(pipeline(Cmd(args);stdout=output,stderr=errors);wait=false)::Base.Process
        while process_running(process) && !cancelled[]
            sleep(0.002)
        end
        cancelled[] && process_running(process) && kill(process,Base.SIGKILL)
        wait(process)
        if !cancelled[]
            success(process) || error("Attachment file finder failed: "*strip(String(take!(errors))))
            for line in split(String(take!(output)),'\0';keepempty=false)
                path=replace(String(line),'\\'=>'/');normalized=rstrip(path,'/')
                if !(normalized==".git" || startswith(normalized,".git/") || occursin("/.git/",normalized))
                    push!(records,(;path,directory=endswith(path,'/')))
                end
            end
        end
    end
    records
end
function chat_completion_attachment_score(path::String,query::String,directory::Bool)
    name=lowercase(basename(rstrip(path,'/')));needle=lowercase(query)
    score=name==needle ? 100 : startswith(name,needle) ? 80 : occursin(needle,name) ? 50 : occursin(needle,lowercase(path)) ? 30 : 0
    score>0 && directory ? score+10 : score
end
function chat_completion_attachment(provider::ChatCompletionProvider,prefix::AbstractString,cancelled)
    query,at,quoted=chat_completion_path_parts(prefix);slash=findlast(==('/'),query)
    display="";directory=provider.directory;filter_query=query
    if !isnothing(slash)
        base=String(SubString(query,1,slash))
        expanded=startswith(base,"~/") ? joinpath(provider.home,chat_suffix(base,2)) : isabspath(base) ? base : joinpath(provider.directory,base)
        if isdir(expanded)
            directory=expanded;display=base;filter_query=String(SubString(query,nextind(query,slash)))
        end
    end
    shallow=chat_completion_fd_entries(provider.finder,directory,filter_query,cancelled;depth=1)
    recursive=chat_completion_fd_entries(provider.finder,directory,filter_query,cancelled)
    seen=Set(row.path for row in shallow)
    records=vcat(shallow,[row for row in recursive if !(row.path in seen)])
    scored=[(;entry,score=isempty(filter_query) ? 1 : chat_completion_attachment_score(entry.path,filter_query,entry.directory)) for entry in records]
    filter!(row->row.score>0,scored)
    sort!(scored;by=row->(-row.score,count(==('/'),rstrip(row.entry.path,'/')),length(row.entry.path),lowercase(row.entry.path),row.entry.path))
    items=ChatCompletionItem[]
    if !cancelled[]
        for row in first(scored,20)
            path=display*row.entry.path;without=rstrip(path,'/')
            push!(items,ChatCompletionItem(;value=chat_completion_value(path,true,quoted),label=basename(without)*(row.entry.directory ? "/" : ""),description=without))
        end
    end
    isempty(items) ? nothing : ChatCompletionResult(;prefix=String(prefix),items)
end

chat_completion_argument_items(::Nothing)=ChatCompletionItem[]
chat_completion_argument_items(items::Vector{ChatCompletionItem})=items
chat_completion_argument_items(task::Task)=chat_completion_argument_items(fetch(task))
"""Reject invalid or explicitly failed extension results instead of claiming an empty successful completion."""
function chat_completion_argument_items(result)
    if result isa NamedTuple && hasproperty(result,:ok) && result.ok===false
        error(hasproperty(result,:reason) ? string(result.reason) : "Command argument completion was rejected")
    else
        error("Command argument completion must return ChatCompletionItem[], nothing, or a Task yielding either")
    end
end
