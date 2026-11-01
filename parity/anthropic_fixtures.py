"""Anthropic inputs for the real upstream differential oracle."""
import json


def anthropic_scenarios() -> list[dict]:
    scenarios = []
    for case in ['text', 'thinking', 'redacted', 'tools', 'length', 'refusal', 'sensitive', 'cache-one-hour',
                 'missing-stop', 'missing-reason']:
        for fragment in [1, 7, 4096]:
            events = [{'type': 'message_start', 'message': {
                'id': 'anthropic-response', 'model': 'served-fixture', 'role': 'assistant',
                'content': [], 'stop_reason': None,
                'usage': {'input_tokens': 24, 'output_tokens': 0,
                          'cache_read_input_tokens': 5, 'cache_creation_input_tokens': 3},
            }}]
            if case == 'cache-one-hour':
                events[0]['message']['usage']['cache_creation'] = {'ephemeral_1h_input_tokens': 2}
            if case == 'thinking':
                events.extend([
                    {'type': 'content_block_start', 'index': 0,
                     'content_block': {'type': 'thinking', 'thinking': '', 'signature': ''}},
                    {'type': 'content_block_delta', 'index': 0,
                     'delta': {'type': 'thinking_delta', 'thinking': 'Plan λ'}},
                    {'type': 'content_block_delta', 'index': 0,
                     'delta': {'type': 'signature_delta', 'signature': 'opaque-'}},
                    {'type': 'content_block_delta', 'index': 0,
                     'delta': {'type': 'signature_delta', 'signature': 'signature'}},
                    {'type': 'content_block_stop', 'index': 0},
                ])
            if case == 'redacted':
                events.extend([
                    {'type': 'content_block_start', 'index': 0,
                     'content_block': {'type': 'redacted_thinking', 'data': 'opaque-redacted-data'}},
                    {'type': 'content_block_stop', 'index': 0},
                ])
            if case == 'tools':
                for index, name in [(0, 'inspect'), (1, 'count')]:
                    events.append({'type': 'content_block_start', 'index': index,
                                   'content_block': {'type': 'tool_use', 'id': f'call-{index}',
                                                     'name': name, 'input': {}}})
                for index, argument in [(0, '{"path":'), (1, '{"n":2}'), (0, '"日本語"}')]:
                    events.append({'type': 'content_block_delta', 'index': index,
                                   'delta': {'type': 'input_json_delta', 'partial_json': argument}})
                events.extend([{'type': 'content_block_stop', 'index': 1},
                               {'type': 'content_block_stop', 'index': 0}])
            else:
                events.extend([
                    {'type': 'content_block_start', 'index': 1,
                     'content_block': {'type': 'text', 'text': ''}},
                    {'type': 'content_block_delta', 'index': 1,
                     'delta': {'type': 'text_delta', 'text': 'Hello λ'}},
                    {'type': 'content_block_delta', 'index': 1,
                     'delta': {'type': 'text_delta', 'text': ' / 日本語'}},
                    {'type': 'content_block_stop', 'index': 1},
                ])
            reason = {'length': 'max_tokens', 'refusal': 'refusal', 'sensitive': 'sensitive',
                      'tools': 'tool_use', 'missing-reason': None}.get(case, 'end_turn')
            delta = {'stop_reason': reason, 'stop_sequence': None}
            if case == 'refusal':
                delta['stop_details'] = {'explanation': 'Fixture refusal explanation'}
            events.append({'type': 'message_delta', 'delta': delta,
                           'usage': {'output_tokens': 9, 'output_tokens_details': {'thinking_tokens': 2}}})
            if case != 'missing-stop':
                events.append({'type': 'message_stop'})
            response = ''.join(f'event: {event["type"]}\ndata: ' + json.dumps(event, ensure_ascii=False)
                               + '\n\n' for event in events)
            scenarios.append({
                'id': f'anthropic-{case}-bytes-{fragment}', 'family': 'wire', 'protocol': 'anthropic',
                'capabilities': ['provider-protocol.anthropic-streaming'],
                'model': {'provider': 'fixture', 'id': 'fixture-claude', 'api': 'anthropic-messages',
                          'name': 'Offline fixture', 'reasoning': False, 'input': ['text'],
                          'contextWindow': 4096, 'maxTokens': 1024,
                          'cost': {'input': 1, 'output': 2, 'cacheRead': 0.25, 'cacheWrite': 1.5}},
                'instructions': 'Be precise.', 'prompt': 'Explain λ.',
                'options': {'maxTokens': 128, 'temperature': 0},
                'fragment': fragment, 'response': response,
            })
            if case == 'cache-one-hour':
                scenarios[-1]['model']['cost']['cacheWrite1h'] = 2
    return scenarios
