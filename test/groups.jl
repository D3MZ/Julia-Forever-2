# Scheduled quality-only checks. Regression and differential suites were removed.
const TEST_FILES = ["lint_tests.jl", "aqua.jl", "jet.jl"]

const TEST_GROUPS = Dict(
    "lint" => ["lint_tests.jl"],
    "aqua" => ["aqua.jl"],
    "jet" => ["jet.jl"],
    "quality" => ["aqua.jl", "jet.jl"],
    "all" => copy(TEST_FILES),
)

unknown_test_groups(groups) = filter(group -> !haskey(TEST_GROUPS, group), groups)

function selected_test_files(groups)
    names = isempty(groups) ? ["all"] : groups
    selected = Set(file for name in names for file in TEST_GROUPS[name])
    filter(in(selected), TEST_FILES)
end
