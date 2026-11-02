@testset "Footer owner lifecycle, unknown facts and no render I/O" begin
    mktempdir() do directory
        model=JuliaForever2.ModelSpec(:fixture,"selected";metadata=Dict("reasoning"=>true,"contextWindow"=>1000,"subscription"=>true))
        calls=Ref(0)
        backend=JuliaForever2.HTTPModelBackend(JuliaForever2.OpenAIChatProtocol(),"https://not-called.invalid";credentials=()->(calls[]+=1;Pair{String,String}[]))
        provider=JuliaForever2.ConfiguredModelProvider(JuliaForever2.ModelProvider(model,backend),model,"high")
        kernel=JuliaForever2.default_kernel(provider)
        app=FooterHost.App(JuliaForever2.Session(kernel;working_directory=directory);settings_dir=joinpath(directory,"config"),registry=JuliaForever2.ProviderRegistry(),theme_fallback="dark")
        state=FooterHost.FooterHostState()
        FooterHost.refresh_footer_controls!(app,state;models=[model],home=directory)
        initial=FooterHost.footer_control_snapshot(app,state)
        @test initial.model.id=="selected" && initial.thinking=="high"
        @test !initial.subscription && isempty(initial.statuses)
        @test initial.context.percent==0.0
        timeline=app.archive.timeline
        JuliaForever2.timeline_append_message!(timeline,Dict("role"=>"assistant","content"=>Any[Dict("type"=>"text","text"=>"not metered")]);id="unknown")
        unknown=FooterHost.footer_control_snapshot(app,state)
        @test "Usage unreported" in last.(unknown.statuses)
        JuliaForever2.timeline_append_message!(timeline,Dict("role"=>"assistant","content"=>Any[],"usage"=>Dict("input"=>0,"output"=>0));id="partial")
        partial=FooterHost.footer_control_snapshot(app,state)
        @test "Usage partial" in last.(partial.statuses)
        @test "Cost unknown" in last.(partial.statuses)
        @test partial.accounting.usage.input==0
        replacement=JuliaForever2.SessionTimeline(directory;id="replacement")
        JuliaForever2.timeline_append_message!(replacement,Dict("role"=>"assistant","content"=>Any[],"usage"=>Dict("input"=>0,"output"=>0,"cacheRead"=>0,"cacheWrite"=>0,"cost"=>Dict("total"=>0)),"stopReason"=>"stop");id="knownzero")
        before=state.scans
        app.archive.timeline=replacement
        zero=FooterHost.footer_control_snapshot(app,state)
        @test state.scans==before+1 && isempty(zero.statuses)
        @test zero.accounting.usage.cost==0 && zero.context.percent==0.0
        FooterHost.refresh_footer_controls!(app,state;subscriptions=Dict(:fixture=>true))
        @test FooterHost.footer_control_snapshot(app,state).subscription
        FooterHost.refresh_footer_controls!(app,state;subscriptions=Dict(:fixture=>false))
        @test !FooterHost.footer_control_snapshot(app,state).subscription
        other=JuliaForever2.ModelSpec(:other,"other";metadata=Dict("reasoning"=>false,"contextWindow"=>2000))
        FooterHost.refresh_footer_controls!(app,state;models=[model,other])
        @test FooterHost.footer_control_snapshot(app,state).available_providers==2
        app.menus.enabled_models=["other/other"]
        @test FooterHost.footer_control_snapshot(app,state).available_providers==1
        JuliaForever2.install!(kernel,JuliaForever2.ComponentSpec(:provider,JuliaForever2.ModelProvider(other,Returns(nothing))))
        replaced=FooterHost.footer_control_snapshot(app,state)
        @test replaced.model.id=="other" && !replaced.model.reasoning && replaced.model.context_window==2000
        @test replaced.thinking===nothing && !replaced.subscription
        app.status="Cancelled"
        @test "Cancelled" in last.(FooterHost.footer_control_snapshot(app,state).statuses)
        chatgpt=JuliaForever2.OpenAIProvider(directory,(args...)->(calls[]+=1),(args...)->(calls[]+=1))
        chatgpt.catalog.models=["wrong-first","actual-selected"]
        chatgpt.catalog.selected_model="actual-selected"
        auth=FooterHost.footer_control_model(chatgpt,state)
        @test auth.model.id=="actual-selected" && auth.auth_unknown && !auth.subscription
        state.subscriptions[:chatgpt]=true
        @test FooterHost.footer_control_model(chatgpt,state).subscription
        state.subscriptions[:chatgpt]=false
        @test !FooterHost.footer_control_model(chatgpt,state).auth_unknown
        @test calls[]==0
        app.archive.timeline=nothing
        absent=FooterHost.footer_control_snapshot(app,state)
        @test "Usage unreported" in last.(absent.statuses)
        @test absent.context.percent===nothing
        close(app.session);close(kernel)
    end
end
