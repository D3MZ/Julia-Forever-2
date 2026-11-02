using Test,JuliaForever2,Tachikoma,CommonMark,JSON,SHA
const MCT=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
function markdown_continuation_oracle()
    corpus=joinpath(@__DIR__,"../parity/fixtures/pi_markdown_continuations_corpus.json")
    original=get(ENV,"PI_SOURCE_ROOT","")
    if isempty(original)
        JSON.parsefile(joinpath(@__DIR__,"../parity/fixtures/pi_markdown_continuations.json"))
    else
        mktemp() do path,io
            close(io)
            run(`node $(joinpath(@__DIR__,"../parity/pi_markdown_fences_oracle.mjs")) $corpus $path`)
            JSON.parsefile(path)
        end
    end
end

@testset "Actual framed Markdown continuations, lists, Unicode and SQL" begin
    previous=MCT.ACTIVE_NATIVE_THEME[];previous_native=Tachikoma.theme()
    MCT.activate_theme_runtime!(MCT.ThemeRuntime(MCT.theme_catalog("";preserve_extras=false);setting="dark"))
    capture=markdown_continuation_oracle()
    @test occursin("Actual TUI.applyLineResets",capture["framing"])
    @test capture["dependencyHashes"]["highlight.js/lib/languages/sql.js"]=="bf56c9b66bea17ebfb891fb59fa165328468f79d03a60ecbed068c6cad351590"
    for frame in capture["snapshots"]
        rows=markdown_block_fixture(capture,frame)
        @testset "$(frame["id"]) @ $(frame["width"])" begin
            @test length(rows)==frame["rowCount"]
            @test markdown_block_digest(rows,Int(frame["width"]))==frame["cellsSha256"]
        end
    end
    for glyph in ("界","漢","ー","か","カ","한","ㄅ")
        @test MCT.session_display_cjk(glyph)
    end
    for glyph in ("A","λ","🙂"," ")
        @test !MCT.session_display_cjk(glyph)
    end
    @test MCT.session_sql_word_kind("NuLlIf","NuLlIf (value)",7)==:type
    @test MCT.session_sql_word_kind("nullif","nullif",7)==:default
    @test MCT.session_sql_word_kind("value","value",6)==:keyword
    @test MCT.session_sql_word_kind("value_name","value_name",11)==:default
    @test MCT.session_sql_word_kind("UNKNOWN","UNKNOWN",8)==:number
    MCT.ACTIVE_NATIVE_THEME[]=previous;Tachikoma.set_theme!(previous_native)
    @test MCT.ACTIVE_NATIVE_THEME[]===previous
    @test Tachikoma.theme()===previous_native
end

struct MarkdownProgressProvider
    fragments::Vector{String}
    started::Channel{Int}
    proceed::Channel{Nothing}
end
function JuliaForever2.respond(provider::MarkdownProgressProvider,request::JuliaForever2.ModelRequest,context::JuliaForever2.ExecutionContext)
    for (index,text) in enumerate(provider.fragments)
        JuliaForever2.emit_protocol_progress!(JuliaForever2.CodeModePolicy(),JSON.json((kind="answer",content=text)),context)
        put!(provider.started,index)
        take!(provider.proceed)
    end
    JuliaForever2.ProviderResult(JuliaForever2.Reply(:answer,last(provider.fragments)),nothing)
end
function markdown_progress_ansi(row)
    sprint() do io
        for span in row
            print(io,"\e[0m");Tachikoma.write_style(io,span.style);print(io,span.content)
        end
        print(io,"\e[0m")
    end
end

function markdown_progress_drain!(app)
    while isready(app.queue.channel)
        Tachikoma.update!(app,take!(app.queue.channel))
    end
    nothing
end

@testset "Actual App streaming preview and commit use identical native Markdown cells" begin
    previous=MCT.ACTIVE_NATIVE_THEME[];previous_native=Tachikoma.theme()
    capture=JSON.parsefile(joinpath(@__DIR__,"../parity/fixtures/pi_markdown_continuations.json"))
    cases=filter(item->startswith(item["id"],"stream-quote-sql/"),capture["cases"])
    provider=MarkdownProgressProvider(String[item["text"] for item in cases],Channel{Int}(1),Channel{Nothing}(1))
    evidence=Dict{String,Any}[]
    commit=Dict{String,Any}()
    mktempdir() do directory
        write(joinpath(directory,"terminal-settings.json"),JSON.json(Dict("quiet-startup"=>true,"theme"=>"dark")))
        kernel=JuliaForever2.default_kernel(provider)
        app=MCT.App(JuliaForever2.Session(kernel;working_directory=directory);settings_dir=directory)
        handle=MCT.submit!(app,"Render the fixture")
        for (index,fixture) in enumerate(cases)
            ready=timedwait(()->isready(provider.started),30)
            @test ready==:ok
            ready==:ok || error("Provider fixture did not emit expected progress")
            @test take!(provider.started)==index
            markdown_progress_drain!(app)
            @test app.transcript.preview.text==fixture["text"]
            @test count(message->message.role==:assistant,app.session.messages)==0
            for width in (40,20,100)
                frame=only(filter(frame->frame["fixture"]==fixture["id"]&&frame["kind"]=="markdown"&&frame["width"]==width,capture["snapshots"]))
                rows=MCT.startup_preview_rows(app,width)
                @test length(rows)==frame["rowCount"]+1
                @test markdown_block_digest(rows[1:end-1],width)==frame["cellsSha256"]
                push!(evidence,Dict("id"=>frame["id"],"width"=>width,"input"=>"Actual protocol progress update $(index)","streaming"=>true,"ansiLines"=>markdown_progress_ansi.(rows[1:end-1]),"previewText"=>app.transcript.preview.text,"committedAssistantCount"=>count(message->message.role==:assistant,app.session.messages)))
            end
            put!(provider.proceed,nothing)
        end
        @test timedwait(()->begin
            markdown_progress_drain!(app)
            isnothing(app.operations.active)
        end,30)==:ok
        @test isnothing(app.transcript.preview)
        @test count(message->message.role==:assistant&&message.content==last(provider.fragments),app.session.messages)==1
        @test isempty(MCT.startup_preview_rows(app,40))
        entries=JuliaForever2.timeline_entries(app.archive.timeline)
        saved=only([entry["message"] for entry in entries if get(entry,"type",nothing)=="message" && get(entry["message"],"role",nothing)=="assistant"])
        @test saved["content"]==[Dict("type"=>"text","text"=>last(provider.fragments))]
        for width in (40,20,100)
            frame=only(filter(frame->frame["fixture"]==last(cases)["id"]&&frame["kind"]=="assistant"&&frame["width"]==width,capture["snapshots"]))
            rows=MCT.session_display_assistant(saved,width,app.transcript.display)
            @test length(rows)==frame["rowCount"]
            @test markdown_block_digest(rows,width)==frame["cellsSha256"]
            push!(evidence,Dict("id"=>frame["id"],"width"=>width,"input"=>"Actual completed operation and durable archive readback","streaming"=>false,"ansiLines"=>markdown_progress_ansi.(rows),"committedAssistantCount"=>count(message->message.role==:assistant,app.session.messages)))
        end
        merge!(commit,Dict("previewCleared"=>isnothing(app.transcript.preview),"assistantCount"=>count(message->message.role==:assistant,app.session.messages),"activeCleared"=>isnothing(app.operations.active)))
        MCT.cleanup!(app);close(app.session);close(kernel)
    end
    path=get(ENV,"JF2_MARKDOWN_APP_CAPTURE","")
    isempty(path) || write(path,JSON.json(Dict("scope"=>"Actual supervised App protocol updates and Buffer-rendered preview; deterministic provider, no network", "snapshots"=>evidence,"commit"=>commit)))
    MCT.ACTIVE_NATIVE_THEME[]=previous;Tachikoma.set_theme!(previous_native)
end
