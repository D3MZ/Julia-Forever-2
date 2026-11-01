@testset "Terminal update notifications and settings" begin
    mktempdir() do directory
        app = Terminal.App(JuliaForever2.default_kernel(); settings_dir=directory)
        @test !app.updates.automatic
        @test any(command.name == "update" for command in app.commands)
        Terminal.settings_command!(app, "")
        @test app.page == :settings
        update!(app, KeyEvent('a'))
        @test app.updates.automatic
        @test JuliaForever2.auto_updates_enabled(directory)
        update!(app, KeyEvent('a'))
        @test !app.updates.automatic
        @test !JuliaForever2.auto_updates_enabled(directory)

        check = JuliaForever2.UpdateCheck(directory, "origin", "a"^40, "b"^40, :available)
        Terminal.update_checked!(app, check)
        @test app.updates.latest === check
        @test occursin("Update available", app.status)
        Terminal.toggle_auto_updates!(app; installer=info -> :installed)
        @test app.updates.automatic
        @test timedwait(() -> isready(app.queue.channel), 5) == :ok
        update!(app, take!(app.queue.channel))
        @test !app.updates.installing
        @test isnothing(app.updates.latest)
        @test occursin("Restart", app.status)
        Terminal.finish_shutdown!(app)

        restored = Terminal.App(JuliaForever2.default_kernel(); settings_dir=directory)
        @test restored.updates.automatic
        Terminal.finish_shutdown!(restored)
    end
end
