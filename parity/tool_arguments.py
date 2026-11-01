"""Tool-argument repair inputs; expected results come only from unmodified Pi."""
from __future__ import annotations

from copy import deepcopy
import json


def argument_inputs() -> dict[str, str]:
    return {
        'invalid-escapes': r'{"path":"C:\work\project","label":"日本語"}',
        'raw-controls': '{"text":"' + ''.join(chr(value) for value in range(32)) + '","label":"λ"}',
        'invalid-unicode': r'{"text":"\u12G4 / \u12 / \z"}',
        'valid-escapes': r'{"text":"quote \" slash \\ solidus \/ backspace \b formfeed \f newline \n return \r tab \t"}',
        'unicode-escapes': r'{"text":"\u03bb \u65e5\ud83d\ude80"}',
        'control-keys': '{"key\nλ":"value\t日本語"}',
        'mixed-nested': '{"items":[{"path":"C:\\work"},{"text":"line\nnext"}],'
                        '"valid":"\\u03bb","count":2,"enabled":true,"missing":null}',
    }


def replace_arguments(response: str, protocol: str, arguments: str) -> str:
    packets = []
    targets = []
    for packet in response.strip().split('\n\n'):
        lines = packet.splitlines()
        data = next((line[6:] for line in lines if line.startswith('data: ')), None)
        if data is None or data == '[DONE]':
            packets.append((lines, None))
            continue
        event = json.loads(data)
        packets.append((lines, event))
        if protocol == 'openai':
            for choice in event.get('choices', []):
                for tool in choice.get('delta', {}).get('tool_calls', []):
                    if tool.get('index') == 0 and 'arguments' in tool.get('function', {}):
                        targets.append((tool['function'], 'arguments'))
        elif event.get('type') == 'content_block_delta' and event.get('index') == 0:
            if event['delta'].get('type') == 'input_json_delta':
                targets.append((event['delta'], 'partial_json'))
    if len(targets) != 2:
        raise ValueError(f'Expected two fragments for the first {protocol} tool, got {len(targets)}')
    # Split immediately after a backslash when present; HTTP fragments also split UTF-8 bytes.
    boundary = arguments.index('\\') + 1 if '\\' in arguments else len(arguments) // 2
    for (target, field), fragment in zip(targets, (arguments[:boundary], arguments[boundary:])):
        target[field] = fragment
    result = []
    for lines, event in packets:
        result.append('\n'.join(
            'data: ' + json.dumps(event, ensure_ascii=False)
            if event is not None and line.startswith('data: ') else line
            for line in lines
        ))
    return '\n\n'.join(result) + '\n\n'


def tool_argument_scenarios(scenarios: list[dict]) -> list[dict]:
    prototypes = {
        scenario['id']: scenario for scenario in scenarios
        if scenario['family'] == 'wire'
        and scenario['id'] == f'{scenario["protocol"]}-tools-bytes-{scenario["fragment"]}'
    }
    required = {
        f'{protocol}-tools-bytes-{fragment}'
        for protocol in ('openai', 'anthropic') for fragment in (1, 7, 4096)
    }
    missing = required - prototypes.keys()
    if missing:
        raise ValueError(f'Missing tool-argument fixture prototypes: {sorted(missing)}')
    result = []
    for identifier in sorted(required):
        prototype = prototypes[identifier]
        for name, arguments in argument_inputs().items():
            scenario = deepcopy(prototype)
            scenario['id'] = f'{scenario["protocol"]}-tool-arguments-{name}-bytes-{scenario["fragment"]}'
            scenario['response'] = replace_arguments(scenario['response'], scenario['protocol'], arguments)
            result.append(scenario)
    return result
