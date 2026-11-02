import YAML

"""A loaded prompt is inert data until the user explicitly invokes its registered command."""
Base.@kwdef struct PromptTemplateData
    name::String
    description::String = ""
    argument_hint::Union{Nothing,String} = nothing
    content::String
    file_path::Union{Nothing,String} = nothing
end
"""Normalize textual prompt boundaries without retaining display annotations or foreign character wrappers."""
prompt_plain_text(text::AbstractString)::String = String(text)
"""Emit valid terminal text when original UTF16 truncation leaves a lone surrogate in metadata."""
function prompt_display_text(text::AbstractString)
    plain=prompt_plain_text(text)
    isvalid(plain) ? plain : join(isvalid(char) ? char : '\ufffd' for char in plain)
end
prompt_menu_description(description::AbstractString,::Nothing) = prompt_display_text(description)
prompt_menu_description(description::AbstractString,hint::AbstractString) = prompt_display_text(isempty(hint) ? description : isempty(description) ? hint : string(hint," — ",description))
const PROMPT_RESOURCE_LIMIT = 2_097_152
const PROMPT_PATH_LIMIT = 4096
prompt_space(c::Char) = c in ('\t','\n','\v','\f','\r',' ','\u00a0','\u1680','\u2028','\u2029','\u202f','\u205f','\u3000','\ufeff') || '\u2000' <= c <= '\u200a'
prompt_strip(text::AbstractString) = String(strip(prompt_space,prompt_plain_text(text)))

"""Parse original quoted-empty command arguments without shell evaluation or escape expansion."""
function prompt_parse_args(text::AbstractString)
    value=prompt_plain_text(text)
    ncodeunits(value)<=PROMPT_RESOURCE_LIMIT || error("Prompt arguments exceed byte limit")
    result=String[]; current=IOBuffer(); delimiter=nothing; started=false
    for char in value
        if !isnothing(delimiter)
            if char==delimiter
                delimiter=nothing
            else
                print(current,char)
            end
        elseif char in ('\"','\'')
            delimiter=char;started=true
        elseif prompt_space(char)
            if started
                push!(result,String(take!(current)));started=false
            end
        else
            print(current,char);started=true
        end
    end
    started&&push!(result,String(take!(current)))
    result
end
function prompt_index(digits::AbstractString,limit::Int)
    value=0
    for digit in digits
        if value<=limit
            increment=Int(digit)-Int('0')
            value=value>fld(limit-increment,10) ? limit+1 : value*10+increment
        end
    end
    value
end
prompt_position(args,index::Int) = 1<=index<=length(args) ? String(args[index]) : ""
function prompt_replacement(found::RegexMatch,args::AbstractVector{<:AbstractString},allargs::String)
    target,default,start,count,simple=found.captures
    if !isnothing(target)
        value=target in ("@","ARGUMENTS") ? allargs : prompt_position(args,prompt_index(target,length(args)))
        isempty(value) ? String(default::AbstractString) : value
    elseif !isnothing(start)
        firstarg=max(1,prompt_index(start,length(args)))
        lastarg=isnothing(count) ? length(args) : min(length(args),firstarg+prompt_index(count,length(args))-1)
        firstarg>lastarg ? "" : join(args[firstarg:lastarg]," ")
    elseif simple in ("@","ARGUMENTS")
        allargs
    else
        prompt_position(args,prompt_index(simple::AbstractString,length(args)))
    end
end
"""Expand each original placeholder once; replacement/default text is never parsed recursively."""
function prompt_substitute_args(content::AbstractString,args::AbstractVector{<:AbstractString};max_bytes::Int=PROMPT_RESOURCE_LIMIT)
    ncodeunits(content)<=max_bytes || error("Prompt template exceeds resource byte limit")
    sum(ncodeunits,args;init=0)<=max_bytes || error("Prompt arguments exceed resource byte limit")
    text=prompt_plain_text(content);allargs=prompt_plain_text(join(args," "));out=IOBuffer();position=firstindex(text)
    pattern=r"\$\{([0-9]+|ARGUMENTS|@):-([^}]*)\}|\$\{@:([0-9]+)(?::([0-9]+))?\}|\$(ARGUMENTS|@|[0-9]+)"
    for found in eachmatch(pattern,text)
        position<found.offset&&print(out,SubString(text,position,prevind(text,found.offset)))
        print(out,prompt_replacement(found,args,allargs))
        position=found.offset+ncodeunits(found.match)
        Base.position(out)<=max_bytes || error("Expanded prompt exceeds resource byte limit")
    end
    position<=lastindex(text)&&print(out,SubString(text,position))
    Base.position(out)<=max_bytes || error("Expanded prompt exceeds resource byte limit")
    String(take!(out))
end
function prompt_command_parts(text::AbstractString)
    value=prompt_plain_text(text)
    if !startswith(value,"/") || value=="/"
        nothing
    else
        firstchar=nextind(value,firstindex(value));space=findnext(prompt_space,value,firstchar)
        if isnothing(space)
            (name=String(SubString(value,firstchar)),arguments="")
        elseif space==firstchar
            nothing
        else
            after=findnext(c->!prompt_space(c),value,space)
            (name=String(SubString(value,firstchar,prevind(value,space))),arguments=isnothing(after) ? "" : String(SubString(value,after)))
        end
    end
end
"""Expand only an exact registered template; unknown commands remain unchanged."""
function prompt_expand_template(text::AbstractString,templates::AbstractVector)
    command=prompt_command_parts(text)
    index=isnothing(command) ? nothing : findfirst(item->item.name==command.name,templates)
    isnothing(index) ? String(text) : prompt_substitute_args(templates[index].content,prompt_parse_args(command.arguments))
end

function prompt_frontmatter_parts(raw::AbstractString)
    text=replace(String(raw),"\r\n"=>"\n","\r"=>"\n")
    startswith(text,"\ufeff")&&(text=String(SubString(text,nextind(text,firstindex(text)))))
    boundary=startswith(text,"---") ? findnext("\n---",text,4) : nothing
    if isnothing(boundary)
        (yaml=nothing,body=text)
    else
        stop=first(boundary)
        yaml=stop>4 ? String(SubString(text,5,prevind(text,stop))) : ""
        after=last(boundary)+1
        (yaml,body=after<=ncodeunits(text) ? prompt_strip(SubString(text,after)) : "")
    end
end
function prompt_validate_node(node::YAML.Node,active::Set{UInt},budget::Base.RefValue{Int},depth::Int)
    depth<=64 || error("Prompt frontmatter nesting exceeds safety limit")
    budget[]+=1;budget[]<=10_000 || error("Prompt frontmatter aliases exceed safety limit")
    identity=objectid(node);identity in active&&error("Cyclic prompt frontmatter is unsupported")
    push!(active,identity)
    prompt_validate_children(node,active,budget,depth)
    delete!(active,identity)
    nothing
end
prompt_validate_children(::YAML.ScalarNode,active,budget,depth) = nothing
function prompt_validate_children(node::YAML.SequenceNode,active,budget,depth)
    for child in node.value
        prompt_validate_node(child,active,budget,depth+1)
    end
end
function prompt_validate_children(node::YAML.MappingNode,active,budget,depth)
    keys=Set{String}()
    for (key,value) in node.value
        if key isa YAML.ScalarNode
            key.value in keys&&error("Duplicate prompt frontmatter key: "*key.value)
            push!(keys,key.value)
        end
        prompt_validate_node(key,active,budget,depth+1)
        prompt_validate_node(value,active,budget,depth+1)
    end
end
prompt_metadata_string(node) = nothing
function prompt_metadata_string(node::YAML.ScalarNode)
    node.tag in ("tag:yaml.org,2002:str","tag:yaml.org,2002:timestamp") || startswith(node.tag,"!") ? node.value : nothing
end
"""Bound the streaming YAML event sequence before recursive composition or alias traversal."""
function prompt_validate_yaml_events(yaml::String)
    events=YAML.EventStream(YAML.TokenStream(IOBuffer(yaml*"\n")))
    depth=0;count=0;documents=0
    event=YAML.forward!(events)
    while !(event isa YAML.StreamEndEvent) && !isnothing(event)
        count+=1;count<=20_000 || error("Prompt frontmatter event count exceeds safety limit")
        if event isa Union{YAML.SequenceStartEvent,YAML.MappingStartEvent}
            depth+=1;depth<=64 || error("Prompt frontmatter nesting exceeds safety limit")
        elseif event isa Union{YAML.SequenceEndEvent,YAML.MappingEndEvent}
            depth-=1
        elseif event isa YAML.DocumentStartEvent
            documents+=1;documents<=1 || error("Prompt frontmatter must contain a single YAML document")
        end
        event=YAML.forward!(events)
    end
    nothing
end
prompt_yaml_metadata(::Nothing) = Dict{String,String}()
function prompt_yaml_metadata(yaml::String)
    prompt_validate_yaml_events(yaml)
    resolver=YAML.Resolver()
    filter!(entry->!(first(entry) in ("tag:yaml.org,2002:timestamp","tag:yaml.org,2002:merge")),resolver.implicit_resolvers)
    node=YAML.compose(YAML.EventStream(YAML.TokenStream(IOBuffer(yaml*"\n"))),resolver)
    data=Dict{String,String}()
    if node isa YAML.Node
        prompt_validate_node(node,Set{UInt}(),Ref(0),0)
        if node isa YAML.MappingNode
            for (key,value) in node.value
                if key isa YAML.ScalarNode
                    text=prompt_metadata_string(value)
                    !isnothing(text)&&(data[key.value]=text)
                end
            end
        end
    end
    data
end
"""Strip frontmatter as data, without invoking custom YAML constructors or resource instructions."""
function prompt_parse_frontmatter(raw::AbstractString)
    ncodeunits(raw)<=PROMPT_RESOURCE_LIMIT || error("Prompt resource exceeds byte limit")
    parts=prompt_frontmatter_parts(raw)
    metadata=prompt_yaml_metadata(parts.yaml)
    (metadata,body=parts.body)
end
function prompt_description(body::AbstractString)
    lines=split(body,'\n');index=findfirst(line->!isempty(prompt_strip(line)),lines)
    if isnothing(index)
        ""
    else
        line=String(lines[index]);units=transcode(UInt16,line)
        if length(units)<=60
            line
        else
            string(transcode(String,units[1:60]),"...")
        end
    end
end
function prompt_template_from_text(name::AbstractString,raw::AbstractString;file_path=nothing)
    parsed=prompt_parse_frontmatter(raw)
    description=get(parsed.metadata,"description","")
    hint=get(parsed.metadata,"argument-hint",nothing)
    PromptTemplateData(name=String(name),description=isempty(description) ? prompt_description(parsed.body) : description,
        argument_hint=isnothing(hint)||isempty(hint) ? nothing : hint,content=parsed.body,file_path=file_path)
end
function prompt_read_file(path::AbstractString)
    target=String(path)
    ncodeunits(target)<=PROMPT_PATH_LIMIT || error("Resource path exceeds byte limit")
    isvalid(target) || error("Resource path is not valid UTF-8")
    occursin('\0',target)&&error("Resource path contains NUL")
    isabspath(target) || error("Resource path must be registered as an absolute path")
    isfile(target) || error("Resource file unavailable: "*target)
    data=open(target,"r") do io
        read(io,PROMPT_RESOURCE_LIMIT+1)
    end
    length(data)<=PROMPT_RESOURCE_LIMIT || error("Resource file exceeds byte limit: "*target)
    isvalid(String,data) || error("Resource file is not valid UTF-8: "*target)
    String(data)
end
function prompt_load_template(path::AbstractString)
    target=abspath(path);filename=basename(target)
    name=endswith(filename,".md") ? first(filename,length(filename)-3) : filename
    prompt_template_from_text(name,prompt_read_file(target);file_path=target)
end
function skill_expand_command(text::AbstractString,skills::AbstractVector;reader=prompt_read_file)
    value=String(text)
    if !startswith(value,"/skill:")
        value
    else
        space=findfirst(==(' '),value)
        name=isnothing(space) ? String(SubString(value,8)) : String(SubString(value,8,prevind(value,space)))
        index=findfirst(skill->skill.name==name,skills)
        if isnothing(index)
            value
        else
            skill=skills[index];path=String(skill.path)
            body=prompt_strip(prompt_parse_frontmatter(reader(path)).body)
            block=string("<skill name=\"",skill.name,"\" location=\"",path,"\">\nReferences are relative to ",dirname(path),".\n\n",body,"\n</skill>")
            args=isnothing(space) ? "" : prompt_strip(SubString(value,nextind(value,space)))
            isempty(args) ? block : string(block,"\n\n",args)
        end
    end
end

"""Turn resource failures into explicit rejected input without executing an unchanged command."""
function prompt_expansion_result(expand::Function,original::AbstractString)
    task=Task(expand);schedule(task);wait(task;throw=false)
    if istaskfailed(task)
        failures=Base.current_exceptions(task)
        reason=isempty(failures) ? "Resource expansion failed" : sprint(showerror,last(failures).exception)
        (ok=false,reason,text=String(original))
    else
        (ok=true,reason="",text=fetch(task)::String)
    end
end

function prompt_load_result(path::AbstractString)
    task=Task(()->prompt_load_template(path));schedule(task);wait(task;throw=false)
    if istaskfailed(task)
        failures=Base.current_exceptions(task)
        reason=isempty(failures) ? "Prompt resource unavailable" : sprint(showerror,last(failures).exception)
        (ok=false,reason,value=nothing)
    else
        (ok=true,reason="",value=fetch(task)::PromptTemplateData)
    end
end
