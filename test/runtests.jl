using Test

include("groups.jl")

unknown = unknown_test_groups(ARGS)
if !isempty(unknown)
    println(stderr, "Unknown quality group(s): ", join(unknown, ", "))
    println(stderr, "Available groups: ", join(sort!(collect(keys(TEST_GROUPS))), ", "))
    exit(2)
end

files = selected_test_files(ARGS)
if any(file -> file in ("aqua.jl", "jet.jl"), files)
    import Pkg
    Pkg.activate(@__DIR__; io=devnull)
end
missing_checks = [name for (file, name) in (("aqua.jl", "Aqua"), ("jet.jl", "JET"))
    if file in files && isnothing(Base.find_package(name))]
if !isempty(missing_checks)
    println(stderr, "Quality dependencies unavailable: ", join(missing_checks, ", "))
    println(stderr, "Instantiate with julia --project=test -e 'using Pkg; Pkg.instantiate()'")
    exit(2)
end

if any(file -> file != "lint_tests.jl", files)
    @eval using JuliaForever2
end

for file in files
    include(file)
end
