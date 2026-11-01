"""Deterministic inputs only: expected behavior always comes from pinned Pi."""
from __future__ import annotations

import random

REGISTRY_CONTRACTS = [
    'provider-registry.replacement', 'model-catalog.typed-lookup',
    'provider-dispatch.selected-backend', 'model-catalog.failure-isolation',
]
STORE_CONTRACTS = ['model-store.copy-isolation', 'model-store.opaque-metadata']


def model(provider: str, identifier: str, kind: str | None = None) -> dict:
    result = {
        'provider': provider, 'id': identifier, 'name': identifier, 'api': 'fixture',
        'baseUrl': 'https://example.invalid', 'reasoning': False, 'input': ['text'],
        'contextWindow': 4096, 'maxTokens': 1024,
        'cost': dict.fromkeys(['input', 'output', 'cacheRead', 'cacheWrite'], 0),
        'extensionMetadata': {'nested': [{'kept': True}], 'unicode': 'λ / 日本語'},
    }
    if kind is not None:
        result['type'] = kind
    return result


def provider(identifier: str, prefix: str, *, broken: bool = False) -> dict:
    return {
        'id': identifier, 'prefix': prefix, 'catalog_error': broken,
        'models': [model(identifier, 'shared'), model(identifier, 'second', 'chat'),
                   model(identifier, 'shared', 'image'), model(identifier, 'shared', 'classifier')],
    }


def register(identifier: str, prefix: str, *, broken: bool = False) -> dict:
    return {'operation': 'register', 'provider': provider(identifier, prefix, broken=broken)}


def build_scenarios() -> list[dict]:
    steps = [
        register('alpha', 'original'), register('beta', 'other'),
        dict(operation='dispatch', provider='alpha', id='shared', prompt='before'),
        register('alpha', 'replacement'), dict(operation='providers'),
        dict(operation='dispatch', provider='alpha', id='shared', prompt='after'),
        dict(operation='models', kind='all'),
        dict(operation='lookup', provider='alpha', id='shared', kind='classifier'),
        register('broken', 'failure', broken=True), dict(operation='models', kind='all'),
        dict(operation='models', provider='broken', kind='all'),
        dict(operation='delete', provider='alpha'),
        dict(operation='dispatch', provider='alpha', id='shared', prompt='deleted'),
    ]
    scenarios = [dict(id='replacement-routing-and-failure-isolation', family='registry',
                      capabilities=REGISTRY_CONTRACTS, steps=steps)]
    for seed in range(724901, 724917):
        generator = random.Random(seed)
        steps = []
        for index in range(40):
            identifier = generator.choice(['alpha', 'beta', 'gamma', 'δelta'])
            operation = generator.choice(['register', 'register', 'delete', 'clear',
                                          'providers', 'models', 'lookup', 'dispatch'])
            kind = generator.choice(['chat', 'image', 'classifier'])
            if operation == 'register':
                step = register(identifier, f'generation-{seed}-{index}', broken=index % 7 == 0)
            elif operation in ('clear', 'providers'):
                step = dict(operation=operation)
            elif operation == 'models':
                step = dict(operation=operation, kind=generator.choice([kind, 'all']))
                if generator.choice([False, True]):
                    step['provider'] = identifier
            elif operation == 'lookup':
                step = dict(operation=operation, provider=identifier, kind=kind,
                            id=generator.choice(['shared', 'second', 'missing']))
            elif operation == 'dispatch':
                step = dict(operation=operation, provider=identifier, id='shared', prompt=f'λ_日本語_{index}')
            else:
                step = dict(operation=operation, provider=identifier)
            steps.append(step)
        scenarios.append(dict(id=f'registry-seed-{seed}', family='registry',
                              capabilities=REGISTRY_CONTRACTS, steps=steps))
    for index in range(8):
        entry = dict(models=[model('alpha', f'model-{index}')], etag=f'W/"opaque-{index}-λ"',
                     lastModified=1700000000 + index, checkedAt=1700000010 + index,
                     providerState={'unknown': {'values': [1, 2, 3]}})
        steps = [
            dict(operation='read', provider='alpha', variable='missing'),
            dict(operation='write', provider='alpha', variable='input', entry=entry),
            dict(operation='mutate', variable='input', path=['models', 0, 'id'], value='mutated-input'),
            dict(operation='read', provider='alpha', variable='snapshot'),
            dict(operation='mutate', variable='snapshot', path=['providerState', 'unknown', 'values', 1], value=99),
            dict(operation='mutate', variable='snapshot', path=['etag'], value='changed'),
            dict(operation='read', provider='alpha', variable='snapshot-again'),
            dict(operation='write', provider='beta', variable='other-input', entry=entry),
            dict(operation='delete', provider='alpha'),
            dict(operation='read', provider='alpha', variable='removed'),
            dict(operation='read', provider='beta', variable='other'),
            dict(operation='delete', provider='not-present'),
            dict(operation='read', provider='beta', variable='other-again'),
        ]
        scenarios.append(dict(id=f'model-store-isolation-{index}', family='store',
                              capabilities=STORE_CONTRACTS, steps=steps))
    return scenarios
