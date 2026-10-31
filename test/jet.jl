using JET
using Tachikoma
using CommonMark

@testset "JET package quality" begin
    JET.test_package(JuliaForever2; target_modules=(JuliaForever2,))
end

@testset "JET terminal extension quality" begin
    terminal = Base.get_extension(JuliaForever2, :JuliaForever2TerminalExt)
    JET.test_package(terminal; target_modules=(terminal,))
end
