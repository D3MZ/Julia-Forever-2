# Task completion

- After every task, commit the task's changes and push them when the relevant tests pass.
- After pushing, remove task-related worktrees and local and remote branches once their changes are integrated into the target branch. Preserve unrelated work, uncommitted changes, and the main branch.

# Julia conventions

- Read and follow the [Julia style guide](https://docs.julialang.org/en/v1/manual/style-guide/) and [performance tips](https://docs.julialang.org/en/v1/manual/performance-tips/).
- Keep docstrings to a single line immediately above the function whenever possible.
- Prefer multiple dispatch and small functions over early short-circuit returns for unexpected behavior and over try/catch.
- Do not write or edit documentation or README files; the user handles those. Update this instructions file when the user explicitly asks.
- The repository lint forbids `throw`, `rethrow`, `@assert`, and `try`/`catch` in Julia source.

# Focused verification

- Run the smallest relevant test groups rather than the full suite. From the repository root, use `julia --project test/runtests.jl <group> [group...]`. Available groups: `selection`, `launcher`, `kernel`, `agent`, `core` (kernel and agent), `tui`, `providers`, `auth`, `smoke`, and `unit` (all of those). Groups may be combined; each file runs once.
- Match tests to changes: `core` for kernel, agent, and plugin work; `tui` for terminal UI; `providers auth` for provider or sign-in work; `launcher` for `bin/`; and `selection` for the test runner or group definitions.
- Run repository syntax lint independently with `julia --project test/runtests.jl lint`. This checks every Julia file and exercises the lint rules.
- Run package-quality checks in Julia's test environment, where their extra dependencies are available: `julia --project -e 'using Pkg; Pkg.test(; test_args=["quality"])'`. Select `aqua` or `jet` instead of `quality` to run just Aqua or JET. Use the checks relevant to the change; Aqua covers package hygiene and JET analyzes the package.
- `Pkg.test()` without test arguments still runs the complete offline suite, lint, Aqua, and JET for CI. Do not run it for routine focused work unless explicitly requested or needed for a broad change.
- `test/live_backbone.jl` is deliberately excluded from all groups and CI: it calls a real Codex subscription model and executes model-generated Julia with user permissions. Run it only with explicit user authorization.
- Register new test files and their focused groups in `test/groups.jl`; update `test/selection.jl` when adding special helper or live-test files.
