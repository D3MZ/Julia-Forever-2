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
from wire import FixtureServer

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
    if manifest['baseline_commit'] != lock['commit']:
        raise ValueError('Capability manifest and Pi pin refer to different commits')
    for extension_path in sorted((ROOT / 'parity/capabilities.d').glob('*.json')):
        extension = json.loads(extension_path.read_text())
        if extension['baseline_commit'] != lock['commit']:
            raise ValueError(f'Extension manifest pin mismatch: {extension_path}')
        manifest['capabilities'].extend(extension['capabilities'])
        manifest['projection'].update(extension.get('projection', {}))
        manifest['inventory_complete'] = manifest['inventory_complete'] and extension['inventory_complete']
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
    server = FixtureServer(scenarios)
    try:
        for scenario in scenarios:
            if scenario['family'] == 'wire':
                scenario['endpoint'] = f"{server.base_url}/fixture/{scenario['id']}"
        payload = json.dumps(scenarios, ensure_ascii=False)
        oracle = json.loads(execute(['node', '--conditions=source', str(ROOT / 'parity/oracle.mjs'), str(reference)], input_text=payload))
        oracle_requests = server.drain()
        candidate = json.loads(execute([os.environ.get('JULIA', 'julia'), '--startup-file=no', f'--project={ROOT}',
                                        str(ROOT / 'parity/candidate.jl')], input_text=payload))
        candidate_requests = server.drain()
    finally:
        server.close()
    for result, requests in [(oracle, oracle_requests), (candidate, candidate_requests)]:
        for entry, scenario in zip(result, scenarios, strict=True):
            if scenario['family'] == 'wire':
                entry['result']['requests'] = requests.get(entry['id'], [])
                if not entry['result']['requests']:
                    raise ValueError(f"No actual HTTP request for {entry['id']}")
    scenario_ids = [scenario['id'] for scenario in scenarios]
    for name, result in [('Pi', oracle), ('Julia', candidate)]:
        if [entry['id'] for entry in result] != scenario_ids:
            raise ValueError(f'{name} returned missing, duplicate, or reordered scenarios')
    failures = []
    failure_details = {}
    for expected, actual in zip(oracle, candidate, strict=True):
        if expected != actual:
            scenario_id = expected['id']
            failures.append(scenario_id)
            before = json.dumps(expected, ensure_ascii=False, sort_keys=True, indent=2).splitlines(True)
            after = json.dumps(actual, ensure_ascii=False, sort_keys=True, indent=2).splitlines(True)
            difference = ''.join(difflib.unified_diff(before, after, fromfile='pinned Pi', tofile='Julia Forever 2'))
            failure_details[scenario_id] = {'oracle': expected, 'candidate': actual, 'diff': difference}
            print(f'Differential mismatch: {scenario_id}; full traces retained in report', file=sys.stderr)
    gaps = sorted(name for name, entry in capabilities.items() if entry['status'] != 'differential')
    complete = not failures and not gaps and manifest['inventory_complete']
    failed_contracts = {capability for scenario in scenarios if scenario['id'] in failures
                        for capability in scenario['capabilities']}
    report = {
        'baseline': commit, 'oracle': 'unmodified upstream source',
        'scenario_count': len(scenarios), 'failed_scenarios': failures,
        'differential_contracts': sorted(covered), 'gaps': gaps,
        'verified_contracts': sorted(covered - failed_contracts),
        'inventory_complete': manifest['inventory_complete'], 'full_parity_established': complete,
        'projection': manifest['projection'],
    }
    if arguments.report:
        report_path = Path(arguments.report)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps({**report, 'failure_details': failure_details}, indent=2) + '\n')
    elif failure_details:
        for detail in failure_details.values():
            sys.stderr.write(detail['diff'] + '\n')
    print(json.dumps(report, indent=2))
    return int(bool(failures) or (arguments.require_complete and not complete))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f'Pi differential verification failed: {error}', file=sys.stderr)
        sys.exit(1)
