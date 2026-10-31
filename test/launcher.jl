@testset "jf2 launcher" begin
    mktempdir() do root
        project = joinpath(root, "project with spaces")
        bindir = joinpath(project, "bin")
        workdir = joinpath(root, "working directory")
        commanddir = joinpath(root, "commands")
        mkpath.((bindir, workdir, commanddir))
        cp(joinpath(@__DIR__, "..", "bin", "juliaforever"), joinpath(bindir, "juliaforever"))
        chmod(joinpath(bindir, "juliaforever"), 0o755)
        symlink("juliaforever", joinpath(bindir, "jf2"))
        symlink(joinpath(bindir, "jf2"), joinpath(commanddir, "jf2"))
        julia = joinpath(commanddir, "julia")
        write(julia, "#!/bin/sh\nprintf '%s\\n' \"\$PWD\" \"\$@\" > \"\$JF2_TEST_OUTPUT\"\n")
        chmod(julia, 0o755)
        output = joinpath(root, "arguments")
        cmd = `$(joinpath(commanddir, "jf2")) two\ words --example`
        cd(workdir) do
            run(addenv(cmd, "PATH" => commanddir * ":" * ENV["PATH"], "JF2_TEST_OUTPUT" => output))
        end
        args = readlines(output)
        @test realpath(args[1]) == realpath(workdir)
        @test args[2] == "--project=$project"
        @test args[3] == "-e"
        @test occursin("JuliaForever2.main()", args[4])
        @test args[5:end] == ["two words", "--example"]
    end
end
