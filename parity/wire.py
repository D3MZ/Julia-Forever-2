"""Local transport fixtures; only upstream execution determines expected behavior."""
from __future__ import annotations

from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from threading import Lock, Thread
from urllib.parse import urlsplit


class FixtureServer:
    def __init__(self, scenarios: list[dict]):
        self.scenarios = {scenario['id']: scenario for scenario in scenarios if scenario['family'] == 'wire'}
        self.requests = defaultdict(list)
        self.lock = Lock()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, format, *arguments):
                return

            def do_POST(self):
                parts = urlsplit(self.path).path.split('/')
                identifier = parts[2] if len(parts) > 2 and parts[1] == 'fixture' else ''
                scenario = owner.scenarios.get(identifier)
                if scenario is None:
                    self.send_error(404, 'Unknown differential fixture')
                    return
                data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
                headers = {name: self.headers[name] for name in
                           ['authorization', 'content-type', 'x-api-key', 'anthropic-version', 'x-goog-api-key']
                           if name in self.headers}
                observation = {'method': 'POST', 'path': self.path, 'headers': headers,
                               'body': json.loads(data)}
                with owner.lock:
                    owner.requests[identifier].append(observation)
                payload = scenario['response'].encode('utf-8')
                self.send_response(scenario.get('status', 200))
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                width = scenario.get('fragment', len(payload) or 1)
                for offset in range(0, len(payload), width):
                    self.wfile.write(payload[offset:offset + width])
                    self.wfile.flush()

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f'http://127.0.0.1:{self.server.server_port}'

    def drain(self) -> dict:
        with self.lock:
            result = dict(self.requests)
            self.requests.clear()
            return result

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


def wire_scenarios() -> list[dict]:
    scenarios = []
    for case in ['text', 'thinking', 'tools', 'length', 'filtered', 'missing-finish', 'empty']:
        for fragment in [1, 7, 4096]:
            identifier = f'openai-{case}-bytes-{fragment}'
            specification = {
                'provider': 'fixture', 'id': 'fixture-chat', 'api': 'openai-completions',
                'name': 'Offline fixture', 'reasoning': False, 'input': ['text'],
                'contextWindow': 4096, 'maxTokens': 1024,
                'cost': {'input': 1, 'output': 2, 'cacheRead': 0.25, 'cacheWrite': 1.5},
                'compat': {'supportsStore': fragment != 7,
                           'supportsUsageInStreaming': True, 'supportsDeveloperRole': True,
                           'maxTokensField': 'max_tokens' if fragment == 7 else 'max_completion_tokens'},
            }
            chunks = []
            def add(delta, reason=None, **fields):
                chunks.append({'id': 'response-fixture', 'model': 'served-fixture',
                               'choices': [{'index': 0, 'delta': delta, 'finish_reason': reason}], **fields})
            if case == 'thinking':
                add({'reasoning_content': 'Plan λ', 'reasoning': 'duplicated', 'content': 'Answer '})
                add({'reasoning_content': ' continued', 'content': '日本語'})
            elif case == 'tools':
                add({'tool_calls': [{'index': 0, 'id': 'call-one', 'type': 'function',
                                     'function': {'name': 'inspect', 'arguments': '{"path":'}}]})
                add({'tool_calls': [{'index': 1, 'id': 'call-two', 'type': 'function',
                                     'function': {'name': 'count', 'arguments': '{"n":2}'}},
                                    {'index': 0, 'function': {'arguments': '"日本語"}'}}]})
            elif case != 'empty':
                add({'content': 'Hello λ'})
                add({'content': ' / 日本語'})
            if case != 'missing-finish':
                reason = {'length': 'length', 'filtered': 'content_filter', 'tools': 'tool_calls'}.get(case, 'stop')
                add({}, reason)
            chunks.append({'id': 'response-fixture', 'choices': [],
                           'usage': {'prompt_tokens': 24, 'completion_tokens': 9,
                                     'prompt_tokens_details': {'cached_tokens': 5, 'cache_write_tokens': 3},
                                     'completion_tokens_details': {'reasoning_tokens': 2}}})
            response = ''.join('data: ' + json.dumps(chunk, ensure_ascii=False) + '\n\n' for chunk in chunks)
            response += 'data: [DONE]\n\n'
            scenarios.append({'id': identifier, 'family': 'wire', 'protocol': 'openai',
                              'capabilities': ['provider-protocol.openai-streaming'],
                              'model': specification, 'instructions': 'Be precise.', 'prompt': 'Explain λ.',
                              'options': {'maxTokens': 128, 'temperature': 0},
                              'fragment': fragment, 'response': response})
    return scenarios
