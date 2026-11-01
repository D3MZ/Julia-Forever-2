import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { readFileSync, realpathSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const release = '0.2.2-alpha.2';
const localKey = 'dsh-differential-local-only';
const firstPrompt = 'Remember the token sapphire.';
const resumedPrompt = 'What token did I ask you to remember?';
const localResponse = 'Recorded sapphire.';
let input = '';
for await (const chunk of process.stdin) input += chunk;
const request = JSON.parse(input);
const binary = realpathSync(request.binary);
const lock = JSON.parse(readFileSync(new URL('./reference-lock.json', import.meta.url), 'utf8'));
const sourceRoot = resolve(dirname(binary), '../../..');
const referenceCommit = execFileSync('git', ['-C', sourceRoot, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
if (referenceCommit !== lock.commit) throw new Error(`Expected DSH source ${lock.commit}, received ${referenceCommit}`);
if (binary !== realpathSync(join(sourceRoot, 'apps/cli/lib/bin.js'))) {
  throw new Error('Runtime differential requires the CLI built from the pinned source checkout');
}
if (execFileSync('git', ['-C', sourceRoot, 'status', '--porcelain', '--untracked-files=no'], { encoding: 'utf8' }).trim()) {
  throw new Error('Runtime differential requires an unmodified DSH source checkout');
}
const requireRuntime = createRequire(pathToFileURL(binary));
const manifest = JSON.parse(readFileSync(requireRuntime.resolve('@deepseek-ai/dsh/package.json'), 'utf8'));
if (manifest.version !== release) throw new Error(`Expected DSH ${release}, received ${manifest.version}`);

function environment(home) {
  const values = {
    ...process.env,
    DSH_HOME: home,
    DSH_TELEMETRY_DISABLED: '1',
    DEEPSEEK_API_KEY: '',
    DSH_PERMISSION_MODE: 'read-only',
  };
  for (const name of ['DEEPSEEK_BASE_URL', 'DSH_PRIMARY_RUNTIME',
    'DSH_BUNDLED_PRIMARY_RUNTIME', 'DSH_BUNDLED_OFFICE_CLI']) delete values[name];
  if (typeof request.modelUrl === 'string') {
    if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(request.modelUrl)) throw new Error('Model fixture must bind IPv4 loopback');
    values.DEEPSEEK_BASE_URL = request.modelUrl;
    values.DEEPSEEK_API_KEY = localKey;
  }
  return values;
}

function launch(profile, home, arguments_ = []) {
  return spawn(process.execPath, ['--disable-warning=ExperimentalWarning', binary,
    '--profile', profile, ...arguments_], {
    cwd: request.directory,
    env: environment(home),
    stdio: ['pipe', 'pipe', 'pipe'],
  });
}

function exited(child) {
  return new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
}

function settleChild(child, exit) {
  const timer = setTimeout(() => child.kill('SIGKILL'), 10000);
  return exit.finally(() => clearTimeout(timer));
}

function normalizeError(error) {
  return { ok: false, value: null, error: {
    code: error.code ?? null, message: error.message, data: error.data ?? null,
  } };
}

async function invoke(transport, method, params) {
  try {
    const value = await transport.request(method, params, AbortSignal.timeout(30000));
    return { ok: true, value: value ?? null, error: null };
  } catch (error) {
    return normalizeError(error);
  }
}

function notification(method, params) {
  if (method === 'session.event') {
    return { method, sessionId: params.sessionId, type: params.event.type };
  }
  return { method, params };
}

async function sdk() {
  const protocolPath = join(sourceRoot, 'packages/sdk/protocol/lib/index.js');
  const { JsonRpcLineTransport } = await import(pathToFileURL(protocolPath).href);
  const child = launch(request.profile ?? 'sdk', request.home);
  const exit = exited(child);
  let diagnostics = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => { diagnostics = (diagnostics + chunk).slice(-40000); });
  const events = [];
  const transport = new JsonRpcLineTransport(child.stdout, child.stdin);
  transport.onNotification((method, params) => events.push(notification(method, params)));
  transport.start();
  const operations = [];
  const call = async (name, method, params) => {
    const result = await invoke(transport, method, params);
    operations.push({ name, result });
    return result;
  };
  try {
    const rejected = await call('prompt-before-initialize', 'session/prompt', {
      sessionId: 'differential-idle', contentBlocks: [{ type: 'text', text: 'must not execute' }],
    });
    if (rejected.ok || rejected.error.message !== 'SDK server is not initialized') {
      throw new Error(`DSH did not reject an uninitialized prompt: ${JSON.stringify(rejected)}`);
    }
    const initialized = await call('initialize', 'initialize', {
      cwd: request.directory, provider: 'deepseek-official', model: 'deepseek-flash',
    });
    if (!initialized.ok) throw new Error(`DSH did not initialize: ${JSON.stringify(initialized)}\n${diagnostics}`);
    const session = { sessionId: 'differential-idle' };
    await call('working-directory-get', 'session/working-directory/get', session);
    await call('working-directory-set', 'session/working-directory/set', { ...session, path: 'child' });
    await call('working-directory-after-set', 'session/working-directory/get', session);
    await call('wait-idle', 'session/wait', session);
    const emptyQuery = await call('empty-query', 'session/query', { ...session, contentBlocks: [] });
    const blankQuery = await call('blank-query', 'session/query', { ...session, contentBlocks: [{ type: 'text', text: ' \n ' }] });
    for (const result of [emptyQuery, blankQuery]) {
      if (result.ok || !result.error.message.startsWith('session/query requires ')) {
        throw new Error(`DSH did not validate session/query: ${JSON.stringify(result)}\n${diagnostics}`);
      }
    }
    await call('missing-directory', 'session/working-directory/set', { ...session, path: 'does-not-exist' });
    await call('directory-after-failure', 'session/working-directory/get', session);
    await call('missing-session-resume', 'session/resume', { sessionId: 'differential-absent' });
    await call('unknown-method', 'differential/unknown', {});
    await call('shutdown', 'shutdown', {});
    const stopped = await settleChild(child, exit);
    return { release, referenceCommit, operations, events, exit: stopped.code };
  } finally {
    transport.close();
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    await settleChild(child, exit);
  }
}

async function localModelFixture() {
  const { startMockLlmServer } = await import(pathToFileURL(join(sourceRoot, 'packages/test-support/llm-mock-server/lib/index.js')).href);
  const server = await startMockLlmServer({ host: '127.0.0.1', port: 0, apiKey: localKey,
    sequence: ['success', 'success', 'success', 'success'], successText: localResponse, randomSeed: 1, chunkSize: 3 });
  const stopping = new Promise(resolveStopped => process.once('SIGTERM', resolveStopped));
  process.stdout.write(JSON.stringify({ baseURL: server.baseURL }) + '\n');
  await stopping;
  await server.close();
  const requests = server.requests.map(record => {
    const body = record.body;
    const messages = body.messages.map(message => ({ ...message,
      content: Array.isArray(message.content) ? message.content.map(block => {
        if (block.type !== 'text' || !block.text.startsWith('Time sampled while preparing turn ')) return block;
        return { ...block, text: block.text
          .replace(/^(Time sampled while preparing turn \d+, step \d+: )[^\n]+/, '$1<timestamp>')
          .replace(/^(Elapsed since the preceding [^:]+: )[^\n]+/m, '$1<elapsed>') };
      }) : message.content,
    }));
    const history = [];
    for (const message of body.messages ?? []) {
      const text = typeof message.content === 'string' ? message.content
        : message.content.filter(block => block.type === 'text').map(block => block.text).join('\n');
      for (const marker of [firstPrompt, localResponse, resumedPrompt]) {
        if (text.includes(marker)) history.push({ role: message.role, text: marker });
      }
    }
    return { path: record.path, behavior: record.behavior, outcome: record.outcome,
      model: body.model, maxTokens: body.max_tokens, stream: body.stream, messages, history };
  });
  return { requests };
}

async function successfulTurns() {
  const { HarnessClient } = await import(pathToFileURL(join(sourceRoot, 'packages/sdk/client/lib/index.js')).href);
  const { finalResponse } = await import(pathToFileURL(join(sourceRoot, 'packages/sdk/client/lib/types/api.js')).href);
  const phases = [];
  for (const resume of [false, true]) {
    const client = new HarnessClient({ dshBin: binary, profile: 'sdk', dshHome: request.home,
      processCwd: request.directory, env: environment(request.home), initializeTimeoutMs: 30000,
      requestTimeoutMs: 30000, shutdownTimeoutMs: 10000 });
    const subscription = client.subscribe();
    try {
      const initialized = await client.initialize({ cwd: resume ? join(request.directory, 'child') : request.directory,
        provider: 'deepseek-official', model: 'deepseek-v4-flash', maxTokens: 128 });
      const sessionId = 'differential-persisted';
      const restored = resume ? await client.request('session/resume', { sessionId }) : null;
      const directory = await client.getWorkingDirectory(sessionId);
      const receipt = await client.prompt(sessionId, [{ type: 'text', text: resume ? resumedPrompt : firstPrompt }]);
      const waited = await client.request('session/wait', { sessionId });
      const notifications = [];
      let item;
      while ((item = subscription.tryNext()) !== undefined) notifications.push(item);
      const events = notifications.filter(item => item.method === 'session.event').map(item => item.params.event);
      const response = finalResponse(events);
      if (response !== localResponse) throw new Error(`Local fixture did not complete a successful agent turn: ${JSON.stringify(response)}`);
      phases.push({ initialized: initialized.serverInfo, restored, directory,
        receipt: typeof receipt === 'string' && receipt.length > 0, waited,
        finalResponse: response, finishReason: events.findLast(event => event.type === 'turn/end')?.data.reason.kind ?? null,
        notifications: notifications.map(item => notification(item.method, item.params)) });
    } finally {
      subscription.close();
      await client.close();
    }
  }
  return { release, referenceCommit, phases };
}

async function configuration() {
  const results = [];
  for (const profile of ['web', 'headless', 'sdk', 'sdk-minimal', 'acp']) {
    const home = join(request.home, profile);
    const child = launch(profile, home, ['--dump-config']);
    const exit = exited(child);
    const output = [];
    const diagnostics = [];
    child.stdout.on('data', chunk => output.push(chunk));
    child.stderr.on('data', chunk => diagnostics.push(chunk));
    const stopped = await settleChild(child, exit);
    const normalize = value => value.split(home).join('<home>').replaceAll('\r\n', '\n');
    results.push({ profile, exit: stopped.code,
      output: normalize(Buffer.concat(output).toString('utf8')),
      diagnostics: normalize(Buffer.concat(diagnostics).toString('utf8')) });
  }
  return { release, referenceCommit, profiles: results };
}

async function httpObservation(url, options = {}, replacements = []) {
  const response = await fetch(url, { ...options, redirect: 'manual', signal: AbortSignal.timeout(10000) });
  let body = Buffer.from(await response.arrayBuffer());
  if (replacements.length) {
    let text = body.toString('utf8');
    for (const [source, target] of replacements) text = text.split(source).join(target);
    body = Buffer.from(text);
  }
  return { response, observation: {
    status: response.status,
    contentType: response.headers.get('content-type'),
    cacheControl: response.headers.get('cache-control'),
    etag: response.headers.get('etag'),
    bodyBytes: body.length,
    bodySha256: createHash('sha256').update(body).digest('hex'),
  } };
}

async function web() {
  const child = launch('web', request.home, ['--no-open', '--host', '127.0.0.1', '--port', '0']);
  const exit = exited(child);
  let output = '';
  let diagnostics = '';
  let timer;
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => { diagnostics = (diagnostics + chunk).slice(-40000); });
  const ready = new Promise((resolveReady, rejectReady) => {
    timer = setTimeout(() => rejectReady(new Error(`DSH Web did not become ready\n${diagnostics}`)), 30000);
    child.stdout.on('data', chunk => {
      output += chunk;
      const match = output.match(/dsh web: (http:\/\/127\.0\.0\.1:\d+\/\S*)/);
      if (match) resolveReady(match[1]);
    });
    exit.then(() => rejectReady(new Error(`DSH Web exited before readiness\n${diagnostics}`)), rejectReady);
  });
  try {
    const authenticatedUrl = await ready;
    clearTimeout(timer);
    const origin = new URL(authenticatedUrl).origin;
    const responses = [];
    for (const [method, path] of [['GET', '/'], ['HEAD', '/'], ['GET', '/index.html'],
      ['GET', '/api/'], ['GET', '/connect'], ['POST', '/'], ['GET', '/__dsh_differential_missing__.js']]) {
      const { observation } = await httpObservation(origin + path, { method });
      responses.push({ method, path, ...observation });
    }
    const trustCases = JSON.parse(readFileSync(new URL('./web-request-trust.json', import.meta.url), 'utf8'));
    const trust = [];
    for (const entry of trustCases) {
      const headers = Object.fromEntries(Object.entries(entry.headers).map(([name, value]) =>
        [name, value.replaceAll('<port>', new URL(origin).port)]));
      const probe = await fetch(origin + '/api/', {
        headers, redirect: 'manual', signal: AbortSignal.timeout(10000),
      });
      trust.push({ name: entry.name, admitted: probe.status !== 403 });
      await probe.arrayBuffer();
    }
    const exchange = await fetch(authenticatedUrl, { redirect: 'manual', signal: AbortSignal.timeout(10000) });
    const cookie = exchange.headers.get('set-cookie')?.split(';')[0];
    await exchange.arrayBuffer();
    if (exchange.status !== 303 || !cookie) throw new Error('DSH Web did not exchange its launch token for a browser cookie');
    const authentication = {
      status: exchange.status, location: exchange.headers.get('location'),
      cacheControl: exchange.headers.get('cache-control'),
      referrerPolicy: exchange.headers.get('referrer-policy'),
    };
    const index = await httpObservation(origin + '/', { headers: { cookie } }, [[request.home, '<home>'], [origin, '<origin>']]);
    if (index.observation.status !== 200 || !index.observation.contentType?.startsWith('text/html')) {
      throw new Error('DSH Web did not serve the authenticated built frontend');
    }
    const asset = await httpObservation(origin + '/favicon.svg');
    if (asset.observation.status !== 200 || asset.observation.bodyBytes === 0 || !asset.observation.etag) {
      throw new Error('DSH Web did not serve its built static asset');
    }
    const cached = await httpObservation(origin + '/favicon.svg', { headers: { 'if-none-match': asset.observation.etag } });
    child.kill('SIGTERM');
    const stopped = await settleChild(child, exit);
    return { release, referenceCommit, responses, trust, authentication,
      index: index.observation, asset: asset.observation, cached: cached.observation,
      exit: stopped.code, signal: stopped.signal };
  } finally {
    clearTimeout(timer);
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    await settleChild(child, exit);
  }
}

const result = request.kind === 'sdk' ? await sdk()
  : request.kind === 'model-fixture' ? await localModelFixture()
  : request.kind === 'successful-turns' ? await successfulTurns()
  : request.kind === 'web' ? await web() : await configuration();
process.stdout.write(JSON.stringify(result) + '\n');
