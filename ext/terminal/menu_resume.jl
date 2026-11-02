# Native archive selection. Load, rename, and delete effects remain explicit owner requests.
include("menu_session_presentation.jl")
include("menu_resume_search.jl")
public ResumeEntry, ResumeMenu, ResumeLoadRequest, ResumeMutationRequest, resume_menu
public resume_input!, resume_lines, resume_selected, resume_progress!, resume_loaded!, resume_failed!
public resume_mutation_complete!, resume_dispose!, resume_mouse!, resume_hardware_cursor, resume_draw!
public resume_captures_viewport

Base.@kwdef struct ResumeEntry
    id::String
    path::String
    cwd::String=""
    created::Float64=0.0
    modified::Float64=created
    messages::Int=0
    first_message::String=""
    text::String=""
    name::Union{Nothing,String}=nothing
    parent::Union{Nothing,String}=nothing
end
Base.@kwdef mutable struct ResumeMutationRequest
    id::Int
    kind::Symbol
    path::String
    value::Union{Nothing,String}=nothing
    completed::Bool=false
end
Base.@kwdef mutable struct ResumeLoadRequest
    id::Int
    scope::Symbol
    cancelled::Bool=false
    completed::Bool=false
    continuation::Union{Nothing,ResumeMutationRequest}=nothing
end
Base.@kwdef struct ResumeRow
    entry::ResumeEntry
    depth::Int=0
    last::Bool=true
    ancestors::Vector{Bool}=Bool[]
end
Base.@kwdef mutable struct ResumeMenu{L,S,C,R,D,V,Q,U,F,N,P} <: SessionSelectionMenu
    on_load::L
    on_select::S
    on_cancel::C
    on_rename::R
    on_delete::D
    request_render::V
    schedule::Q
    unschedule::U
    style::F
    now::N
    path_key::P
    home::String=homedir()
    bold::Bool=false
    focused::Bool=false
    current_path::Union{Nothing,String}=nothing
    scope::Symbol=:current
    sort::Symbol=:threaded
    names::Symbol=:all
    mode::Symbol=:list
    caches::Dict{Symbol,Union{Nothing,Vector{ResumeEntry}}}=Dict{Symbol,Union{Nothing,Vector{ResumeEntry}}}(:current=>nothing,:all=>nothing)
    loads::Dict{Symbol,ResumeLoadRequest}=Dict{Symbol,ResumeLoadRequest}()
    serial::Int=0
    mutation_serial::Int=0
    records::Vector{ResumeEntry}=ResumeEntry[]
    rows::Vector{ResumeRow}=ResumeRow[]
    cursor::Int=1
    selection_touched::Bool=false
    search::MenuSearchInput=MenuSearchInput()
    rename_input::MenuSearchInput=MenuSearchInput()
    rename_target::Union{Nothing,String}=nothing
    rename_focused::Bool=false
    show_cwd::Bool=false
    show_path::Bool=false
    show_rename::Bool=false
    confirming_delete::Union{Nothing,String}=nothing
    maximum_rows::Int=10
    header_scope::Symbol=:current
    loading::Bool=false
    progress::Union{Nothing,Tuple{Int,Int}}=nothing
    status::Union{Nothing,Tuple{Symbol,String}}=nothing
    status_timer::Any=nothing
    status_generation::Int=0
    width::Int=0
    input_row::Int=0
    disposed::Bool=false
end

resume_path_key(path::AbstractString)=ispath(path) ? realpath(path) : normpath(abspath(path))

"""Construct an archive selector and immediately request the current directory from its owner."""
function resume_menu(;on_load,on_select,on_cancel,on_rename=nothing,on_delete=nothing,
        request_render=Returns(nothing),schedule=tree_schedule,unschedule=session_cancel_timer,
        style=tree_default_style,bold::Bool=false,focused::Bool=false,now=time,path_key=resume_path_key,
        home::AbstractString=homedir(),current_path=nothing,show_rename::Bool=!isnothing(on_rename))
    menu=ResumeMenu(;on_load,on_select,on_cancel,on_rename,on_delete,request_render,schedule,unschedule,
        style,bold,focused,now,path_key,home=String(home),current_path,show_rename,rename_focused=focused)
    resume_load!(menu,:current)
    menu
end
resume_selected(menu::ResumeMenu)=1<=menu.cursor<=length(menu.rows) ? menu.rows[menu.cursor].entry.path : nothing
resume_current(menu::ResumeMenu,path::AbstractString)=resume_current(menu,path,menu.current_path)
resume_current(menu::ResumeMenu,path::AbstractString,::Nothing)=false
resume_current(menu::ResumeMenu,path::AbstractString,current::AbstractString)=menu.path_key(path)==menu.path_key(current)
resume_captures_viewport(menu::ResumeMenu)=menu.mode!=:rename

"""Build activity-ordered archive ancestry without changing service-owned records."""
function resume_tree(entries::Vector{ResumeEntry},path_key)
    count=length(entries)
    indices=Dict(path_key(entry.path)=>index for (index,entry) in enumerate(entries))
    children=[Int[] for _ in entries]
    parents=zeros(Int,count)
    for (index,entry) in enumerate(entries)
        parent=isnothing(entry.parent) ? 0 : get(indices,path_key(entry.parent),0)
        parents[index]=parent==index ? 0 : parent
        parents[index]==0 || push!(children[parents[index]],index)
    end
    roots=findall(==(0),parents)
    activity=[entry.modified for entry in entries]
    order=Int[]
    stack=reverse(roots)
    seen=Set{Int}()
    while !isempty(stack)
        index=pop!(stack)
        if !(index in seen)
            push!(seen,index)
            push!(order,index)
            append!(stack,reverse(children[index]))
        end
    end
    for index in reverse(order)
        if parents[index]!=0
            activity[parents[index]]=max(activity[parents[index]],activity[index])
        end
    end
    sort!(roots;by=index->-activity[index],alg=Base.Sort.MergeSort)
    for group in children
        sort!(group;by=index->-activity[index],alg=Base.Sort.MergeSort)
    end
    result=ResumeRow[]
    pending=[(index,0,Bool[],position==length(roots)) for (position,index) in reverse(collect(enumerate(roots)))]
    empty!(seen)
    while !isempty(pending)
        index,depth,ancestors,last=pop!(pending)
        if !(index in seen)
            push!(seen,index)
            push!(result,ResumeRow(;entry=entries[index],depth,last,ancestors))
            next=[ancestors;depth>0 ? !last : false]
            for position in reverse(eachindex(children[index]))
                push!(pending,(children[index][position],depth+1,next,position==length(children[index])))
            end
        end
    end
    result
end

function resume_filter!(menu::ResumeMenu)
    entries=resume_search(menu.records,menu.search.value,menu.sort,menu.names)
    menu.rows=menu.sort==:threaded && isempty(strip(menu.search.value)) ? resume_tree(entries,menu.path_key) : [ResumeRow(;entry) for entry in entries]
    menu.cursor=min(menu.cursor,max(1,length(menu.rows)))
    nothing
end
function resume_rows!(menu::ResumeMenu,entries::AbstractVector{ResumeEntry},show_cwd::Bool)
    selected=menu.selection_touched ? resume_selected(menu) : nothing
    menu.records=deepcopy(entries)
    menu.show_cwd=show_cwd
    resume_filter!(menu)
    if !menu.selection_touched
        menu.cursor=1
    elseif !isnothing(selected)
        index=findfirst(row->row.entry.path==selected,menu.rows)
        isnothing(index) || (menu.cursor=index)
    end
    nothing
end

function resume_loading!(menu::ResumeMenu,value::Bool)
    menu.loading=value
    menu.progress=nothing
    nothing
end
function resume_status!(menu::ResumeMenu,value;delay::Real=0)
    menu.unschedule(menu.status_timer)
    menu.status_timer=nothing
    menu.status_generation+=1
    generation=menu.status_generation
    menu.status=value
    if !isnothing(value) && delay>0
        menu.status_timer=menu.schedule(delay) do
            if !menu.disposed && menu.status_generation==generation
                menu.status=nothing
                menu.status_timer=nothing
                menu.request_render()
            end
        end
    end
    nothing
end

function resume_load!(menu::ResumeMenu,scope::Symbol;continuation=nothing)
    request=nothing
    if !menu.disposed && !haskey(menu.loads,scope)
        menu.serial+=1
        request=ResumeLoadRequest(;id=menu.serial,scope,continuation)
        menu.loads[scope]=request
        menu.header_scope=scope
        resume_loading!(menu,true)
        menu.request_render()
        menu.on_load(menu,request)
    end
    request
end
resume_load_active(menu::ResumeMenu,request::ResumeLoadRequest)=!menu.disposed && get(menu.loads,request.scope,nothing)===request

"""Accept progress only for the current request identity, including partial scope caches."""
function resume_progress!(menu::ResumeMenu,request::ResumeLoadRequest,loaded::Integer,total::Integer;entries=nothing)
    if resume_load_active(menu,request)
        if !isnothing(entries)
            rows=deepcopy(Vector{ResumeEntry}(entries))
            menu.caches[request.scope]=rows
            request.scope==menu.scope && resume_rows!(menu,rows,request.scope==:all)
        end
        if request.scope==menu.scope
            menu.progress=(Int(loaded),Int(total))
            menu.request_render()
        end
    end
    nothing
end
function resume_after_load!(menu::ResumeMenu,request::ResumeLoadRequest)
    mutation=request.continuation
    if !isnothing(mutation)
        if mutation.kind==:rename
            resume_exit_rename!(menu)
        else
            menu.request_render()
        end
    end
    nothing
end

"""Install an owner's load result; cancelled and superseded requests cannot replace rows."""
function resume_loaded!(menu::ResumeMenu,request::ResumeLoadRequest,entries::AbstractVector{ResumeEntry})
    first_completion=!request.completed
    request.completed=true
    if first_completion && resume_load_active(menu,request)
        rows=deepcopy(Vector{ResumeEntry}(entries))
        menu.caches[request.scope]=rows
        delete!(menu.loads,request.scope)
        if request.scope==menu.scope
            resume_loading!(menu,false)
            resume_rows!(menu,rows,request.scope==:all)
            menu.request_render()
        end
    end
    first_completion && !menu.disposed && resume_after_load!(menu,request)
    nothing
end
function resume_failed!(menu::ResumeMenu,request::ResumeLoadRequest,message::AbstractString)
    first_completion=!request.completed
    request.completed=true
    if first_completion && resume_load_active(menu,request)
        delete!(menu.loads,request.scope)
        menu.caches[request.scope]=nothing
        if request.scope==menu.scope
            resume_loading!(menu,false)
            resume_status!(menu,(:error,"Failed to load sessions: "*message);delay=4)
            resume_rows!(menu,ResumeEntry[],request.scope==:all)
            menu.request_render()
        end
    end
    first_completion && !menu.disposed && resume_after_load!(menu,request)
    nothing
end
function resume_cancel_loads!(menu::ResumeMenu)
    for (scope,request) in menu.loads
        request.cancelled=true
        menu.caches[scope]=nothing
    end
    empty!(menu.loads)
    nothing
end
function resume_refresh!(menu::ResumeMenu,request::ResumeMutationRequest)
    resume_cancel_loads!(menu)
    menu.caches[:current]=nothing
    menu.caches[:all]=nothing
    resume_load!(menu,menu.scope;continuation=request)
end
function resume_exit_rename!(menu::ResumeMenu)
    menu.mode=:list
    menu.rename_target=nothing
    menu.request_render()
    nothing
end

"""Complete a real owner mutation; a request alone never reports persistence success."""
function resume_mutation_complete!(menu::ResumeMenu,request::ResumeMutationRequest;ok::Bool,error::AbstractString="Unknown error",method::Symbol=:unlink)
    if !request.completed && !menu.disposed
        request.completed=true
        if request.kind==:rename
            if ok
                resume_refresh!(menu,request)
            else
                resume_exit_rename!(menu)
            end
        elseif ok
            for scope in (:current,:all)
                entries=menu.caches[scope]
                if !isnothing(entries)
                    menu.caches[scope]=filter(entry->entry.path!=request.path,entries)
                end
            end
            resume_rows!(menu,something(menu.caches[menu.scope],ResumeEntry[]),menu.scope==:all)
            resume_status!(menu,(:info,method==:trash ? "Session moved to trash" : "Session deleted");delay=2)
            resume_refresh!(menu,request)
        else
            resume_status!(menu,(:error,"Failed to delete: "*error);delay=3)
            menu.request_render()
        end
    end
    nothing
end

function resume_request_mutation!(menu::ResumeMenu,kind::Symbol,path::String,value=nothing)
    callback=kind==:rename ? menu.on_rename : menu.on_delete
    result=(action=kind,invoked=false,outcome=nothing)
    if !isnothing(callback)
        menu.mutation_serial+=1
        request=ResumeMutationRequest(;id=menu.mutation_serial,kind,path,value)
        result=(action=kind,invoked=true,outcome=callback(menu,request),request=request)
    elseif kind==:delete
        resume_status!(menu,(:error,"Session deletion is not available from this owner");delay=3)
        menu.request_render()
    end
    result
end
function resume_confirming!(menu::ResumeMenu,path)
    menu.confirming_delete=path
    menu.request_render()
    nothing
end
function resume_start_delete!(menu::ResumeMenu)
    path=resume_selected(menu)
    if !isnothing(path)
        if resume_current(menu,path)
            resume_status!(menu,(:error,"Cannot delete the currently active session");delay=3)
            menu.request_render()
        else
            resume_confirming!(menu,path)
        end
    end
    nothing
end

"""Route default key packets while preserving independent owner effect boundaries."""
function resume_input!(menu::ResumeMenu,data::AbstractString;selectors::NativeSelectorBindings=NativeSelectorBindings())
    result=(action=:none,invoked=false,outcome=nothing)
    confirming=menu.confirming_delete
    navigation=native_selector_navigation(selectors,data)
    if !menu.disposed
        if menu.mode==:rename
            if native_selector_matches(selectors,:cancel,data)
                resume_exit_rename!(menu)
            elseif menu_search_input!(menu.rename_input,data)==:submit
                value=String(strip(menu.rename_input.value))
                target=menu.rename_target
                if !isempty(value) && !isnothing(target)
                    result=resume_request_mutation!(menu,:rename,target,value)
                end
            end
        elseif !isnothing(confirming)
            if native_selector_matches(selectors,:confirm,data)
                path=confirming
                resume_confirming!(menu,nothing)
                result=resume_request_mutation!(menu,:delete,path)
            elseif native_selector_matches(selectors,:cancel,data)
                resume_confirming!(menu,nothing)
            end
        elseif data=="\t"
            menu.scope=menu.scope==:current ? :all : :current
            menu.header_scope=menu.scope
            resume_loading!(menu,haskey(menu.loads,menu.scope))
            entries=menu.caches[menu.scope]
            resume_rows!(menu,something(entries,ResumeEntry[]),menu.scope==:all)
            menu.request_render()
            if isnothing(entries) && !haskey(menu.loads,menu.scope)
                resume_load!(menu,menu.scope)
            end
        elseif data=="\x13"
            menu.sort=menu.sort==:threaded ? :recent : menu.sort==:recent ? :relevance : :threaded
            resume_filter!(menu)
            menu.request_render()
        elseif data=="\x0e"
            menu.names=menu.names==:all ? :named : :all
            resume_filter!(menu)
            menu.request_render()
        elseif data=="\x10"
            menu.show_path=!menu.show_path
            menu.request_render()
        elseif data=="\x04"
            resume_start_delete!(menu)
        elseif data=="\x12"
            path=resume_selected(menu)
            if !isnothing(path) && !isnothing(menu.on_rename) && !haskey(menu.loads,menu.scope)
                menu.mode=:rename
                menu.rename_target=path
                entry=menu.rows[menu.cursor].entry
                menu_search_set!(menu.rename_input,something(entry.name,""))
                menu.rename_focused=true
                menu.request_render()
            end
        elseif data in ("\e[127;5u","\e[8;5~")
            if isempty(menu.search.value)
                resume_start_delete!(menu)
            else
                submitted=menu_search_input!(menu.search,data)==:submit
                path=resume_selected(menu)
                if submitted && !isnothing(path)
                    resume_status!(menu,nothing);resume_cancel_loads!(menu)
                    result=(action=:select,invoked=true,outcome=menu.on_select(path),path=path)
                end
                resume_filter!(menu)
            end
        else
            menu.selection_touched=true
            if navigation==:up
                menu.cursor=max(1,menu.cursor-1)
            elseif navigation==:down
                menu.cursor=min(length(menu.rows),menu.cursor+1)
            elseif navigation==:page_up
                menu.cursor=max(1,menu.cursor-menu.maximum_rows)
            elseif navigation==:page_down
                menu.cursor=min(length(menu.rows),menu.cursor+menu.maximum_rows)
            elseif native_selector_matches(selectors,:confirm,data)
                path=resume_selected(menu)
                if !isnothing(path)
                    resume_status!(menu,nothing)
                    resume_cancel_loads!(menu)
                    result=(action=:select,invoked=true,outcome=menu.on_select(path),path=path)
                end
            elseif native_selector_matches(selectors,:cancel,data)
                resume_status!(menu,nothing)
                resume_cancel_loads!(menu)
                result=(action=:cancel,invoked=true,outcome=menu.on_cancel())
            else
                submitted=menu_search_input!(menu.search,data)==:submit
                path=resume_selected(menu)
                if submitted && !isnothing(path)
                    resume_status!(menu,nothing);resume_cancel_loads!(menu)
                    result=(action=:select,invoked=true,outcome=menu.on_select(path),path=path)
                end
                resume_filter!(menu)
            end
        end
    end
    result
end
function resume_dispose!(menu::ResumeMenu)
    menu.disposed=true
    resume_cancel_loads!(menu)
    resume_status!(menu,nothing)
    nothing
end
include("menu_resume_render.jl")
