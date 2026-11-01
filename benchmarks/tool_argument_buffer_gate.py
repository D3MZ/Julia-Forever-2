#!/usr/bin/env python3
import json
import os
import random
import statistics
import subprocess
import sys
import traceback
from pathlib import Path

evidence = Path(os.environ["EVIDENCE_DIR"])
evidence.mkdir(parents=True, exist_ok=True)
candidate = Path.cwd()
baseline = Path(os.environ["BASELINE_DIR"])
experiment = candidate / "benchmarks/tool_argument_buffer_experiment.jl"
baseline_sha = os.environ["BASELINE_SHA"]
candidate_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
environment = dict(os.environ, JULIA_PKG_PRECOMPILE_AUTO="0")

def run(side, index):
    project = (baseline if side == "baseline" else candidate) / "benchmarks"
    env = dict(environment, JF2_SIDE=side, JF2_PAIR=str(index), JF2_PROFILE="1" if index == 1 else "0")
    command = ["julia", "--startup-file=no", f"--project={project}", str(experiment)]
    process = subprocess.run(command, cwd=candidate, env=env, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (evidence / f"pair-{index:02d}-{side}.log").write_text(process.stdout)
    print(f"Pair {index}, {side}: exit {process.returncode}", flush=True)
    print(process.stdout[-3000:], flush=True)
    if process.returncode:
        raise RuntimeError(f"Julia {side} pair {index} failed; see artifact log")
    return json.loads((evidence / f"pair-{index:02d}-{side}.json").read_text())

def bootstrap_lower(values):
    rng = random.Random(20261101)
    medians = [statistics.median(rng.choices(values, k=len(values))) for _ in range(20000)]
    medians.sort()
    return medians[int(0.025 * len(medians))]

pairs = []
report = {"passed": False, "baseline_sha": baseline_sha, "candidate_sha": candidate_sha,
          "pairing": "AB,BA,AB,BA,AB,BA,AB", "pairs": 7, "repetitions_per_side": 7,
          "workloads": {}, "error": None}
try:
    actual = subprocess.check_output(["git", "-C", str(baseline), "rev-parse", "HEAD"], text=True).strip()
    if actual != baseline_sha:
        raise RuntimeError("Baseline worktree SHA differs from pinned latest main")
    for index in range(1, 8):
        order = ("baseline", "candidate") if index % 2 else ("candidate", "baseline")
        observation = {}
        for side in order:
            observation[side] = run(side, index)
        pairs.append(observation)
    stable = ["julia_version", "threads", "cpu", "architecture", "logical_cpus",
              "json_version", "juliaforever_version", "packages", "fixtures", "repetitions", "warmup"]
    for index, pair in enumerate(pairs, 1):
        for field in stable:
            if pair["baseline"]["metadata"][field] != pair["candidate"]["metadata"][field]:
                raise RuntimeError(f"Environment mismatch in pair {index}: {field}")
    for name in sorted(pairs[0]["baseline"]["results"]):
        improvements, raw, digests = [], [], set()
        for pair in pairs:
            baseline_result = pair["baseline"]["results"][name]
            candidate_result = pair["candidate"]["results"][name]
            improvements.append(1 - candidate_result["median_ns"] / baseline_result["median_ns"])
            digests.update((baseline_result["digest"], candidate_result["digest"]))
            raw.append({"baseline": baseline_result, "candidate": candidate_result})
        median = statistics.median(improvements)
        bound = bootstrap_lower(improvements)
        getmed = lambda side, field: statistics.median(p[side][field] for p in raw)
        report["workloads"][name] = {
            "median_improvement": median, "lower95": bound,
            "minimum_pair_improvement": min(improvements),
            "baseline_median_ns": getmed("baseline", "median_ns"),
            "candidate_median_ns": getmed("candidate", "median_ns"),
            "baseline_median_bytes": getmed("baseline", "allocated_bytes"),
            "candidate_median_bytes": getmed("candidate", "allocated_bytes"),
            "baseline_median_allocations": getmed("baseline", "allocation_count"),
            "candidate_median_allocations": getmed("candidate", "allocation_count"),
            "exact_output_match": len(digests) == 1,
            "paired_improvements": improvements, "samples": raw}
        print(f"{name}: median {100*median:.2f}%, lower95 {100*bound:.2f}%, minimum pair {100*min(improvements):.2f}%")
    primary = report["workloads"]["openai/integration-large"]
    report["no_regressions"] = all(item["median_improvement"] > -0.10
                                   for item in report["workloads"].values())
    report["correct"] = all(item["exact_output_match"] for item in report["workloads"].values())
    report["passed"] = (primary["median_improvement"] > 0.10 and primary["lower95"] > 0.10
                        and primary["minimum_pair_improvement"] > 0.10
                        and report["no_regressions"] and report["correct"])
except Exception as error:
    report["error"] = f"{error}\n{traceback.format_exc()}"
finally:
    (evidence / "gate.json").write_text(json.dumps(report, indent=2))
    (evidence / "paired-raw.json").write_text(json.dumps(pairs, indent=2))
print("PERFORMANCE_GATE=" + ("PASS" if report["passed"] else "FAIL"), flush=True)
if report["error"]:
    print(report["error"])
sys.exit(0 if report["passed"] else 1)
