using JuliaForever2: check_for_updates, update_available, apply_update!, auto_updates_enabled, set_auto_updates!

@testset "Git origin update parity" begin
    mktempdir() do directory
        upstream = joinpath(directory, "upstream.git")
        publisher = joinpath(directory, "publisher")
        installation = joinpath(directory, "installation")
        run(`git init --bare --initial-branch=main $upstream`)
        run(`git init --initial-branch=main $publisher`)
        run(`git -C $publisher config user.name Test`)
        run(`git -C $publisher config user.email test@example.invalid`)
        mkpath(joinpath(publisher, "app"))
        write(joinpath(publisher, "app", "Project.toml"), "name = \"UpdaterFixture\"\n")
        source = joinpath(publisher, "version.txt")
        write(source, "first\n")
        run(`git -C $publisher add .`)
        run(`git -C $publisher -c commit.gpgsign=false commit -m initial`)
        run(`git -C $publisher remote add origin $upstream`)
        run(`git -C $publisher push -u origin main`)
        run(`git clone $upstream $installation`)

        current = check_for_updates(installation)
        @test current.state == :current
        @test !update_available(current)
        @test current.source == upstream
        @test apply_update!(current; rebuild=root -> error("No rebuild for current revision")) == :current

        write(source, "second\n")
        run(`git -C $publisher add version.txt`)
        run(`git -C $publisher -c commit.gpgsign=false commit -m update`)
        run(`git -C $publisher push`)
        available = check_for_updates(installation)
        @test available.state == :available
        @test update_available(available)
        @test available.current == current.current
        @test available.latest != available.current
        @test read(joinpath(installation, "version.txt"), String) == "first\n"

        rebuilt = String[]
        @test apply_update!(available; rebuild=root -> (push!(rebuilt, root); true)) == :installed
        @test rebuilt == [abspath(installation)]
        @test read(joinpath(installation, "version.txt"), String) == "second\n"
        @test check_for_updates(installation).state == :current
        @test !update_available(check_for_updates(installation))
    end
end

@testset "Automatic update preference is opt-in" begin
    mktempdir() do directory
        @test !auto_updates_enabled(directory)
        @test set_auto_updates!(directory, true)
        @test auto_updates_enabled(directory)
        @test !set_auto_updates!(directory, false)
        @test !auto_updates_enabled(directory)
        @test check_for_updates(directory).state == :unsupported
    end
end
