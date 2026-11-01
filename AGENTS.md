# Task completion

- After every task, commit the task's changes and push them when the relevant tests pass.
- Merge completed task changes into the target branch once the relevant checks pass, without asking for separate merge confirmation. Do not stop at an unmerged pull request unless a required check or repository protection blocks merging.
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

# Hourly upstream-inspired parity cycle: red → green → refactor

- Fetch current `main` and the current default branch of `deepseek-ai/deepseek-harness`; record exact commit hashes before selecting work. DSH is an external product-behavior reference and optional **test-only** oracle, not a production dependency, implementation template, process adapter, SDK, web server, or runtime.
- Inventory material user-facing capabilities and architectural concepts, distinguishing **native and differentially verified**, **native but unverified**, **reference-only**, and **missing**. Audit production source for DSH/Cordis/Pi invocation or delegation. Prefer closing an unverified high-value family over increasing case counts within an already narrow projection.
- **RED:** Before implementation, add or update **differential tests only** that invoke the original, exact-revision, source-hash-checked upstream oracle where suitable. Cover successes, denials, errors, cancellation, lifecycle and replacement behavior that materially distinguishes parity. Demonstrate a meaningful failure on the unchanged Julia baseline and record the red evidence; distinguish implementation mismatch from failed oracle setup. Never perform external model calls.
- **GREEN:** Independently implement the smallest useful Julia-native feature with explicit contracts, composable services, multiple dispatch and replaceable plugins. Avoid copying upstream structures or leaking its protocol types into production. Make the new differentials pass while preserving existing APIs and regression behavior.
- **REFACTOR:** Simplify interfaces and ownership, eliminate accidental coupling, then rerun differentials and the existing focused regression suite, syntax lint, Aqua and JET. Verify GitHub Actions CI and relevant additional workflows on the final PR head; do not interpret a skipped, pending or failing workflow as success.
- **PROVE, do not assert:** `superset_proven` may become `true` only with an exhaustive current-upstream material-feature inventory, an independently native implementation and passing executable differential evidence for **every** material family (including provider, agent, SDK, CLI and Web behaviors), no unresolved/unverified families, no feature supported solely through a DSH/Pi adapter, and all regression/quality/CI gates passing. Record verified subscopes separately from whole-product proof. A count of passing fixtures is not exhaustive parity, and a declared capability without executed evidence cannot close a gap. Keep the machine-checkable proof gate consistent with the capability matrix.
- Commit substantive work on a feature branch, open a PR, and merge into `main` only after the complete required CI and differential checks pass and GitHub reports the PR safely mergeable; otherwise leave the PR open and report the blockers. Never change `superset_proven` merely to satisfy a requested outcome.
