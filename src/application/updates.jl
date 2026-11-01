"""A Git installation's current and tracked upstream revisions."""
struct UpdateCheck
    root::String
    source::String
    current::String
    latest::String
    state::Symbol
end

"""Locate the source checkout used to launch Julia Forever 2."""
installation_root() = normpath(joinpath(@__DIR__, "..", ".."))

"""Automatic installation is disabled until explicitly enabled in settings."""
auto_updates_enabled(directory::AbstractString=config_dir()) =
    isfile(joinpath(directory, "auto_update")) && strip(read(joinpath(directory, "auto_update"), String)) == "true"

"""Persist the automatic update preference independently of provider credentials."""
function set_auto_updates!(directory::AbstractString, enabled::Bool)
    mkpath(directory; mode=0o700)
    mktemp(directory) do path, io
        chmod(path, 0o600)
        print(io, enabled)
        close(io)
        Base.Filesystem.rename(path, joinpath(directory, "auto_update"))
    end
    return enabled
end

update_available(check::UpdateCheck) = check.state == :available

"""Check the branch tracked by this Git installation, not a hard-coded GitHub URL."""
function check_for_updates(root::AbstractString=installation_root())
    directory = abspath(root)
    if ispath(joinpath(directory, ".git"))
        check_git_upstream(directory)
    else
        UpdateCheck(directory, "", "", "", :unsupported)
    end
end

function check_git_upstream(directory::AbstractString)
    tracking = strip(read(pipeline(ignorestatus(`git -C $directory rev-parse --abbrev-ref --symbolic-full-name "@{upstream}"`), stderr=devnull), String))
    if isempty(tracking)
        UpdateCheck(directory, "", "", "", :unsupported)
    else
        remote = first(split(tracking, '/'; limit=2))
        source = strip(read(pipeline(ignorestatus(`git -C $directory remote get-url $remote`), stderr=devnull), String))
        fetched = success(run(pipeline(ignorestatus(`git -C $directory fetch --quiet $remote`), stdout=devnull, stderr=devnull)))
        if fetched
            current = strip(read(`git -C $directory rev-parse HEAD`, String))
            latest = strip(read(`git -C $directory rev-parse $tracking`, String))
            forward = success(run(pipeline(ignorestatus(`git -C $directory merge-base --is-ancestor $current $latest`), stdout=devnull, stderr=devnull)))
            state = current == latest ? :current : forward ? :available : :diverged
            UpdateCheck(String(directory), source, current, latest, state)
        else
            UpdateCheck(String(directory), source, "", "", :unavailable)
        end
    end
end

"""Resolve and precompile the updated Julia application for its next launch."""
function precompile_update!(root::AbstractString)
    julia = Base.julia_cmd()
    project = joinpath(root, "app")
    command = `$julia --startup-file=no --project=$project -e "using Pkg; Pkg.instantiate(); Pkg.precompile(); using JuliaForever2, Tachikoma, CommonMark"`
    return success(run(pipeline(ignorestatus(command), stdout=devnull, stderr=devnull)))
end

"""Fast-forward the installed checkout to the checked revision, then precompile."""
function apply_update!(check::UpdateCheck; rebuild=precompile_update!)
    if update_available(check)
        advanced = success(run(pipeline(ignorestatus(`git -C $(check.root) merge --ff-only $(check.latest)`), stdout=devnull, stderr=devnull)))
        advanced ? (rebuild(check.root) ? :installed : :compile_failed) : :merge_failed
    else
        :current
    end
end
