using Test,JuliaForever2,JSON,Sockets
const KeyClient=JuliaForever2
@testset "Catalog validation uses declared provider headers and actual usable model ids" begin
    for header in (:bearer,:anthropic), scenario in (:valid,:unknown,:malformed,:denied,:unavailable)
        seen=[]
        transport=(url,method,body,headers,context,sink)->begin
            push!(seen,(url,method,body,headers))
            status=scenario==:denied ? 401 : scenario==:unavailable ? 503 : 200
            rows=scenario==:malformed ? nothing : [Dict("id"=>scenario==:unknown ? "unsupported" : "known")]
            (status,body=JSON.json(Dict("data"=>rows)),reason="")
        end
        client=KeyClient.APIKeyCatalogValidator(;provider=:fixture,url="https://example.invalid/models",header,known_models=["known"],transport)
        context=KeyClient.ExecutionContext()
        result=client(:fixture,"synthetic-key",context)
        @test result.ok==(scenario==:valid)
        @test result.model_ids==(scenario==:valid ? ["known"] : String[])
        @test only(seen)[1:3]==("https://example.invalid/models","GET","")
        @test only(seen)[4]==KeyClient.api_key_headers(Val(header),"synthetic-key")
        @test !occursin("synthetic-key",repr(result))
        @test !client(:other,"synthetic-key",context).ok
        @test length(seen)==1
        close(context)
    end
end
@testset "Credentials resolve lazily, disappear after logout, and never print" begin
    mktempdir() do directory
        resolver=KeyClient.APIKeyCredentialResolver(;provider=:fixture,directory)
        context=KeyClient.ExecutionContext()
        KeyClient.save_credentials!(directory,:fixture,Dict("type"=>"api_key","key"=>"synthetic-one","validated_at"=>1.0,"model_ids"=>["known"]))
        @test resolver(nothing,context)==["Authorization"=>"Bearer synthetic-one"]
        KeyClient.save_credentials!(directory,:fixture,Dict("type"=>"api_key","key"=>"synthetic-two","validated_at"=>1.0,"model_ids"=>["known"]))
        @test resolver(nothing,context)==["Authorization"=>"Bearer synthetic-two"]
        @test !occursin("synthetic",repr(resolver))
        KeyClient.CredentialStorage.delete_credentials!(directory,:fixture)
        @test_throws ErrorException resolver(nothing,context)
        close(context)
    end
end
function local_key_request(action;status="200 OK",headers="",body="{}")
    server=listen(ip"127.0.0.1",0)
    port=getsockname(server)[2]
    seen=Channel{String}(1)
    task=@async begin
        peer=accept(server)
        request=IOBuffer()
        line=readline(peer;keep=true)
        while !isempty(line) && line!="\r\n"
            write(request,line)
            line=readline(peer;keep=true)
        end
        put!(seen,String(take!(request)))
        write(peer,"HTTP/1.1 "*status*"\r\nConnection: close\r\nContent-Length: "*string(sizeof(body))*"\r\n"*headers*"\r\n"*body)
        close(peer)
    end
    action("http://127.0.0.1:"*string(port)*"/models",seen)
    close(server)
    wait(task)
end
@testset "Native HTTP confines synthetic keys and refuses redirect forwarding" begin
    local_key_request(;body="{\"data\":[{\"id\":\"known\"}]}") do url,seen
        transport=KeyClient.APIKeyHTTPTransport(;urls=[url],allow_loopback=true)
        context=KeyClient.ExecutionContext()
        result=transport(url,"GET","",["x-api-key"=>"synthetic-key"],context,nothing)
        @test result.status==200
        @test occursin("known",result.body)
        @test occursin("x-api-key: synthetic-key",take!(seen))
        @test !KeyClient.api_key_endpoint_allowed(transport,url*"?redirect=other")
        close(context)
    end
    local_key_request(;status="302 Found",headers="Location: http://127.0.0.1:9/forbidden\r\n",body="synthetic-key") do url,seen
        transport=KeyClient.APIKeyHTTPTransport(;urls=[url],allow_loopback=true)
        context=KeyClient.ExecutionContext()
        result=transport(url,"GET","",["x-api-key"=>"synthetic-key"],context,nothing)
        @test result.status==302
        @test isempty(result.body)
        @test !occursin("synthetic-key",repr(result))
        @test occursin("x-api-key: synthetic-key",take!(seen))
        close(context)
    end
end
@testset "Unsafe credential paths fail closed without crashing provider observation" begin
    mktempdir() do directory
        outside=joinpath(directory,"outside.json")
        write(outside,"external untouched")
        symlink(outside,joinpath(directory,"fixture.json"))
        @test KeyClient.api_key_observed_state(directory,:fixture)==:unavailable
        @test occursin("unsafe",KeyClient.api_key_provider_status(directory,:fixture))
        @test read(outside,String)=="external untouched"
    end
end
@testset "Unsupported protocol registrations never become decorative providers" begin
    models=[KeyClient.ModelSpec(:fixture,"known";api="openai-completions")]
    @test_throws ErrorException KeyClient.api_key_provider_descriptor(:fixture,"Fixture";models,endpoint="https://fixture.invalid",models_url="https://fixture.invalid/models",protocol=nothing)
    @test_throws ErrorException KeyClient.api_key_provider_descriptor(:fixture,"Fixture";models,endpoint="http://fixture.invalid",models_url="https://fixture.invalid/models")
    @test_throws ErrorException KeyClient.api_key_provider_descriptor(:fixture,"Fixture";models=KeyClient.ModelSpec[],endpoint="https://fixture.invalid",models_url="https://fixture.invalid/models")
end
@testset "Rejected API-key HTTP bodies cannot enter the model decoder" begin
    local_key_request(;status="401 Unauthorized",body="data: SYNTHETIC_PRIVATE_KEY\n\n") do url,seen
        transport=KeyClient.APIKeyHTTPTransport(;urls=[url],allow_loopback=true)
        context=KeyClient.ExecutionContext();sink=IOBuffer()
        result=transport(url,"GET","",["x-api-key"=>"SYNTHETIC_PRIVATE_KEY"],context,sink)
        @test result.status==401
        @test isempty(take!(sink))
        @test !occursin("SYNTHETIC_PRIVATE_KEY",repr(result))
        take!(seen);close(context)
    end
end
@testset "Native Anthropic key factory uses its real message protocol and current key" begin
    mktempdir() do directory
        model=KeyClient.ModelSpec(:fixture,"known";api="anthropic-messages")
        KeyClient.save_credentials!(directory,:fixture,Dict("type"=>"api_key","key"=>"synthetic-anthropic","validated_at"=>1.0,"model_ids"=>["known"]))
        calls=[]
        events=[Dict("type"=>"message_start","message"=>Dict("id"=>"fixture","model"=>"known")),
            Dict("type"=>"content_block_start","index"=>0,"content_block"=>Dict("type"=>"text","text"=>"fixture answer")),
            Dict("type"=>"content_block_stop","index"=>0),Dict("type"=>"message_delta","delta"=>Dict("stop_reason"=>"end_turn")),Dict("type"=>"message_stop")]
        transport=(url,method,body,headers,context,sink)->begin
            push!(calls,(url,method,body,headers))
            for event in events
                write(sink,"data: "*JSON.json(event)*"\n\n")
            end
            (status=200,body="",reason="")
        end
        descriptor=KeyClient.api_key_provider_descriptor(:fixture,"Fixture";models=[model],endpoint="https://fixture.invalid",
            models_url="https://fixture.invalid/v1/models",protocol=KeyClient.AnthropicMessagesProtocol(),transport)
        provider=descriptor.create(directory)
        context=KeyClient.ExecutionContext()
        request=KeyClient.ModelRequest([Message(:user,"fixture")],"",nothing,nothing,nothing)
        result=KeyClient.respond(provider,request,context)
        @test KeyClient.response_reply(result)==Reply(:answer,"fixture answer")
        @test only(calls)[1]=="https://fixture.invalid/v1/messages?beta=true"
        @test count(pair->first(pair)=="anthropic-version",only(calls)[4])==1
        @test ("x-api-key"=>"synthetic-anthropic") in only(calls)[4]
        @test !occursin("synthetic-anthropic",repr(provider))
        @test isnothing(KeyClient.instantiate_provider(descriptor.create,directory,"missing"))
        close(context)
    end
end
