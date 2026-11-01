const UNIT_TEST_FILES = [
    "selection.jl",
    "launcher.jl",
    "packaging.jl",
    "kernel.jl",
    "agent.jl",
    "contracts.jl",
    "architecture.jl",
    "architecture_contracts.jl",
    "streaming.jl",
    "tui.jl",
    "providers.jl",
    "adapters_architecture.jl",
    "auth.jl",
    "smoke.jl",
]
const DIFFERENTIAL_TEST_FILES = ["dsh_differential.jl", "dsh_runtime_differential.jl", "pi_parity.jl"]
const TEST_FILES = vcat(UNIT_TEST_FILES, DIFFERENTIAL_TEST_FILES, ["lint_tests.jl", "aqua.jl", "jet.jl"])

const TEST_GROUPS = Dict(
    "selection" => ["selection.jl"],
    "launcher" => ["launcher.jl"],
    "packaging" => ["packaging.jl"],
    "kernel" => ["kernel.jl"],
    "agent" => ["agent.jl"],
    "contracts" => ["contracts.jl"],
    "architecture" => ["architecture.jl", "architecture_contracts.jl"],
    "streaming" => ["streaming.jl"],
    "adapters" => ["adapters_architecture.jl"],
    "core" => ["kernel.jl", "agent.jl", "contracts.jl", "architecture.jl", "architecture_contracts.jl"],
    "tui" => ["tui.jl"],
    "providers" => ["providers.jl", "adapters_architecture.jl"],
    "auth" => ["auth.jl"],
    "smoke" => ["smoke.jl"],
    "differential" => ["dsh_differential.jl"],
    "differential-runtime" => ["dsh_runtime_differential.jl"],
    "differential-all" => copy(DIFFERENTIAL_TEST_FILES),
    "parity" => ["pi_parity.jl"],
    "lint" => ["lint_tests.jl"],
    "aqua" => ["aqua.jl"],
    "jet" => ["jet.jl"],
    "quality" => ["aqua.jl", "jet.jl"],
    "unit" => copy(UNIT_TEST_FILES),
    "all" => copy(TEST_FILES),
)

unknown_test_groups(groups) = filter(group -> !haskey(TEST_GROUPS, group), groups)

function selected_test_files(groups)
    names = isempty(groups) ? ["all"] : groups
    selected = Set(file for name in names for file in TEST_GROUPS[name])
    return filter(in(selected), TEST_FILES)
end
