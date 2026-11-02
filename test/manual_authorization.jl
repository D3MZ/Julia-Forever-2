using Test, JuliaForever2, JSON, Sockets
const ManualAuthJF = JuliaForever2

@testset "Private manual callback validates exact active attempt" begin
    attempt = ManualAuthJF.oauth_attempt(:chatgpt,"http://127.0.0.1:15445/auth/callback";client_id="fixture-client")
    good=string(attempt.redirect_uri,"?code=fixture-code&state=",attempt.state,"&client_id=fixture-client")
    @test ManualAuthJF.manual_auth_callback(attempt,good).ok
    @test ManualAuthJF.manual_auth_callback(attempt,"  "*good*"  ").ok
    for bad in (replace(good,"15445"=>"15446"),replace(good,"127.0.0.1"=>"localhost"),replace(good,"http:"=>"https:"),replace(good,"/auth/callback"=>"/auth/callback/"),replace(good,attempt.state=>"other"),replace(good,"fixture-client"=>"other"),good*"&state=duplicate",good*"#fragment",good*"\nencoded",good*"&extra=%XX",good*"&extra="*"x"^8192,"fixture-code")
        @test !ManualAuthJF.manual_auth_callback(attempt,bad).ok
    end
    flow=ManualAuthJF.AuthFlow()
    @test !ManualAuthJF.manual_auth_available(flow)
    @test !ManualAuthJF.submit_auth_callback!(flow,good).ok
    @test ManualAuthJF.begin_auth_callback!(flow,attempt,30)
    @test !ManualAuthJF.begin_auth_callback!(flow,attempt,30)
    @test ManualAuthJF.manual_auth_available(flow)
    @test !ManualAuthJF.submit_auth_callback!(flow,"bad").ok
    @test ManualAuthJF.manual_auth_available(flow)
    @test ManualAuthJF.submit_auth_callback!(flow,good).ok
    @test !ManualAuthJF.manual_auth_available(flow)
    @test !ManualAuthJF.submit_auth_callback!(flow,good).ok
    @test ManualAuthJF.claim_auth_callback!(flow,ManualAuthJF.rejectedcallback("later")).code=="fixture-code"
    @test !occursin("fixture",sprint(show,flow))
    @test !occursin(attempt.state,sprint(show,flow.inbox))
    ManualAuthJF.cancel_auth!(flow)
    @test isnothing(ManualAuthJF.received_auth_callback(flow))
    @test !ManualAuthJF.claim_auth_callback!(flow,ManualAuthJF.rejectedcallback("later")).ok
    expired=ManualAuthJF.AuthFlow()
    ManualAuthJF.begin_auth_callback!(expired,attempt,0)
    @test !ManualAuthJF.submit_auth_callback!(expired,good).ok
    close(expired)
end

@testset "Manual callback reaches the same guarded native exchange" begin
    for outcome in (:success,:denied,:cancel,:timeout,:exchange_failure)
        mktempdir() do dir
            flow=ManualAuthJF.AuthFlow()
            exchanges=Ref(0)
            submitted=Ref(false)
            opener=url->begin
                params=ManualAuthJF.callback_params("/auth?"*split(url,'?';limit=2)[2]).values
                callback=params["callback_url"]
                input=callback*"?state="*params["state"]*(outcome==:denied ? "&error=access_denied" : "&code=fixture-code")
                if outcome==:cancel
                    ManualAuthJF.cancel_auth!(flow)
                elseif outcome!=:timeout
                    submitted[]=ManualAuthJF.submit_auth_callback!(flow,input).ok
                end
                true
            end
            transport=(url,body,headers)->begin
                exchanges[]+=1
                @test occursin("fixture-code",body)
                (status=outcome==:exchange_failure ? 400 : 200,body=JSON.json(Dict("key"=>"fixture-key")))
            end
            result=ManualAuthJF.sign_in!(flow,:openrouter,dir;opener,transport,timeout=outcome==:timeout ? 0.1 : 3.0)
            @test result.ok==(outcome==:success)
            @test exchanges[]==(outcome in (:success,:exchange_failure) ? 1 : 0)
            @test submitted[]==(outcome in (:success,:denied,:exchange_failure))
            @test isnothing(flow.listener) && isnothing(flow.inbox)
            @test !ManualAuthJF.manual_auth_available(flow)
            @test (ManualAuthJF.load_credentials(dir,:openrouter)!==nothing)==(outcome==:success)
        end
    end
end

@testset "Manual input interrupts an already waiting native listener and spare socket" begin
    for spare in (false,true)
        mktempdir() do dir
            flow=ManualAuthJF.AuthFlow();intake=Channel{Any}(1);producer=Ref{Task}()
            opener=url->begin
                params=ManualAuthJF.callback_params("/auth?"*split(url,'?';limit=2)[2]).values
                callback=params["callback_url"]
                port=parse(Int,match(r"127\.0\.0\.1:(\d+)",callback).captures[1])
                producer[]=Threads.@spawn begin
                    socket=spare ? Sockets.connect(ip"127.0.0.1",port) : nothing
                    sleep(0.1)
                    put!(intake,ManualAuthJF.submit_auth_callback!(flow,callback*"?state="*params["state"]*"&code=fixture-code"))
                    isnothing(socket) || close(socket)
                end
                true
            end
            transport=(url,body,headers)->(status=200,body=JSON.json(Dict("key"=>"fixture-key")))
            started=time()
            result=ManualAuthJF.sign_in!(flow,:openrouter,dir;opener,transport,timeout=3)
            @test result.ok
            @test take!(intake).ok
            wait(producer[])
            @test time()-started<2
            @test isnothing(flow.inbox) && isnothing(flow.listener)
        end
    end
end

@testset "Native callback prevents second manual exchange" begin
    attempt=ManualAuthJF.oauth_attempt(:chatgpt,"http://127.0.0.1:15445/auth/callback";client_id="fixture-client")
    url=attempt.redirect_uri*"?state="*attempt.state*"&code=first&client_id=fixture-client"
    flow=ManualAuthJF.AuthFlow();ManualAuthJF.begin_auth_callback!(flow,attempt,5)
    native=ManualAuthJF.manual_auth_callback(attempt,url)
    @test ManualAuthJF.claim_auth_callback!(flow,native).code=="first"
    @test !ManualAuthJF.submit_auth_callback!(flow,replace(url,"code=first"=>"code=second")).ok
    @test ManualAuthJF.received_auth_callback(flow).code=="first"
    close(flow)
    @test isnothing(flow.inbox)
end

@testset "Original manual callback parser agrees within native security constraints" begin
    original=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-manual-callback.json"))
    stricter=Set(["duplicate-code","duplicate-state","duplicate-client","fragment","userinfo","path-normalization","embedded-control","oversized-code"])
    for case in original["cases"]
        attempt=ManualAuthJF.OAuthAttempt(:chatgpt,case["redirect"],case["expectedState"],"fixture-verifier","fixture-nonce","fixture-host","")
        native=ManualAuthJF.manual_auth_callback(attempt,case["input"])
        if case["id"] in stricter
            @test case["result"]["ok"] && !native.ok
        else
            @test native.ok==case["result"]["ok"]
            if native.ok
                @test native.code==case["result"]["code"]
                @test native.client_id==case["result"]["clientId"]
            end
        end
    end
end

@testset "Concurrent start and failed browser action retain single-writer cleanup" begin
    mktempdir() do dir
        flow=ManualAuthJF.AuthFlow();url_ready=Channel{String}(1)
        transport=(url,body,headers)->(status=200,body=JSON.json(Dict("key"=>"fixture-key")))
        operation=Threads.@spawn ManualAuthJF.sign_in!(flow,:openrouter,dir;opener=url->put!(url_ready,url),transport,timeout=5)
        url=take!(url_ready)
        params=ManualAuthJF.callback_params("/auth?"*split(url,'?';limit=2)[2]).values
        listener=flow.listener
        duplicate=ManualAuthJF.sign_in!(flow,:openrouter,dir;opener=url->error("Must not reopen browser"),timeout=1)
        @test !duplicate.ok
        @test flow.listener===listener && ManualAuthJF.manual_auth_available(flow)
        input=params["callback_url"]*"?code=fixture-code&state="*params["state"]
        @test ManualAuthJF.submit_auth_callback!(flow,input).ok
        @test fetch(operation).ok
        @test isnothing(flow.listener) && isnothing(flow.inbox)
    end
    mktempdir() do dir
        flow=ManualAuthJF.AuthFlow()
        failed=Threads.@spawn ManualAuthJF.sign_in!(flow,:openrouter,dir;opener=url->error("Synthetic browser failure"))
        wait(failed;throw=false)
        @test istaskfailed(failed)
        @test isnothing(flow.listener) && isnothing(flow.inbox)
        @test isnothing(ManualAuthJF.load_credentials(dir,:openrouter))
    end
end
