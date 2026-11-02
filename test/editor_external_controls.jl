using Test,JuliaForever2,Tachikoma,CommonMark
module ExternalEditorControlTests
using Test,JuliaForever2,Tachikoma,CommonMark
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
@testset "External editor host rejects missing terminal and preserves the exact draft" begin
    session=Session(Kernel((messages,session)->error("No model call permitted"));working_directory=mktempdir())
    app=T.App(session;settings_dir=mktempdir(),registry=JuliaForever2.ProviderRegistry(),theme_fallback="dark")
    T.chat_completion_set_text!(T.chat_completion_state!(app),"draft α")
    owner=T.ExternalEditorProcess();result=T.external_editor_command!(app;command="must-not-launch",owner)
    @test !result.ok && occursin("attached local terminal",result.reason)
    @test !owner.started && isnothing(owner.process)
    @test Tachikoma.text(app.input)=="draft α"
    @test isnothing(app.operations.active)
    app.page=:settings
    @test !T.external_editor_command!(app;command="must-not-launch").ok
    app.page=:chat;app.operations.closing[]=true
    @test !T.external_editor_command!(app;command="must-not-launch").ok
    app.operations.closing[]=false
    for packet in ("\a","\e[103;5u","\e[71;5u","\e[27;5;103~","\e[27;5;71~")
        @test T.external_editor_packet(packet)
    end
    for packet in ("g","G","\e[103u","\e[103;3u","\e[200~\a\e[201~")
        @test !T.external_editor_packet(packet)
    end
    T.finish_shutdown!(app);close(session.kernel)
end
end
