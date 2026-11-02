using Test, JuliaForever2, Tachikoma, CommonMark, JSON
const HostReviewTerminal = Base.get_extension(JuliaForever2, :JuliaForever2TerminalExt)
const HostReviewCore = JuliaForever2

function host_review_app(directory; messages=Message[])
    calls = Ref(0)
    transport = (args...) -> (calls[] += 1; error("Unexpected external call in host fixture"))
    current = HostReviewCore.OpenAIProvider(directory, transport, transport; model="old", reasoning="low")
    models = [HostReviewCore.ModelSpec(:chatgpt, id; api="openai-responses",
        metadata=Dict("reasoning" => true, "contextWindow" => 128000)) for id in ("old", "new")]
    factory = HostReviewCore.ProviderFactory(Returns(current); models=Returns(models),
        select=(directory, id) -> HostReviewCore.OpenAIProvider(current, id))
    registry = HostReviewCore.ProviderRegistry()
    HostReviewCore.register_provider!(registry, HostReviewCore.ProviderDescriptor(:chatgpt, "Fixture", factory))
    app = HostReviewTerminal.App(Session(HostReviewCore.default_kernel(current); messages); settings_dir=directory, registry)
    (app, calls, current)
end

function host_review_finish!(app)
    kernel = app.session.kernel
    HostReviewTerminal.finish_shutdown!(app)
    close(kernel)
end

@testset "Terminal model-default submenu saves only durable defaults" begin
    mktempdir() do directory
        app, calls, current = host_review_app(directory)
        before = HostReviewCore.timeline_entries(app.archive.timeline)
        provider = HostReviewCore.component(app.session.kernel, :provider)
        HostReviewTerminal.open_menu!(app, "settings")
        Tachikoma.set_text!(app.menus.search, "Default thinking level per model")
        HostReviewTerminal.activate_setting!(app)
        menu = app.menus.thinking_defaults_menu
        @test HostReviewTerminal.thinking_defaults_active(app)
        @test !isnothing(menu)
        menu.cursor = findfirst(index -> menu.items[index].value == "chatgpt/new", menu.filtered)
        HostReviewTerminal.thinking_defaults_input!(menu, "\r")
        menu.cursor = findfirst(index -> menu.items[index].value == "high", menu.filtered)
        HostReviewTerminal.thinking_defaults_input!(menu, "\r")
        stored = JSON.parsefile(HostReviewTerminal.model_settings_path(app))
        @test stored["thinkingDefaults"]["chatgpt/new"] == "high"
        @test HostReviewCore.component(app.session.kernel, :provider) === provider
        @test HostReviewCore.timeline_entries(app.archive.timeline) == before
        @test calls[] == 0
        @test menu.step == :model
        HostReviewTerminal.thinking_defaults_input!(menu, "\e")
        @test app.menus.path == ["settings"]
        @test Tachikoma.text(app.menus.search) == "Default thinking level per model"
        app.busy = true
        rejected = HostReviewTerminal.persist_thinking_default!(app, "chatgpt", "new", "low")
        @test !rejected.ok
        @test JSON.parsefile(HostReviewTerminal.model_settings_path(app)) == stored
        app.busy = false
        removed = HostReviewTerminal.persist_thinking_default!(app, "chatgpt", "new", nothing)
        @test removed.ok
        @test isempty(JSON.parsefile(HostReviewTerminal.model_settings_path(app))["thinkingDefaults"])
        @test HostReviewCore.component(app.session.kernel, :provider) === provider
        @test HostReviewCore.timeline_entries(app.archive.timeline) == before
        host_review_finish!(app)
    end
end

@testset "Terminal host stale model candidates preserve durable history" begin
    mktempdir() do directory
        app, calls, current = host_review_app(directory)
        HostReviewCore.append_message!(app.session, Message(:user, "first"))
        timeline = app.archive.timeline
        snapshot = lock(timeline.lock) do
            (rows=[HostReviewCore.timeline_header(timeline); HostReviewCore.timeline_entries(timeline)],
                leaf=timeline.leaf, digest=timeline.disk_digest, count=length(timeline.entries))
        end
        candidate = HostReviewCore.timeline_from_rows(snapshot.rows; leaf=snapshot.leaf)
        HostReviewCore.timeline_append!(candidate, Dict("type" => "model_change", "provider" => "chatgpt", "modelId" => "new"))
        expected = app.session.kernel.entries[:provider]
        HostReviewCore.append_message!(app.session, Message(:user, "intervening durable message"))
        result = HostReviewTerminal.commit_model_configuration!(app.session.kernel, expected, expected.spec.value,
            timeline, candidate, ExecutionContext(), snapshot)
        restored = HostReviewCore.load_timeline(app.archive.store, timeline.identity.id)
        @test !result.ok
        @test occursin("Session changed", result.reason)
        @test length(HostReviewCore.timeline_messages(restored)) == length(app.session.messages) == 2
        @test app.session.kernel.entries[:provider] === expected
        @test calls[] == 0
        host_review_finish!(app)
    end
end

mutable struct HostReviewFailInitExecutor
    fail::Bool
    closed::Base.RefValue{Bool}
    forked::Base.RefValue{Any}
end
HostReviewCore.initialize_executor!(executor::HostReviewFailInitExecutor, session) = executor.fail ? error("injected initialization failure") : executor
function HostReviewCore.fork_executor(executor::HostReviewFailInitExecutor)
    executor.forked[] = HostReviewFailInitExecutor(true, Ref(false), Ref{Any}(nothing))
end
HostReviewCore.close_executor!(executor::HostReviewFailInitExecutor) = (executor.closed[] = true)

@testset "Terminal runtime construction failure releases all ownership" begin
    mktempdir() do directory
        app, calls, current = host_review_app(directory)
        entry = app.session.kernel.entries[:provider]
        before = entry.users
        timeline = HostReviewCore.SessionTimeline(joinpath(directory, "absent-workspace"))
        @test_throws ErrorException HostReviewTerminal.timeline_runtime(app, timeline)
        @test entry.users == before
        host_review_finish!(app)
    end
    mktempdir() do directory
        kernel = HostReviewCore.default_kernel()
        executor = HostReviewFailInitExecutor(false, Ref(false), Ref{Any}(nothing))
        app = HostReviewTerminal.App(Session(kernel; executor); settings_dir=directory)
        entry = kernel.entries[:provider]
        before = entry.users
        @test_throws TaskFailedException HostReviewTerminal.timeline_runtime(app, HostReviewCore.SessionTimeline(directory))
        @test entry.users == before
        @test executor.forked[].closed[]
        host_review_finish!(app)
    end
end

@testset "Terminal journal failures preserve history without lease leaks" begin
    kernel = Kernel()
    session = Session(kernel)
    HostReviewCore.bind_history_journal!(session, (args...) -> error("injected durability failure"))
    entry = kernel.entries[:history_journals]
    before = entry.users
    @test_throws ErrorException HostReviewCore.append_message!(session, Message(:user, "never committed"))
    @test entry.users == before
    @test isempty(session.messages)
    close(session)
    close(kernel)
end

@testset "Terminal migration preserves preexisting compaction" begin
    mktempdir() do directory
        session = Session(HostReviewCore.default_kernel();
            messages=[Message(:user, "old turn"), Message(:assistant, "old answer"), Message(:user, "current turn")],
            compaction_entry=HostReviewCore.CompactionEntry("retained summary", 3))
        app = HostReviewTerminal.App(session; settings_dir=directory)
        projected = [message.content for message in HostReviewCore.context_messages(session)]
        @test length(projected) == 2
        @test occursin("retained summary", first(projected))
        @test last(projected) == "current turn"
        @test !("old turn" in projected)
        @test length(HostReviewCore.timeline_messages(app.archive.timeline)) == 3
        host_review_finish!(app)
    end
end

@testset "Terminal-created kernel remains owned across session replacement" begin
    mktempdir() do directory
        app = HostReviewTerminal.terminal_app(; settings_dir=directory, registry=HostReviewCore.ProviderRegistry())
        original = app.session.kernel
        disposed = Ref(0)
        install!(original, ComponentSpec(:host_review_resource, nothing; cleanup=value -> (disposed[] += 1)))
        HostReviewTerminal.session_action!(app, :new)
        handle = app.operations.active
        wait(handle)
        HostReviewTerminal.session_action_finished!(app, handle)
        @test app.session.kernel !== original
        host_review_finish!(app)
        @test original.closed
        @test disposed[] == 1
        close(original)
        @test disposed[] == 1
    end
end

@testset "Terminal durable failures remain visible without crashing chat" begin
    for prompt in ("new prompt", "/julia 1 + 1")
        mktempdir() do directory
            calls = Ref(0)
            provider = (messages, session) -> (calls[] += 1; Reply(:answer, "should not be called"))
            app = HostReviewTerminal.App(HostReviewCore.default_kernel(provider); settings_dir=directory)
            HostReviewCore.append_message!(app.session, Message(:user, "original durable message"))
            open(app.archive.timeline.path, "a") do io
                write(io, "\n")
            end
            HostReviewTerminal.submit!(app, prompt)
            handle = app.operations.active
            @test !isnothing(handle)
            if !isnothing(handle)
                wait(handle; throw=false)
                HostReviewTerminal.operation_finished!(app, handle)
                @test !app.busy
                @test occursin("Session file changed", app.status)
                @test length(app.session.messages) == 1
                @test calls[] == 0
            end
            host_review_finish!(app)
        end
    end
end

@testset "Terminal model selection persists actual configuration and defaults" begin
    mktempdir() do directory
        app, calls, current = host_review_app(directory)
        HostReviewCore.append_message!(app.session, Message(:user, "question"))
        HostReviewCore.append_message!(app.session, Message(:assistant, "answer"))
        initial = HostReviewCore.timeline_projection(app.archive.timeline)
        @test initial.thinking_level == "low"
        @test initial.model == Dict("provider" => "chatgpt", "modelId" => "old")
        result = HostReviewTerminal.configure_terminal_model!(app, "chatgpt/new", "high", true, :model, ExecutionContext())
        @test result.ok
        before_default = HostReviewCore.component(app.session.kernel, :provider)
        entries_before_default = HostReviewCore.timeline_entries(app.archive.timeline)
        thinking_default = HostReviewTerminal.configure_terminal_model!(app, "chatgpt/new", "high", true, :model_thinking, ExecutionContext())
        @test thinking_default.ok
        @test HostReviewCore.component(app.session.kernel, :provider) === before_default
        @test HostReviewCore.timeline_entries(app.archive.timeline) == entries_before_default
        @test current.model == "old" && current.reasoning == "low"
        selected = HostReviewCore.component(app.session.kernel, :provider)
        @test HostReviewCore.provider_model_identity(selected).model_id == "new"
        @test HostReviewCore.current_thinking_level(selected) == "high"
        projected = HostReviewCore.timeline_projection(app.archive.timeline)
        @test projected.model == Dict("provider" => "chatgpt", "modelId" => "new")
        @test projected.thinking_level == "high"
        saved = JSON.parse(read(HostReviewTerminal.model_settings_path(app), String))
        @test saved["defaultModel"] == "chatgpt/new"
        @test saved["thinkingDefaults"]["chatgpt/new"] == "high"
        count_before = length(app.archive.timeline.entries)
        rejected = HostReviewTerminal.configure_terminal_model!(app, "chatgpt/not-in-catalog", "high", false, :model, ExecutionContext())
        @test !rejected.ok
        @test length(app.archive.timeline.entries) == count_before
        @test HostReviewCore.component(app.session.kernel, :provider) === selected
        context = ExecutionContext()
        HostReviewCore.cancel!(context)
        cancelled = HostReviewTerminal.configure_terminal_model!(app, "chatgpt/old", "low", false, :model, context)
        @test !cancelled.ok
        @test length(app.archive.timeline.entries) == count_before
        @test calls[] == 0
        restored, restored_calls, restored_current = host_review_app(directory)
        HostReviewTerminal.restore_default_model!(restored)
        restored_provider = HostReviewCore.component(restored.session.kernel, :provider)
        @test HostReviewCore.provider_model_identity(restored_provider).model_id == "new"
        @test HostReviewCore.current_thinking_level(restored_provider) == "high"
        @test restored_calls[] == 0
        host_review_finish!(restored)
        host_review_finish!(app)
    end
end

@testset "Terminal model preference CAS rejects external edits without losing them" begin
    mktempdir() do directory
        path = joinpath(directory, "model-settings.json")
        write(path, JSON.json(Dict("enabledModels" => ["chatgpt/old"])))
        app, calls, current = host_review_app(directory)
        external = JSON.json(Dict("enabledModels" => ["chatgpt/new"], "defaultModel" => "chatgpt/new"))
        write(path, external)
        menu = HostReviewTerminal.ScopedModelMenu(HostReviewTerminal.menu_model_snapshot(app); enabled=["chatgpt/old"])
        menu.dirty = true
        app.menus.scoped_menu = menu
        HostReviewTerminal.save_scoped_preferences!(app, Dict("enabledModels" => ["chatgpt/old"]), menu)
        handle = app.operations.active
        wait(handle; throw=false)
        HostReviewTerminal.model_preferences_finished!(app, handle)
        @test !app.busy
        @test menu.dirty
        @test menu.status_kind == :error
        @test read(path, String) == external
        @test app.menus.model_preferences["enabledModels"] == ["chatgpt/old"]
        @test calls[] == 0
        host_review_finish!(app)
    end
end

@testset "Terminal save owner is not replaced by a busy rejected save" begin
    mktempdir() do directory
        app, calls, current = host_review_app(directory)
        old = HostReviewTerminal.ScopedModelMenu(HostReviewTerminal.menu_model_snapshot(app))
        replacement = HostReviewTerminal.ScopedModelMenu(HostReviewTerminal.menu_model_snapshot(app))
        app.menus.scoped_save_owner = old
        app.menus.scoped_menu = replacement
        app.busy = true
        HostReviewTerminal.save_scoped_preferences!(app, Dict("enabledModels" => ["chatgpt/new"]), replacement)
        @test app.menus.scoped_save_owner === old
        @test isnothing(app.operations.active)
        app.busy = false
        host_review_finish!(app)
    end
end

@testset "Terminal model completion cannot close a newer same-path menu" begin
    mktempdir() do directory
        app, calls, current = host_review_app(directory)
        app.page = :pi_menu
        app.menus.path = ["model"]
        app.menus.generation = UInt(2)
        HostReviewTerminal.open_model_controls!(app, "model"; refresh=false)
        replacement = app.menus.model_menu
        app.menus.configuration_path = ["model"]
        app.menus.configuration_page = :pi_menu
        app.menus.configuration_generation = UInt(1)
        completed = Task(() -> HostReviewCore.ExecutionResult(true, "Prior selection applied"))
        schedule(completed)
        wait(completed)
        handle = HostReviewCore.TaskHandle(completed, app.session, ExecutionContext())
        app.operations.active = handle
        app.busy = true
        HostReviewTerminal.model_configuration_finished!(app, handle)
        @test app.page == :pi_menu
        @test app.menus.model_menu === replacement
        @test !replacement.closed
        @test !app.busy
        @test calls[] == 0
        host_review_finish!(app)
    end
end

@testset "Terminal default-save failure distinguishes active model from unsaved default" begin
    mktempdir() do directory
        app, calls, current = host_review_app(directory)
        target = joinpath(directory, "preserved-preferences.json")
        write(target, "{}\n")
        symlink(target, HostReviewTerminal.model_settings_path(app))
        result = HostReviewTerminal.configure_terminal_model!(app, "chatgpt/new", "high", true, :model, ExecutionContext())
        @test !result.ok
        @test occursin("current selection is active", result.text)
        selected = HostReviewCore.component(app.session.kernel, :provider)
        @test HostReviewCore.provider_model_identity(selected).model_id == "new"
        @test HostReviewCore.current_thinking_level(selected) == "high"
        @test read(target, String) == "{}\n"
        @test islink(HostReviewTerminal.model_settings_path(app))
        @test !haskey(app.menus.model_preferences, "defaultModel")
        @test calls[] == 0
        host_review_finish!(app)
    end
end

@testset "Terminal respects ownership of externally supplied kernels" begin
    mktempdir() do directory
        original = HostReviewCore.default_kernel()
        disposed = Ref(0)
        install!(original, ComponentSpec(:host_review_external, nothing; cleanup=value -> (disposed[] += 1)))
        app = HostReviewTerminal.App(original; settings_dir=directory)
        HostReviewTerminal.session_action!(app, :new)
        handle = app.operations.active
        wait(handle)
        HostReviewTerminal.session_action_finished!(app, handle)
        host_review_finish!(app)
        @test !original.closed
        @test disposed[] == 0
        close(original)
        @test disposed[] == 1
    end
end

@testset "Terminal migration retains historical identity and seeds current selection last" begin
    mktempdir() do directory
        historical = Dict{String,Any}("role" => "assistant", "content" => [Dict("type" => "text", "text" => "historical answer")],
            "provider" => "chatgpt", "model" => "historical-model", "timestamp" => 1000)
        message = HostReviewCore.timeline_native_message(historical, "old-entry")
        app, calls, current = host_review_app(directory; messages=[message])
        projected = HostReviewCore.timeline_projection(app.archive.timeline)
        @test projected.model == Dict("provider" => "chatgpt", "modelId" => "old")
        @test projected.thinking_level == "low"
        archived = only(HostReviewCore.timeline_messages(app.archive.timeline))
        @test archived["model"] == "historical-model"
        @test calls[] == 0
        host_review_finish!(app)
    end
end

@testset "Terminal model replacement retains borrowed provider resources" begin
    mktempdir() do directory
        app, calls, current = host_review_app(directory)
        kernel = app.session.kernel
        released = Ref(0)
        install!(kernel, ComponentSpec(:provider, current; cleanup=value -> (released[] += 1)))
        changed = HostReviewTerminal.configure_terminal_model!(app, "chatgpt/new", "high", false, :model, ExecutionContext())
        @test changed.ok
        replacement = HostReviewCore.component(kernel, :provider)
        @test replacement.backend.transport === current.transport
        @test released[] == 0
        changed_again = HostReviewTerminal.configure_terminal_model!(app, "chatgpt/old", "low", false, :model, ExecutionContext())
        @test changed_again.ok
        @test released[] == 0
        @test calls[] == 0
        host_review_finish!(app)
        @test released[] == 1
    end
end

@testset "Terminal resumed owned session retains borrowed provider resources" begin
    mktempdir() do directory
        app, calls, current = host_review_app(directory)
        original = app.session.kernel
        app.session.runtime.owns_kernel = true
        released = Ref(0)
        install!(original, ComponentSpec(:provider, current; cleanup=value -> (released[] += 1)))
        HostReviewCore.append_message!(app.session, Message(:user, "retained question"))
        id = app.archive.timeline.identity.id
        HostReviewTerminal.session_action!(app, :resume, id)
        handle = app.operations.active
        wait(handle)
        HostReviewTerminal.session_action_finished!(app, handle)
        @test original.closed
        @test app.session.kernel !== original
        @test released[] == 0
        selected = HostReviewCore.component(app.session.kernel, :provider)
        @test selected.backend.transport === current.transport
        @test calls[] == 0
        host_review_finish!(app)
        @test released[] == 1
    end
end

@testset "Terminal blocked preparation retains generation through replacement or cancellation" begin
    for concurrent_action in (:replace, :cancel)
        mktempdir() do directory
            app, calls, current = host_review_app(directory)
            kernel = app.session.kernel
            released = Ref(0)
            install!(kernel, ComponentSpec(:provider, current; cleanup=value -> (released[] += 1)))
            entry = kernel.entries[:provider]
            descriptor = HostReviewCore.provider_descriptor(app.settings.registry, :chatgpt)
            models = HostReviewCore.catalog_models(descriptor.create)
            started = Channel{Nothing}(1)
            proceed = Channel{Nothing}(1)
            first_call = Ref(true)
            still_live_after_resume = Ref(false)
            gated_models = function ()
                if first_call[]
                    first_call[] = false
                    put!(started, nothing)
                    take!(proceed)
                    still_live_after_resume[] = released[] == 0
                end
                models
            end
            replacement_factory = HostReviewCore.ProviderFactory(descriptor.create.create;
                models=gated_models, select=descriptor.create.select)
            HostReviewCore.register_provider!(app.settings.registry, HostReviewCore.ProviderDescriptor(descriptor, replacement_factory))
            before_count = length(app.archive.timeline.entries)
            context = ExecutionContext()
            task = Task(() -> HostReviewTerminal.configure_terminal_model!(app, "chatgpt/new", "high", false, :model, context))
            schedule(task)
            gate_ready = timedwait(() -> isready(started), 10; pollint=0.01)
            @test gate_ready == :ok
            @test released[] == 0
            if concurrent_action == :replace
                install!(kernel, ComponentSpec(:provider, HostReviewCore.DemoProvider()))
            else
                HostReviewCore.cancel!(context)
            end
            @test released[] == 0
            put!(proceed, nothing)
            wait(task; throw=false)
            @test !istaskfailed(task)
            result = fetch(task)
            @test !result.ok
            @test still_live_after_resume[]
            @test length(app.archive.timeline.entries) == before_count
            @test entry.users == 0
            @test released[] == (concurrent_action == :replace ? 1 : 0)
            @test calls[] == 0
            host_review_finish!(app)
            @test released[] == 1
        end
    end
end

function host_review_events!(app)
    while isready(app.queue.channel)
        Tachikoma.update!(app, take!(app.queue.channel))
    end
    nothing
end

@testset "Native resume selectors load, rename and delete actual owned archives" begin
    mktempdir() do directory
        app, calls, provider = host_review_app(directory)
        first = HostReviewCore.SessionTimeline(app.settings.workspace)
        HostReviewCore.timeline_append_message!(first, Dict("role" => "user", "content" => "First real archived question"))
        HostReviewCore.timeline_append_message!(first, Dict("role" => "assistant", "content" => "Preserved reply"))
        first_path = HostReviewCore.save_timeline!(app.archive.store, first)
        second = HostReviewCore.SessionTimeline(directory)
        HostReviewCore.timeline_append_message!(second, Dict("role" => "user", "content" => "Other directory"))
        HostReviewCore.save_timeline!(app.archive.store, second)
        HostReviewTerminal.open_menu!(app, "resume")
        menu = app.menus.resume_menu
        @test timedwait(() -> (host_review_events!(app); !menu.loading), 20) == :ok
        @test length(menu.records) == 1
        @test only(menu.records).first_message == "First real archived question"
        @test only(menu.records).text == "First real archived question Preserved reply"
        @test only(menu.records).messages == 2
        request = HostReviewTerminal.ResumeMutationRequest(; id=1, kind=:rename, path=first_path, value="Reviewed archive")
        HostReviewTerminal.mutate_resume_entry!(app, request)
        renamed = HostReviewCore.load_timeline(app.archive.store, first.identity.id)
        @test HostReviewCore.timeline_name(renamed) == "Reviewed archive"
        @test_throws ErrorException HostReviewTerminal.mutate_resume_entry!(app, request)
        app.menus.resume_revisions[first_path] = renamed.disk_digest
        deletion = HostReviewTerminal.ResumeMutationRequest(; id=2, kind=:delete, path=first_path)
        HostReviewTerminal.mutate_resume_entry!(app, deletion)
        @test !ispath(first_path)
        @test isfile(second.path)
        @test calls[] == 0
        @test_throws ErrorException HostReviewTerminal.terminal_resume_id(app, joinpath(directory, "outside.timeline.json"))
        HostReviewTerminal.close_session_selectors!(app)
        @test menu.disposed
        host_review_finish!(app)
    end
end

@testset "Rendering never waits on an active session execution lock" begin
    mktempdir() do directory
        app, calls, provider = host_review_app(directory)
        entered, release = Channel{Nothing}(1), Channel{Nothing}(1)
        owner = Threads.@spawn lock(app.session.runtime.execution_lock) do
            put!(entered, nothing)
            take!(release)
        end
        take!(entered)
        render = Threads.@spawn HostReviewTerminal.archive_transcript_lines!(app, 80)
        completed = timedwait(() -> istaskdone(render), 5)
        put!(release, nothing)
        wait(owner)
        wait(render)
        @test completed == :ok
        @test fetch(render) isa Vector
        @test calls[] == 0
        host_review_finish!(app)
    end
end

@testset "Current-model default updates active thinking, unrelated model defaults do not" begin
    mktempdir() do directory
        app, calls, original = host_review_app(directory)
        result = HostReviewTerminal.persist_thinking_default!(app, "chatgpt", "old", "high")
        @test result.ok
        active = HostReviewCore.component(app.session.kernel, :provider)
        @test HostReviewCore.provider_footer_status(active).thinking == "high"
        @test HostReviewCore.timeline_entry(app.archive.timeline, app.archive.timeline.leaf)["thinkingLevel"] == "high"
        app.menus.model_preferences["defaultThinking"] = "low"
        result = HostReviewTerminal.persist_thinking_default!(app, "chatgpt", "old", nothing)
        @test result.ok
        @test HostReviewCore.provider_footer_status(HostReviewCore.component(app.session.kernel, :provider)).thinking == "low"
        @test calls[] == 0
        host_review_finish!(app)
    end
end

@testset "Thinking menu and shortcut preferences change real projection and survive restart" begin
    mktempdir() do directory
        T = HostReviewTerminal
        app, calls, original = host_review_app(directory)
        JuliaForever2.timeline_append_message!(app.archive.timeline, Dict("role"=>"assistant","content"=>[Dict("type"=>"thinking","thinking"=>"Private fixture reasoning"),Dict("type"=>"text","text"=>"Public fixture reply")]))
        before = JuliaForever2.timeline_entries(app.archive.timeline)
        visible = T.archive_transcript_lines!(app,80)
        rowtext(rows) = join((join(span.content for span in row) for row in rows),"\n")
        @test occursin("Private fixture reasoning",rowtext(visible))
        T.toggle_thinking_visibility!(app)
        @test app.transcript.display.hide_thinking
        @test app.status=="Thinking blocks: hidden"
        @test JSON.parsefile(joinpath(directory,"terminal-settings.json"))["hide-thinking"]=="true"
        hidden = T.archive_transcript_lines!(app,80)
        @test !occursin("Private fixture reasoning",rowtext(hidden))
        @test occursin("Thinking...",rowtext(hidden))
        @test occursin("Public fixture reply",rowtext(hidden))
        @test JuliaForever2.timeline_entries(app.archive.timeline)==before
        @test calls[]==0
        host_review_finish!(app)
        restored, calls, original = host_review_app(directory)
        @test restored.transcript.display.hide_thinking
        T.toggle_thinking_visibility!(restored)
        @test !restored.transcript.display.hide_thinking
        @test restored.status=="Thinking blocks: visible"
        # Denied persistence cannot hide text or falsely claim saved success.
        rm(joinpath(directory,"terminal-settings.json"))
        symlink("missing-target",joinpath(directory,"terminal-settings.json"))
        T.toggle_thinking_visibility!(restored)
        @test !restored.transcript.display.hide_thinking
        @test restored.status!="Thinking blocks: hidden"
        host_review_finish!(restored)
    end
end
