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

@testset "Updater preserves local and ignored work" begin
    mktempdir() do directory
        upstream = joinpath(directory, "upstream.git")
        publisher = joinpath(directory, "publisher")
        installation = joinpath(directory, "installation")
        run(`git init --bare --initial-branch=main $upstream`)
        run(`git init --initial-branch=main $publisher`)
        run(`git -C $publisher config user.name Test`)
        run(`git -C $publisher config user.email test@example.invalid`)
        write(joinpath(publisher, ".gitignore"), "cache.txt\n")
        write(joinpath(publisher, "version.txt"), "before\n")
        run(`git -C $publisher add .`)
        run(`git -C $publisher -c commit.gpgsign=false commit -m initial`)
        run(`git -C $publisher remote add origin $upstream`)
        run(`git -C $publisher push -u origin main`)
        run(`git clone $upstream $installation`)
        write(joinpath(publisher, "version.txt"), "after\n")
        write(joinpath(publisher, "cache.txt"), "upstream\n")
        run(`git -C $publisher add version.txt`)
        run(`git -C $publisher add -f cache.txt`)
        run(`git -C $publisher -c commit.gpgsign=false commit -m update`)
        run(`git -C $publisher push`)
        check = check_for_updates(installation)
        head() = strip(read(`git -C $installation rev-parse HEAD`, String))
        calls = String[]
        rebuild = root -> (push!(calls, root); true)
        untracked = joinpath(installation, "untracked.txt")
        write(untracked, "keep me\n")
        @test apply_update!(check; rebuild) == :dirty
        @test head() == check.current && read(untracked, String) == "keep me\n"
        rm(untracked)
        version = joinpath(installation, "version.txt")
        write(version, "local edit\n")
        @test apply_update!(check; rebuild) == :dirty
        @test head() == check.current && read(version, String) == "local edit\n"
        write(version, "before\n")
        stale = JuliaForever2.UpdateCheck(check.root, check.source, "0000000", check.latest, :available)
        @test apply_update!(stale; rebuild) == :changed
        @test head() == check.current && isempty(calls)
        ignored = joinpath(installation, "cache.txt")
        write(ignored, "local ignored data\n")
        @test apply_update!(check; rebuild) == :merge_failed
        @test head() == check.current && read(ignored, String) == "local ignored data\n"
        @test isempty(calls)
        rm(ignored)
        @test apply_update!(check; rebuild) == :installed
        @test head() == check.latest && read(version, String) == "after\n"
        @test length(calls) == 1
    end
end
