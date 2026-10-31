using JET
using Tachikoma
using CommonMark

@testset "JET package quality" begin
    JET.test_package(JuliaForever2; target_modules=(JuliaForever2,
        JuliaForever2.JSONCodec, JuliaForever2.HTTPTransport, JuliaForever2.EventStreams,
        JuliaForever2.ProcessRuntime, JuliaForever2.CredentialStorage))
end

@testset "JET terminal extension quality" begin
    terminal = Base.get_extension(JuliaForever2, :JuliaForever2TerminalExt)
    JET.test_package(terminal; target_modules=(terminal,))
end
