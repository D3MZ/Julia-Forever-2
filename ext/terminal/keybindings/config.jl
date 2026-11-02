const NATIVE_KEYBINDING_LIMIT=64*1024
const NATIVE_KEYBINDING_MIGRATIONS=Dict(
    "interrupt"=>"app.interrupt","clear"=>"app.clear","exit"=>"app.exit","suspend"=>"app.suspend",
    "cycleThinkingLevel"=>"app.thinking.cycle","cycleModelForward"=>"app.model.cycleForward","cycleModelBackward"=>"app.model.cycleBackward",
    "selectModel"=>"app.model.select","expandTools"=>"app.tools.expand","toggleThinking"=>"app.thinking.toggle",
    "externalEditor"=>"app.editor.external","followUp"=>"app.message.followUp","dequeue"=>"app.message.dequeue","pasteImage"=>"app.clipboard.pasteImage",
    "selectUp"=>"tui.select.up","selectDown"=>"tui.select.down","selectPageUp"=>"tui.select.pageUp",
    "selectPageDown"=>"tui.select.pageDown","selectConfirm"=>"tui.select.confirm","selectCancel"=>"tui.select.cancel",
    "newSession"=>"app.session.new","tree"=>"app.session.tree","fork"=>"app.session.fork","resume"=>"app.session.resume")

"""Read only the selected private config through owned, no-follow descriptors; never execute its contents."""
function native_keybinding_read(path::String)
    basename(path)=="keybindings.json" || error("Keybindings path is not the native keybindings store")
    islink(path) && error("Keybindings file is a symlink; previous bindings retained")
    ispath(path) || return nothing
    supported=Sys.isunix() && all(!iszero,(Base.Filesystem.JL_O_NOFOLLOW,Base.Filesystem.JL_O_DIRECTORY,Base.Filesystem.JL_O_CLOEXEC,Base.Filesystem.JL_O_NONBLOCK))
    supported || error("Secure keybinding file reads are unavailable on this host; previous bindings retained")
    ncodeunits(path)<=4096 || error("Keybindings path exceeds the limit")
    files=Base.Filesystem.File[]
    outcome=preference_attempt() do
        flags=Base.Filesystem.JL_O_RDONLY | Base.Filesystem.JL_O_DIRECTORY | Base.Filesystem.JL_O_NOFOLLOW | Base.Filesystem.JL_O_CLOEXEC
        push!(files,Base.Filesystem.open("/",flags))
        parts=filter(!isempty,split(abspath(path),'/'));owner=ccall(:geteuid,Cuint,())
        for (index,part) in enumerate(parts)
            push!(files,project_resource_openat(last(files),String(part),index<length(parts)))
            metadata=stat(last(files));ancestor=index<length(parts)-1
            owned=metadata.uid==owner || ancestor && metadata.uid==0
            protected=(metadata.mode&0o022)==0 || ancestor && isdir(metadata) && (metadata.mode&0o1000)!=0
            owned && protected || error("Keybindings storage has unsafe ownership or writable permissions; previous bindings retained")
        end
        file=last(files);metadata=stat(file)
        isfile(metadata) || error("Keybindings path is not a regular file")
        metadata.size<=NATIVE_KEYBINDING_LIMIT || error("Keybindings file exceeds 64 KiB")
        bytes=read(file,NATIVE_KEYBINDING_LIMIT+1)
        length(bytes)<=NATIVE_KEYBINDING_LIMIT || error("Keybindings file exceeds 64 KiB")
        isvalid(String,bytes) || error("Keybindings file is not valid UTF-8")
        String(bytes)
    end
    for file in reverse(files)
        close(file)
    end
    outcome.ok || error(outcome.reason)
    outcome.value
end

"""Reject unsupported or malformed remaps atomically rather than claiming inert entries are active."""
function native_keybinding_config(state::NativeKeybindings,raw::Union{Nothing,String})
    data=isnothing(raw) ? Dict{String,Any}() : JSON.parse(startswith(raw,'\ufeff') ? chop(raw;head=1,tail=0) : raw;maxdepth=4)
    data isa AbstractDict || error("Keybindings must be a JSON object; previous bindings retained")
    length(data)<=256 || error("Too many keybinding entries; previous bindings retained")
    available=Set(definition.id for definition in state.definitions)
    configured=Dict{String,Vector{String}}()
    for (name,value) in data
        name=="\$schema" && continue
        name isa String && ncodeunits(name)<=128 || error("Invalid keybinding action identifier")
        action=get(NATIVE_KEYBINDING_MIGRATIONS,name,name)
        name!=action && haskey(data,action) && continue
        action in available || error("Keybinding action is not configurable in this build: "*session_display_safe(action)*"; previous bindings retained")
        values=value isa String ? [value] : value isa AbstractVector && all(item->item isa String,value) ? String.(value) : nothing
        isnothing(values) && error("Keybinding values must be a key ID or an array of key IDs")
        length(values)<=32 || error("A keybinding has too many keys")
        all(key->!isnothing(native_key_id(key)),values) || error("Invalid key ID for "*action*"; previous bindings retained")
        configured[action]=unique(values)
    end
    native_keybinding_plan(state,configured)
end

"""Prepare an immutable, bounded binding candidate; failures cannot mutate the active registry."""
function native_keybinding_prepare(state::NativeKeybindings,path::String)
    preference_attempt() do
        native_keybinding_config(state,native_keybinding_read(path))
    end
end
