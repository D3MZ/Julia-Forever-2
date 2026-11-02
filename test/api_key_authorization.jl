using Test,JuliaForever2,JSON
const KeyCore=JuliaForever2
function key_fixture(action;validator=(id,key,ctx)->KeyCore.APIKeyValidation(;ok=true,model_ids=["fixture-model"]))
    mktempdir() do directory
        method=KeyCore.APIKeyAuthMethod(;provider=:fixture,name="Fixture API key",validate=validator)
        flow=KeyCore.AuthFlow(;timeout=120)
        ready=Channel{Nothing}(1)
        task=@async method(flow,:fixture,directory;notify=()->put!(ready,nothing))
        ready_state=timedwait(()->isready(ready) || istaskdone(task),125)
        ready_state==:ok && isready(ready) || error("Fixture auth prompt did not become ready")
        take!(ready)
        action(method,flow,task,directory)
        KeyCore.cancel_auth!(flow)
        wait(task)
        close(flow)
    end
end
@testset "Native private key receipt is not validation or persistence" begin
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    validator=(id,key,context)->begin
        put!(entered,nothing);take!(release)
        KeyCore.APIKeyValidation(;ok=true,model_ids=["fixture-model"])
    end
    key_fixture(;validator) do method,flow,task,directory
        @test KeyCore.api_key_request_status(method,flow).prompt=="Enter Fixture API key"
        @test KeyCore.submit_api_key!(method,flow,"synthetic-key").ok
        timedwait(()->isready(entered) || istaskdone(task),10)==:ok && isready(entered) || error("Validator did not start")
        take!(entered)
        @test !isfile(joinpath(directory,"fixture.json"))
        @test !occursin("synthetic-key",repr(method))
        @test !occursin("synthetic-key",repr(first(values(method.requests))))
        @test !KeyCore.submit_api_key!(method,flow,"second-key").ok
        put!(release,nothing)
        timedwait(()->istaskdone(task),10)==:ok || error("Auth operation did not finish")
        @test fetch(task)==(ok=true,reason="API key validated and saved.")
        saved=JSON.parsefile(joinpath(directory,"fixture.json"))
        @test saved["key"]=="synthetic-key"
        @test saved["model_ids"]==["fixture-model"]
        @test stat(joinpath(directory,"fixture.json")).mode & 0o777 == 0o600
        @test isempty(method.requests)
    end
end
@testset "Cancellation, rejected keys, unsafe input and validator errors never save credentials" begin
    for scenario in (:cancel,:reject,:error,:emptycatalog)
        validator=(id,key,context)->scenario==:error ? error(key) : KeyCore.APIKeyValidation(;ok=scenario==:emptycatalog,reason=:rejected)
        key_fixture(;validator) do method,flow,task,directory
            for invalid in ("","bad key","bad\nkey",repeat("x",8193))
                @test !KeyCore.submit_api_key!(method,flow,invalid).ok
            end
            if scenario==:cancel
                KeyCore.cancel_auth!(flow)
            else
                @test KeyCore.submit_api_key!(method,flow,"synthetic-private-value").ok
            end
            timedwait(()->istaskdone(task),10)==:ok || error("Auth operation did not finish")
        result=fetch(task)
            @test !result.ok
            @test !occursin("synthetic-private-value",repr(result))
            @test !isfile(joinpath(directory,"fixture.json"))
            @test isempty(method.requests)
        end
    end
end
@testset "An intervening credential writer prevents replacement after validation" begin
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    validator=(id,key,context)->begin
        put!(entered,nothing);take!(release)
        KeyCore.APIKeyValidation(;ok=true,model_ids=["fixture-model"])
    end
    key_fixture(;validator) do method,flow,task,directory
        @test KeyCore.submit_api_key!(method,flow,"candidate-key").ok
        timedwait(()->isready(entered) || istaskdone(task),10)==:ok && isready(entered) || error("Validator did not start")
        take!(entered)
        KeyCore.save_credentials!(directory,:fixture,Dict("key"=>"new-owner-key"))
        put!(release,nothing)
        timedwait(()->istaskdone(task),10)==:ok || error("Auth operation did not finish")
        result=fetch(task)
        @test !result.ok
        @test occursin("changed",result.reason)
        @test JSON.parsefile(joinpath(directory,"fixture.json"))["key"]=="new-owner-key"
    end
end
