#!/usr/bin/env python3
"""Compare unmodified pinned Pi and Julia on identical deterministic scenarios."""
from __future__ import annotations

import argparse
import difflib
import json
import os
from pathlib import Path
import subprocess
import sys

from scenarios import build_scenarios

ROOT = Path(__file__).resolve().parents[1]


def execute(command: list[str], *, input_text: str | None = None, timeout: int = 240) -> str:
    completed = subprocess.run(command, cwd=ROOT, input=input_text, text=True,
                               capture_output=True, timeout=timeout, check=False)
    if completed.returncode:
        raise RuntimeError(f"Command failed ({completed.returncode}): {command!r}\n"
                           f"{completed.stdout}\n{completed.stderr}")
    return completed.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', default=os.environ.get('PI_REFERENCE', ''))
    parser.add_argument('--report', default='')
    parser.add_argument('--require-complete', action='store_true',
                        help='Also fail on any gap or incomplete capability inventory.')
    arguments = parser.parse_args()
    if not arguments.reference:
        raise ValueError('PI_REFERENCE or --reference must identify a checkout of parity/pi-lock.json; no oracle means failure, not a skip.')
    reference = Path(arguments.reference).resolve()
    lock = json.loads((ROOT / 'parity/pi-lock.json').read_text())
    manifest = json.loads((ROOT / 'parity/capabilities.json').read_text())
    scenarios = build_scenarios()
    commit = execute(['git', '-C', str(reference), 'rev-parse', 'HEAD']).strip()
    tree = execute(['git', '-C', str(reference), 'rev-parse', 'HEAD^{tree}']).strip()
    if commit != lock['commit'] or tree != lock['tree']:
        raise ValueError(f'Oracle pin mismatch: expected {lock["commit"]}/{lock["tree"]}, got {commit}/{tree}')
    execute(['git', '-C', str(reference), 'diff', '--exit-code', 'HEAD', '--'])
    capabilities = {entry['id']: entry for entry in manifest['capabilities']}
    if len(capabilities) != len(manifest['capabilities']):
        raise ValueError('Duplicate capability identifiers')
    if len({scenario['id'] for scenario in scenarios}) != len(scenarios):
        raise ValueError('Duplicate scenario identifiers')
    exercised = {capability for scenario in scenarios for capability in scenario['capabilities']}
    covered = {name for name, entry in capabilities.items() if entry['status'] == 'differential'}
    if exercised != covered:
        raise ValueError(f'Manifest/scenario coverage mismatch: {sorted(exercised ^ covered)}')
    for entry in manifest['capabilities']:
        for source in entry['sources']:
            path = (reference / source).resolve()
            if not path.is_relative_to(reference) or not path.is_file():
                raise ValueError(f'Missing upstream evidence: {source}')
    payload = json.dumps(scenarios, ensure_ascii=False)
    oracle = json.loads(execute(['node', '--conditions=source', str(ROOT / 'parity/oracle.mjs'), str(reference)], input_text=payload))
    candidate = json.loads(execute([os.environ.get('JULIA', 'julia'), '--startup-file=no', f'--project={ROOT}',
                                    str(ROOT / 'parity/candidate.jl')], input_text=payload))
    scenario_ids = [scenario['id'] for scenario in scenarios]
    for name, result in [('Pi', oracle), ('Julia', candidate)]:
        if [entry['id'] for entry in result] != scenario_ids:
            raise ValueError(f'{name} returned missing, duplicate, or reordered scenarios')
    failures = []
    for expected, actual in zip(oracle, candidate, strict=True):
        if expected != actual:
            failures.append(expected['id'])
            before = json.dumps(expected, ensure_ascii=False, sort_keys=True, indent=2).splitlines(True)
            after = json.dumps(actual, ensure_ascii=False, sort_keys=True, indent=2).splitlines(True)
            sys.stderr.writelines(difflib.unified_diff(before, after, fromfile='pinned Pi', tofile='Julia Forever 2'))
            sys.stderr.write('\n')
    gaps = sorted(name for name, entry in capabilities.items() if entry['status'] != 'differential')
    complete = not failures and not gaps and manifest['inventory_complete']
    report = {
        'baseline': commit, 'oracle': 'unmodified upstream source',
        'scenario_count': len(scenarios), 'failed_scenarios': failures,
        'differential_contracts': sorted(covered), 'gaps': gaps,
        'inventory_complete': manifest['inventory_complete'], 'full_parity_established': complete,
        'projection': manifest['projection'],
    }
    if arguments.report:
        report_path = Path(arguments.report)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return int(bool(failures) or (arguments.require_complete and not complete))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f'Pi differential verification failed: {error}', file=sys.stderr)
        sys.exit(1)
