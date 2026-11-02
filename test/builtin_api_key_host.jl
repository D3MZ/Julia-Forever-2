using Test,JuliaForever2,Tachikoma,CommonMark,JSON
const BuiltinKeyHost=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
function builtin_key_drain!(app)
    timedwait(15;pollint=0.002) do
        while isready(app.queue.channel)
            Tachikoma.update!(app,take!(app.queue.channel))
        end
        !app.busy && all(istaskdone,app.operations.watchers)
    end
end
function builtin_key_fixture_reply!(id,sink,model)
    text=JSON.json(Dict("kind"=>"answer","content"=>"Harmless local fixture reply"))
    if id==:groq
        write(sink,"data: "*JSON.json(Dict("choices"=>[Dict("delta"=>Dict("content"=>text),"finish_reason"=>"stop")]))*"\n\n")
        write(sink,"data: [DONE]\n\n")
    else
        events=[Dict("type"=>"message_start","message"=>Dict("id"=>"fixture","model"=>model)),
            Dict("type"=>"content_block_start","index"=>0,"content_block"=>Dict("type"=>"text","text"=>text)),
            Dict("type"=>"content_block_stop","index"=>0),Dict("type"=>"message_delta","delta"=>Dict("stop_reason"=>"end_turn")),Dict("type"=>"message_stop")]
        for event in events
            write(sink,"data: "*JSON.json(event)*"\n\n")
        end
    end
    nothing
end
@testset "Actual built-in native host login, model/thinking selection, replies, archive and logout" begin
    for (id,model_id) in ((:groq,"openai/gpt-oss-120b"),(:anthropic,"claude-haiku-5-5"))
        mktempdir() do directory
            calls=[]
            catalog=JuliaForever2.builtin_api_key_catalog(id)
            transport=(url,method,body,headers,context,sink)->begin
                push!(calls,(url,method,payload=isempty(body) ? nothing : JSON.parse(body),headers))
                if method=="GET"
                    (status=200,body=JSON.json(Dict("data"=>[Dict("id"=>m.id) for m in catalog],"has_more"=>false)),reason="")
                else
                    builtin_key_fixture_reply!(id,sink,model_id)
                    (status=200,body="",reason="")
                end
            end
            registry=JuliaForever2.builtin_provider_registry()
            descriptor=JuliaForever2.builtin_api_key_descriptor(id;transport)
            JuliaForever2.register_provider!(registry,descriptor)
            app=BuiltinKeyHost.App(;settings_dir=directory,registry)
            @test !(id in BuiltinKeyHost.configured_model_providers(app))
            before=deepcopy(app.transcript.lines)
            BuiltinKeyHost.dispatch!(app,"/login "*String(id))
            flow=app.settings.auth_flow
            @test flow isa JuliaForever2.AuthFlow
            @test timedwait(()->JuliaForever2.api_key_request_status(descriptor.auth,flow).available || istaskdone(app.settings.auth_task),15)==:ok
            BuiltinKeyHost.page_input!(app,Val(:auth),Tachikoma.KeyEvent(:char,'x'),Vector{UInt8}(codeunits("SYNTHETIC_NOT_A_REAL_KEY")))
            text=join(join(span.content for span in line) for line in BuiltinKeyHost.auth_dialog_layout(app,app.menus.auth_menu_control,80).lines)
            @test !occursin("SYNTHETIC",text)
            BuiltinKeyHost.page_input!(app,Val(:auth),Tachikoma.KeyEvent(:enter))
            @test builtin_key_drain!(app)==:ok
            @test app.transcript.lines==before
            @test id in BuiltinKeyHost.configured_model_providers(app)
            @test JuliaForever2.provider_id(JuliaForever2.component(app.session.kernel,:provider))==:demo
            BuiltinKeyHost.dispatch!(app,"/model "*String(id)*"/"*model_id)
            @test builtin_key_drain!(app)==:ok
            @test JuliaForever2.provider_model_identity(JuliaForever2.component(app.session.kernel,:provider)).model_id==model_id
            BuiltinKeyHost.dispatch!(app,"/thinking low")
            @test builtin_key_drain!(app)==:ok
            @test JuliaForever2.current_thinking_level(JuliaForever2.component(app.session.kernel,:provider))=="low"
            first=run_turn!(app.session,"First harmless fixture question")
            @test first.ok
            @test first.text=="Harmless local fixture reply"
            BuiltinKeyHost.dispatch!(app,"/thinking high")
            @test builtin_key_drain!(app)==:ok
            second=run_turn!(app.session,"Second harmless fixture question")
            @test builtin_key_drain!(app)==:ok
            @test second.ok
            @test second.text=="Harmless local fixture reply"
            @test length(calls)==3
            if id==:anthropic
                @test ("anthropic-beta"=>"mid-conversation-output-config-2026-07-01,thinking-binding-controls-2026-08-01") in last(calls).headers
                markers=[message["output_config"]["effort"] for message in last(calls).payload["messages"] if haskey(message,"output_config")]
                @test markers==["low","high"]
                archived=JuliaForever2.timeline_context(app.archive.timeline)
                assistants=filter(message->get(message,"role",nothing)=="assistant",archived.messages)
                @test [message["providerThinkingLevel"] for message in assistants]==["low","high"]
                restored=JuliaForever2.timeline_runtime_messages(app.archive.timeline)
                request=JuliaForever2.model_request(JuliaForever2.CodeModePolicy(),restored)
                provider=JuliaForever2.component(app.session.kernel,:provider)
                backend=provider.backend.backend
                options=JuliaForever2.model_request_options(backend.options,provider.model,request)
                payload=JuliaForever2.model_payload(backend.protocol,provider.model,request,options)
                @test [message["output_config"]["effort"] for message in payload["messages"] if haskey(message,"output_config")]==["low","high","high"]
                @test !occursin("providerThinkingLevel",JuliaForever2.wire_content(last(restored)))
            end
            provider=JuliaForever2.component(app.session.kernel,:provider)
            BuiltinKeyHost.open_menu!(app,"logout")
            BuiltinKeyHost.start_logout!(app,String(id))
            @test builtin_key_drain!(app)==:ok
            @test !(id in BuiltinKeyHost.configured_model_providers(app))
            @test !isfile(joinpath(directory,String(id)*".json"))
            context=ExecutionContext()
            @test_throws ErrorException JuliaForever2.respond(provider,JuliaForever2.ModelRequest([Message(:user,"fixture")],"",nothing,nothing,nothing),context)
            @test length(calls)==3
            close(context)
            BuiltinKeyHost.finish_shutdown!(app)
            close(app.session.kernel)
        end
    end
end
