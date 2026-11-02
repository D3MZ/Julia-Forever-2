"""Fixed endpoint metadata validation uses the provider's real auth header and never invokes inference."""
Base.@kwdef struct APIKeyCatalogValidator{T}
    provider::Symbol
    url::String
    header::Symbol=:bearer
    known_models::Vector{String}
    transport::T
    paginate::Bool=false
    max_pages::Int=32
end
Base.show(io::IO,client::APIKeyCatalogValidator)=print(io,"APIKeyCatalogValidator(",client.provider,")")
api_key_headers(::Val{:bearer},key::AbstractString)=["Authorization"=>"Bearer "*key]
api_key_headers(::Val{:anthropic},key::AbstractString)=["x-api-key"=>String(key),"anthropic-version"=>"2023-06-01"]
api_key_model_headers(kind::Val,key::AbstractString)=api_key_headers(kind,key)
api_key_model_headers(::Val{:anthropic},key::AbstractString)=["x-api-key"=>String(key)]

function api_key_catalog_validation(client::APIKeyCatalogValidator,response)
    if response.status in (401,403)
        APIKeyValidation(;reason=:rejected)
    elseif !(200<=response.status<300)
        APIKeyValidation(;reason=:unavailable)
    else
        data=parse_json(response.body)
        rows=data isa AbstractDict ? get(data,"data",nothing) : nothing
        valid=rows isa AbstractVector && all(row->row isa AbstractDict && get(row,"id",nothing) isa AbstractString,rows)
        ids=valid ? unique(String[row["id"] for row in rows if row["id"] in client.known_models]) : String[]
        isempty(ids) ? APIKeyValidation(;reason=:catalog) : APIKeyValidation(;ok=true,reason=:validated,model_ids=ids)
    end
end

"""Follow only bounded same-endpoint cursors; never follow provider-supplied URLs or silently accept partial failures."""
function (client::APIKeyCatalogValidator)(provider::Symbol,key::String,context::ExecutionContext)
    if provider!=client.provider || cancelled(context)
        APIKeyValidation(;reason=:cancelled)
    else
        api_key_catalog_pages(client,key,context)
    end
end
function api_key_catalog_pages(client::APIKeyCatalogValidator,key::String,context::ExecutionContext)
    headers=api_key_headers(Val(client.header),key)
    url=client.url
    seen=Set{String}()
    ids=String[]
    finished=false
    outcome=APIKeyValidation(;reason=:catalog)
    page=0
    while !finished && !cancelled(context) && page<client.max_pages
        page+=1
        response=client.transport(url,"GET","",headers,context,nothing)
        data=200<=response.status<300 ? parse_json(response.body) : nothing
        rows=data isa AbstractDict ? get(data,"data",nothing) : nothing
        valid=rows isa AbstractVector && all(row->row isa AbstractDict && get(row,"id",nothing) isa String,rows)
        if !valid
            outcome=api_key_catalog_validation(client,response)
            finished=true
        else
            append!(ids,String[row["id"] for row in rows if row["id"] in client.known_models])
            unique!(ids)
            more=client.paginate && get(data,"has_more",false)===true && length(ids)<length(client.known_models)
            cursor=get(data,"last_id",nothing)
            if !more
                outcome=isempty(ids) ? APIKeyValidation(;reason=:catalog) : APIKeyValidation(;ok=true,reason=:validated,model_ids=ids)
                finished=true
            elseif cursor isa String && 0<sizeof(cursor)<=256 && !isempty(rows) && last(rows)["id"]==cursor && !(cursor in seen)
                push!(seen,cursor)
                url=client.url*"?after_id="*url_encode(cursor)
            else
                finished=true
            end
        end
    end
    cancelled(context) ? APIKeyValidation(;reason=:cancelled) : outcome
end

"""Resolve only this provider's current app-owned key at request time; never freeze a logged-out secret in a backend."""
Base.@kwdef struct APIKeyCredentialResolver
    provider::Symbol
    directory::String
    header::Symbol=:bearer
end
Base.show(io::IO,resolver::APIKeyCredentialResolver)=print(io,"APIKeyCredentialResolver(",resolver.provider,", [private location redacted])")
function (resolver::APIKeyCredentialResolver)(model,context::ExecutionContext)
    saved=cancelled(context) ? nothing : api_key_credentials(resolver.directory,resolver.provider)
    key=saved isa AbstractDict && get(saved,"type",nothing)=="api_key" ? get(saved,"key",nothing) : nothing
    if api_key_saved(saved) && key isa String && 0<sizeof(key)<=8192 && all(byte->0x21<=byte<=0x7e,codeunits(key)) &&
            (!(model isa ModelSpec) || model.id in saved["model_ids"])
        api_key_model_headers(Val(resolver.header),key)
    else
        error("A validated API key is unavailable for this provider")
    end
end
