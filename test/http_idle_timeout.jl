using Test, Downloads, JuliaForever2
const HIT=JuliaForever2.HTTPTransport
@testset "HTTP model idle watchdog is available" begin
    @test isdefined(HIT,:HTTPIdleWatch)
    @test isdefined(HIT,:with_http_idle_timeout)
end
if isdefined(HIT,:HTTPIdleWatch)
@testset "Deterministic headers, body, disabled and consumer pause deadlines" begin
    now=Ref(0.0)
    watch=HIT.HTTPIdleWatch(timeout_ms=30000,clock=()->now[])
    now[]=29; HIT.idle_debug!(watch,"HEADER IN","HTTP/1.1 200 OK\r\n")
    @test !HIT.idle_expired!(watch)
    now[]=30; HIT.idle_debug!(watch,"HEADER IN","X-Partial: yes\r\n")
    @test HIT.idle_expired!(watch)
    @test watch.expired_phase==:headers
    close(watch)
    now[]=0; watch=HIT.HTTPIdleWatch(timeout_ms=30000,clock=()->now[])
    now[]=29; HIT.idle_debug!(watch,"HEADER IN","HTTP/1.1 200 OK\r\n")
    HIT.idle_debug!(watch,"HEADER IN","\r\n")
    now[]=58; HIT.idle_debug!(watch,"DATA IN","first")
    now[]=87; HIT.idle_debug!(watch,"DATA IN","second")
    @test !HIT.idle_expired!(watch)
    @test watch.phase==:body
    now[]=117; @test HIT.idle_expired!(watch)
    @test watch.expired_phase==:body
    close(watch)
    now[]=0; watch=HIT.HTTPIdleWatch(timeout_ms=30000,clock=()->now[])
    HIT.idle_debug!(watch,"HEADER IN","HTTP/1.1 200 OK\r\n"); HIT.idle_debug!(watch,"HEADER IN","\r\n")
    HIT.idle_pause!(watch);now[]=1000
    @test !HIT.idle_expired!(watch)
    HIT.idle_resume!(watch);now[]=1029
    @test !HIT.idle_expired!(watch)
    now[]=1030;@test HIT.idle_expired!(watch)
    close(watch)
    watch=HIT.HTTPIdleWatch(timeout_ms=0,clock=()->now[])
    now[]=1e12; @test !HIT.idle_expired!(watch)
    close(watch); @test watch.closed
    @test isnothing(watch.timer)
end
@testset "Per-request policy is inherited, restored and independent across tasks" begin
    @test HIT.http_idle_timeout_ms()==300000
    HIT.with_http_idle_timeout(30000) do
        @test HIT.http_idle_timeout_ms()==30000
        @test fetch(Threads.@spawn HIT.http_idle_timeout_ms())==30000
        HIT.with_http_idle_timeout(0) do
            @test HIT.http_idle_timeout_ms()==0
        end
        @test HIT.http_idle_timeout_ms()==30000
    end
    @test HIT.http_idle_timeout_ms()==300000
    tasks=[Threads.@spawn HIT.with_http_idle_timeout(()->HIT.http_idle_timeout_ms(),n) for n in (0,30000,60000)]
    @test fetch.(tasks)==[0,30000,60000]
end
@testset "Actual transport ownership with mocked network implementation" begin
    for milliseconds in (0,30000), mode in (:success,:idle,:cancel,:absolute)
        context=ExecutionContext(timeout=10.0);now=Ref(0.0);observed=Ref(0.0)
        requester=function (url;method,input,output,headers,throw,timeout,interrupt,debug,downloader)
            observed[]=timeout
            debug("HEADER OUT","POST / HTTP/1.1\r\n\r\n")
            debug("HEADER IN","HTTP/1.1 200 OK\r\n");debug("HEADER IN","\r\n")
            now[]=29;debug("DATA IN","one");write(output,"one")
            now[]=58;debug("DATA IN","two");write(output,"two")
            if mode==:idle
                now[]=89;debug("TEXT","")
            elseif mode==:cancel
                JuliaForever2.cancel!(context)
            elseif mode==:absolute
                context.deadline=JuliaForever2.monotonic_seconds()-1
            end
            Downloads.Response("https",url,200,"OK",Pair{String,String}[])
        end
        response=HIT.http_request("https://fixture.invalid","POST","",Pair{String,String}[],context;
            timeout=Inf,idle_timeout_ms=milliseconds,clock=()->now[],watch_timer=false,requester)
        @test 0<observed[]<=10
        @test isempty(context.listeners)
        @test all(!r.active for r in context.resources)
        if mode in (:cancel,:absolute)
            @test response.status==0
            @test JuliaForever2.cancelled(context)
        elseif mode==:idle&&milliseconds>0
            @test response.status==0
            @test occursin("body idle timeout",response.reason)
            @test !JuliaForever2.cancelled(context)
        else
            @test response.status==200
            @test response.body=="onetwo"
            @test !JuliaForever2.cancelled(context)
        end
        JuliaForever2.release_context_resources!(context)
    end
end
end

Base.@kwdef struct IdleBoundaryURL <: AbstractString
    options::Vector{Any}=Any[]
end
function HIT.http_request(url::IdleBoundaryURL,method,body,headers,context::ExecutionContext;kwargs...)
    push!(url.options,(;kwargs...))
    (status=200,body="fixture",reason="")
end
@testset "Concrete model boundaries opt in; authentication does not" begin
    url=IdleBoundaryURL();context=ExecutionContext()
    HIT.with_http_idle_timeout(0) do
        JuliaForever2.model_http_transport(url,"POST","",Pair{String,String}[],context,IOBuffer())
        JuliaForever2.openai_request(url,"POST","",Pair{String,String}[],context)
        JuliaForever2.router_request(url,"",Pair{String,String}[],context)
        JuliaForever2.auth_request(url,"",Pair{String,String}[],context)
    end
    @test length(url.options)==4
    @test all(options.timeout==Inf&&options.idle_timeout_ms==0 for options in url.options[1:3])
    @test url.options[4]==(timeout=60.0,)
    JuliaForever2.release_context_resources!(context)
end
@testset "Exception and transport-error cleanup remains owned and bounded" begin
    for failure in (:exception,:response)
        context=ExecutionContext()
        requester=function(url;kwargs...)
            failure==:exception&&error("fixture request error")
            Downloads.RequestError(url,7,"fixture connection error",Downloads.Response(nothing,url,0,"",Pair{String,String}[]))
        end
        if failure==:exception
            @test_throws ErrorException HIT.http_request("https://fixture.invalid","GET","",Pair{String,String}[],context;idle_timeout_ms=30000,requester)
            watches=[resource.value for resource in context.resources if resource.value isa HIT.HTTPIdleWatch]
            @test length(watches)==1
            JuliaForever2.release_context_resources!(context)
            @test all(watch.closed&&isnothing(watch.timer) for watch in watches)
        else
            response=HIT.http_request("https://fixture.invalid","GET","",Pair{String,String}[],context;idle_timeout_ms=30000,requester)
            @test response.status==0
            @test response.reason=="fixture connection error"
            @test all(!resource.active for resource in context.resources)
            JuliaForever2.release_context_resources!(context)
        end
        @test isempty(context.listeners)
        @test isempty(context.resources)
    end
end

@testset "Original client/parser timeout transitions over fixture-only sockets" begin
    original=JuliaForever2.parse_json(read(joinpath(@__DIR__,"fixtures/pi-http-idle.json"),String))
    @test original["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    @test length(original["sourceHashes"])==513
    @test length(original["cases"])==20
    for fixture in original["cases"]
        now=Ref(0.0);watch=HIT.HTTPIdleWatch(timeout_ms=fixture["timeoutMs"],clock=()->now[])
        pending="";headers=true
        for step in fixture["steps"]
            action=step["action"]
            if action["type"]=="advance"
                now[]+=action["milliseconds"]/1000
                HIT.idle_expired!(watch)
            else
                pending*=action["text"]
                if headers
                    line=findfirst("\r\n",pending)
                    while !isnothing(line)&&headers
                        text=pending[1:last(line)]
                        pending=pending[nextind(pending,last(line)):end]
                        HIT.idle_debug!(watch,"HEADER IN",text)
                        headers=text!="\r\n"
                        line=findfirst("\r\n",pending)
                    end
                end
                if !headers&&!isempty(pending)
                    HIT.idle_debug!(watch,"DATA IN",pending)
                    pending=""
                end
            end
            outcome=last(step["events"])
            expired=outcome["kind"]=="error"
            @test watch.expired==expired
            if expired
                @test outcome["code"]==(watch.expired_phase==:headers ? "UND_ERR_HEADERS_TIMEOUT" : "UND_ERR_BODY_TIMEOUT")
            end
        end
        close(watch)
    end
end

@testset "Connect time remains separate from the idle clock" begin
    now=Ref(0.0);watch=HIT.HTTPIdleWatch(timeout_ms=30000,clock=()->now[],armed=false)
    now[]=1000;@test !HIT.idle_expired!(watch)
    HIT.idle_debug!(watch,"HEADER OUT","GET / HTTP/1.1\r\n\r\n")
    now[]=1029;@test !HIT.idle_expired!(watch)
    now[]=1030;@test HIT.idle_expired!(watch)
    close(watch)
end
@testset "Real Downloads adapter and wrapped sink use fixture files only" begin
    mktempdir() do directory
        path=joinpath(directory,"response.txt");write(path,"fixture bytes\n")
        context=ExecutionContext(timeout=10.0)
        response=HIT.http_request("file://"*path,"GET","",Pair{String,String}[],context;
            timeout=Inf,idle_timeout_ms=30000)
        @test response.body=="fixture bytes\n"
        @test isempty(response.reason)
        @test isempty(context.listeners)
        @test all(!r.active for r in context.resources)
        JuliaForever2.release_context_resources!(context)
    end
end

@testset "Closing request ownership interrupts even a disabled idle clock" begin
    context=ExecutionContext();entered=Channel{Bool}(1)
    requester=function(url;interrupt,kwargs...)
        put!(entered,true)
        wait(interrupt)
        Downloads.RequestError(url,42,"fixture owned request interrupted",Downloads.Response(nothing,url,0,"",Pair{String,String}[]))
    end
    worker=@async HIT.http_request("https://fixture.invalid","GET","",Pair{String,String}[],context;
        timeout=Inf,idle_timeout_ms=0,requester)
    @test take!(entered)
    JuliaForever2.release_context_resources!(context)
    response=fetch(worker)
    @test response.status==0
    @test response.reason=="fixture owned request interrupted"
    @test isempty(context.listeners)
end
