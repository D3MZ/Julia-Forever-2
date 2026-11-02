"""Validation reports safe outcomes and model identifiers, never a key or server error body."""
Base.@kwdef struct APIKeyValidation
    ok::Bool=false
    reason::Symbol=:rejected
    model_ids::Vector{String}=String[]
end

"""Private per-flow state; only bounded printable keys reach a provider-owned validator."""
Base.@kwdef mutable struct APIKeyRequest{G}
    directory::String
    commit::G=action->action()
    expected::Union{Nothing,String}=nothing
    phase::Symbol=:waiting
    bytes::Vector{UInt8}=UInt8[]
    model_ids::Vector{String}=String[]
end
Base.show(io::IO,::APIKeyRequest)=print(io,"APIKeyRequest([redacted])")

"""A callable native auth method owns its requests; registry presence alone does not claim validation."""
Base.@kwdef struct APIKeyAuthMethod{V}
    provider::Symbol
    name::String
    validate::V
    lock::ReentrantLock=ReentrantLock()
    requests::IdDict{AuthFlow,APIKeyRequest}=IdDict{AuthFlow,APIKeyRequest}()
end
Base.show(io::IO,method::APIKeyAuthMethod)=print(io,"APIKeyAuthMethod(",method.provider,", [private state redacted])")
api_key_validation_message(::Val{:cancelled})="API key sign-in cancelled."
api_key_validation_message(::Val{:invalid})="Enter a nonempty API key without spaces or control characters."
api_key_validation_message(::Val{:rejected})="The provider rejected this API key."
api_key_validation_message(::Val{:unavailable})="The provider could not validate this API key."
api_key_validation_message(::Val{:catalog})="The provider returned no usable model catalog for this API key."
api_key_validation_message(::Val{:changed})="Stored credentials changed during validation; nothing was replaced."
api_key_validation_message(::Val{:storage})="API key validation succeeded, but credential persistence is unconfirmed."
api_key_validation_message(::Val)= "API key validation failed."

function api_key_request_status(method::APIKeyAuthMethod,flow::AuthFlow)
    lock(method.lock) do
        request=get(method.requests,flow,nothing)
        isnothing(request) ? (available=false,phase=:absent,prompt="",provider=method.provider) :
            (available=active_auth(flow) && request.phase==:waiting,phase=request.phase,prompt="Enter "*method.name,provider=method.provider)
    end
end

"""Accept one private key; receipt is not provider validation or successful persistence."""
function submit_api_key!(method::APIKeyAuthMethod,flow::AuthFlow,value::AbstractString)
    lock(method.lock) do
        request=get(method.requests,flow,nothing)
        valid=0<sizeof(value)<=8192 && all(byte->0x21<=byte<=0x7e,codeunits(value))
        if isnothing(request) || !active_auth(flow) || request.phase!=:waiting
            (ok=false,reason=:inactive)
        elseif !valid
            (ok=false,reason=:invalid)
        else
            request.bytes=collect(codeunits(value))
            request.phase=:validating
            (ok=true,reason=:received)
        end
    end
end

function begin_api_key!(method::APIKeyAuthMethod,flow::AuthFlow,provider::Symbol,directory::AbstractString;commit=action->action())
    lock(method.lock) do
        if provider!=method.provider || !active_auth(flow) || haskey(method.requests,flow)
            nothing
        else
            expected=CredentialStorage.credential_revision(directory,provider)
            request=APIKeyRequest(;directory=String(directory),expected,commit)
            method.requests[flow]=request
            request
        end
    end
end

function finish_api_key!(method::APIKeyAuthMethod,flow::AuthFlow)
    lock(method.lock) do
        request=pop!(method.requests,flow,nothing)
        if !isnothing(request)
            fill!(request.bytes,0)
            empty!(request.bytes)
        end
    end
    nothing
end

function await_api_key(method::APIKeyAuthMethod,flow::AuthFlow,request::APIKeyRequest)
    waiting=true
    while waiting && active_auth(flow)
        waiting=lock(()->request.phase==:waiting,method.lock)
        waiting && sleep(0.01)
    end
    lock(method.lock) do
        active_auth(flow) && request.phase==:validating ? String(copy(request.bytes)) : ""
    end
end

"""Validate and save under distinct owners; cancellation or an intervening credential change prevents replacement."""
function persist_validated_api_key!(flow::AuthFlow,method::APIKeyAuthMethod,request::APIKeyRequest,key::String,models::Vector{String})
    CredentialStorage.credential_write(request.directory,method.provider) do path
        lock(flow.lock) do
            current=CredentialStorage.credential_file_revision(path)
            if !active_auth(flow)
                (ok=false,reason=:cancelled)
            elseif current!=request.expected
                (ok=false,reason=:changed)
            else
                data=Dict("type"=>"api_key","key"=>key,"validated_at"=>time(),"model_ids"=>copy(models))
                text=JSON.json(data)
                mktemp(request.directory) do temporary,output
                    chmod(temporary,0o600)
                    write(output,text)
                    flush(output)
                    if Sys.isunix() && ccall(:fsync,Cint,(Cint,),fd(output))!=0
                        error("Credential sync failed")
                    end
                    close(output)
                    Base.Filesystem.rename(temporary,path)
                    CredentialStorage.credential_sync_directory(path)
                end
                if read(path,String)!=text || stat(path).mode & 0o777 != 0o600
                    error("Credential verification failed")
                end
                (ok=true,reason=:saved)
            end
        end
    end
end

function run_api_key!(method::APIKeyAuthMethod,flow::AuthFlow,request::APIKeyRequest;notify)
    notify()
    key=await_api_key(method,flow,request)
    if isempty(key) || !active_auth(flow)
        (ok=false,reason=api_key_validation_message(Val(:cancelled)))
    else
        validation=method.validate(method.provider,key,flow.context)::APIKeyValidation
        lock(method.lock) do
            fill!(request.bytes,0)
            empty!(request.bytes)
        end
        if !active_auth(flow)
            (ok=false,reason=api_key_validation_message(Val(:cancelled)))
        elseif !validation.ok || isempty(validation.model_ids)
            (ok=false,reason=api_key_validation_message(Val(validation.ok ? :catalog : validation.reason)))
        else
            saved=Task(()->request.commit(()->persist_validated_api_key!(flow,method,request,key,validation.model_ids)))
            schedule(saved)
            wait(saved;throw=false)
            outcome=istaskfailed(saved) ? (ok=false,reason=:storage) : fetch(saved)
            if outcome.ok
                lock(method.lock) do
                    request.phase=:saved
                    request.model_ids=copy(validation.model_ids)
                end
                (ok=true,reason="API key validated and saved.")
            else
                (ok=false,reason=api_key_validation_message(Val(outcome.reason)))
            end
        end
    end
end

"""Run the real key workflow without exposing validator exceptions or keeping completed flow secrets."""
function (method::APIKeyAuthMethod)(flow::AuthFlow,provider::Symbol,directory::AbstractString;announce=Returns(nothing),notify=Returns(nothing),commit=action->action())
    claim=Task(()->begin_api_key!(method,flow,provider,directory;commit))
    schedule(claim)
    wait(claim;throw=false)
    request=istaskfailed(claim) ? nothing : fetch(claim)
    if isnothing(request)
        (ok=false,reason="API key sign-in could not acquire safe credential ownership.")
    else
        operation=Task(()->run_api_key!(method,flow,request;notify))
        schedule(operation)
        wait(operation;throw=false)
        result=istaskfailed(operation) ? (ok=false,reason="API key validation failed.") : fetch(operation)
        finish_api_key!(method,flow)
        result
    end
end
