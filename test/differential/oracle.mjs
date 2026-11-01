import { PassThrough, Writable } from 'node:stream'
import { createInterface } from 'node:readline'
import { spawn } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { resolve } from 'node:path'
import { importSource, referenceSource, referenceRoot, cordisReference, scopedReference, toolsReference } from './reference.mjs'
const { formatSessionMarkdown } = await importSource('packages/session-query/session-log-export/src/markdown.ts')
const { normalizeSessionTitle, fallbackSessionTitle, truncateTitleUtf8 } = await importSource('packages/session/session-title/src/normalize.ts')
const { filterSessionEventDocuments, filterSessionResults } = await import(pathToFileURL(resolve(referenceRoot, 'packages/session-query/session-query/src/filters.ts')).href)
const { assertSupportedJsonSchema, validateJsonSchemaValue } = await import(pathToFileURL(resolve(referenceRoot, 'packages/core/tools/src/json-schema.ts')).href)
const { executeToolBatch } = await import(pathToFileURL(resolve(referenceRoot, 'packages/core/tools/src/batch.ts')).href)
const { ApprovalReference } = await importSource('packages/core/tools/src/pipeline.ts', source => {
  const start = source.indexOf('  private async serviceAsk(')
  const end = source.indexOf('  /**\n   * Run the `tools/post-execute`', start)
  if (start < 0 || end < 0) throw new Error('Locked DSH approval method boundaries were not found')
  return 'export class ApprovalReference { constructor(ctx) { this.ctx = ctx }\n'
    + source.slice(start, end) + '\n}'
})

const { ToolCancellationReference } = await importSource('packages/core/tools/src/pipeline.ts', source => {
  const start = source.indexOf('  private async dispatchToolBody(')
  const end = source.indexOf('  /**\n   * Run around-dispatch', start)
  const helpers = source.indexOf('function isAborted(')
  const helpersEnd = source.indexOf('export { executeToolBatch }', helpers)
  if (start < 0 || end < 0 || helpers < 0 || helpersEnd < 0) {
    throw new Error('Locked DSH tool cancellation method boundaries were not found')
  }
  return `const TOOL_ABORTED = 'ABORTED'
const TOOL_ABORTED_BEFORE_DISPATCH = 'ABORTED_BEFORE_DISPATCH'
${source.slice(helpers, helpersEnd)}
export class ToolCancellationReference {
  constructor(tool) {
    this.tool = tool
    this.cancellationStates = new WeakMap()
  }
  resolveExecution() { return this.tool }
  createSuccessResult(_execution, _tool, value) {
    return { isError: false, value, content: [] }
  }
${source.slice(start, end)}
}`
})
const { PostToolReference } = await importSource('packages/core/tools/src/pipeline.ts', source => {
  const start = source.indexOf('  private async postExecute(')
  const end = source.indexOf('  /** Registry-normalized results', start)
  const helperStart = source.indexOf('function failureMessageFromContent(')
  const helperEnd = source.indexOf('/** Snapshot and freeze one durable', helperStart)
  if ([start, end, helperStart, helperEnd].some(index => index < 0)) {
    throw new Error('Locked DSH post-execute method boundaries were not found')
  }
  return `${source.slice(helperStart, helperEnd)}
const scopeTarget = (service, scope) => service
export class PostToolReference {
  constructor(decision) {
    this.ctx = { waterfall: async () => decision }
    this.tools = {}
  }
  markCanonical(_exec, value) { return value }
${source.slice(start, end)}
}`
})
const { applyEntryPatches } = await importSource('vendor/include/src/index.ts', source => {
  const start = source.indexOf('export function applyEntryPatches(')
  const end = source.indexOf('/** Runtime patch applied to entries', start)
  if (start < 0 || end < 0) throw new Error('Locked DSH patch function boundaries were not found')
  return source.slice(start, end)
})
const { JsonRpcLineTransport } = await importSource('packages/sdk/protocol/src/transport.ts')
const { resolveDshLaunch } = await importSource('packages/sdk/client/src/launch.ts')
const { finalResponse } = await importSource('packages/sdk/client/src/api.ts', source => {
  const start = source.indexOf('export function finalResponse(')
  if (start < 0) throw new Error('Locked DSH finalResponse function was not found')
  return source.slice(start)
})
const { composeEntries } = await importSource('packages/boot/app-boot/src/profile.ts', source => {
  const start = source.indexOf('export function composeEntries(')
  if (start < 0) throw new Error('Locked DSH profile composition function was not found')
  const include = referenceSource('vendor/include/src/index.ts')
  const patchStart = include.indexOf('export function applyEntryPatches(')
  const patchEnd = include.indexOf('/** Runtime patch applied to entries', patchStart)
  return include.slice(patchStart, patchEnd) + '\n' + source.slice(start)
})
const { AcpSessionControlReference } = await importSource('packages/acp/acp/src/session.ts', source => {
  const prompt = source.indexOf('  async prompt(')
  const guardStart = source.indexOf('    if (this.inflight !== undefined) throw invalidParams(', prompt)
  const guardEnd = source.indexOf('\n    const completion', guardStart)
  const cancelStart = source.indexOf('  cancel(): void {', guardEnd)
  const cancelEnd = source.indexOf('\n  }', cancelStart) + 4
  if ([prompt, guardStart, guardEnd, cancelStart].some(index => index < 0)) {
    throw new Error('Pinned ACP prompt admission or cancellation method is unavailable')
  }
  return `const invalidParams = message => new Error(message)
export class AcpSessionControlReference {
  constructor(agent) { this.agent = agent; this.inflight = undefined }
  admit() {
${source.slice(guardStart, guardEnd)}
    this.inflight = { cancelled: false }
  }
  cancelPrompt() {
    if (this.inflight !== undefined) this.inflight.cancelled = true
  }
${source.slice(cancelStart, cancelEnd)}
}`
})

// Exercise pinned upstream fork-prefix and unfinished-turn closure code with no tool calls.
const { buildForkSeed } = await importSource('packages/core/session/src/fork.ts', source => {
  const repair = referenceSource('packages/core/session/src/repair.ts')
  const repairStart = repair.indexOf('export function openTurnClosers(')
  const repairEnd = repair.indexOf('\n/**\n * Track unanswered assistant tool requests', repairStart)
  const forkStart = source.indexOf('export function buildForkSeed(')
  if ([repairStart, repairEnd, forkStart].some(index => index < 0)) {
    throw new Error('Pinned session fork boundaries were not found')
  }
  // No tool calls occur in these fixtures. Recovering incomplete calls remains outside this oracle.
  return `const SessionSeq = value => value
class ToolCallRecovery {
  observe(_event) {}
  results() { return [] }
}
${repair.slice(repairStart, repairEnd)}
${source.slice(forkStart)}`
})

const settle = () => new Promise(resolve => setImmediate(resolve))

/** Render a deterministic test output projection, independent of the policy implementation. */
function completionDisplay(input, value) {
  if (input.format === 'label') return String(input.prefix ?? '') + value.label
  if (input.format === 'joined') return value.lines.join('|')
  return String(value)
}

/** Exercise pinned DSH post-execute decisions with deterministic tool output fixtures. */
async function toolCompletionCase(input) {
  const successful = (input.initial ?? 'success') === 'success'
  const initialValue = Object.hasOwn(input, 'initial_value') ? input.initial_value : 'done'
  const result = successful
    ? { isError: false, value: initialValue, content: [{ type: 'text', text: completionDisplay(input, initialValue) }] }
    : { isError: true, error: { message: 'denied' }, content: [{ type: 'text', text: 'denied' }] }
  const policy = input.policy === 'block'
    ? { kind: 'block', feedback: [{ type: 'text', text: input.message }] }
    : input.policy === 'replace'
      ? { kind: 'accept', content: [{ type: 'text', text: input.message }] }
      : input.policy === 'value'
        ? { kind: 'accept', value: input.value }
        : { kind: 'accept' }
  const reference = new PostToolReference(policy)
  let replacementRenders = 0
  // Inject a test-only tool contract. The policy method itself comes unchanged
  // from the pinned, hash-verified upstream source.
  reference.resolveExecution = () => ({ output: { schema: input.schema ?? { type: 'string' } } })
  reference.createSuccessResult = (_exec, tool, value) => {
    const violations = validateJsonSchemaValue(tool.output.schema, value, 'value')
    if (violations.length > 0) throw new TypeError('Invalid tool replacement')
    replacementRenders++
    return { isError: false, value, content: [{ type: 'text', text: completionDisplay(input, value) }] }
  }
  let completed
  try {
    completed = await reference.postExecute({ name: 'fixture', agent: {} }, result)
  } catch (error) {
    if (input.policy !== 'value') throw error
    return { ok: false, text: 'completion rejected', retained: null,
      called: input.initial !== 'guard', replacementRenders }
  }
  const observation = {
    ok: !completed.isError,
    text: completed.content.map(block => block.text).join('\n'),
    retained: completed.isError ? null : completed.value,
    called: input.initial !== 'guard',
  }
  if (input.policy === 'value') {
    if (completed.isError) observation.text = 'completion rejected'
    observation.replacementRenders = replacementRenders
  }
  return observation
}

/** Compare the original pinned upstream approval-resolution behavior in isolation. */
async function toolApprovalCase(input) {
  let available = input.channel !== 'missing'
  let requests = 0
  const service = { request: async () => {
    requests++
    return requests === 1 ? input.outcome : (input.next_outcome ?? input.outcome)
  } }
  const reference = new ApprovalReference({ get: key => key === 'approval' && available ? service : undefined })
  const exec = { name: 'fixture', agent: {}, callId: 'fixture-call', signal: new AbortController().signal }
  const ask = { kind: 'ask', ...Object.hasOwn(input, 'reason') ? { reason: input.reason } : {} }
  const project = resolution => ({
    allowed: resolution.decision.kind === 'allow',
    reason: resolution.decision.kind === 'allow' ? null : resolution.decision.reason,
    approvalCancelled: resolution.approvalCancelled,
  })
  const first = project(await reference.serviceAsk(exec, ask))
  if (!input.withdraw && !input.next_outcome) return first
  if (input.withdraw) available = false
  return [first, project(await reference.serviceAsk(exec, ask))]
}

/** Compare a real pinned DSH tool-body cancellation decision, not a runtime adapter. */
async function toolCancellationCase(input) {
  const controller = new AbortController()
  let invoked = 0
  const reference = new ToolCancellationReference({ execute: async () => {
    invoked++
    if (input.async) await settle()
    if (input.cancel_during) controller.abort()
    return input.value
  } })
  const exec = { name: 'fixture', arguments: {}, signal: controller.signal }
  reference.cancellationStates.set(exec, { callerSignal: controller.signal, bodyInvoked: false })
  if (input.cancel_before) controller.abort()
  const result = await reference.dispatchToolBody(exec)
  return { allowed: !result.isError, invoked, retained: result.isError ? null : result.value }
}

async function toolBatchCase(input) {
  const definitions = new Map(input.calls.filter(call => call.registered !== false).map(call => [call.id, call]))
  const entered = new Map(input.calls.map(call => [call.id, Promise.withResolvers()]))
  const controller = new AbortController()
  if (input.cancel_before) controller.abort()
  const started = []
  let active = 0
  let peak = 0
  let exclusiveSafe = true
  const outcome = await executeToolBatch({
    calls: input.calls.map(call => ({ id: call.id, name: call.id, arguments: '{}' })),
    signal: controller.signal,
    maxParallelToolCalls: input.max_parallel,
  }, {
    executionMode(exec) {
      return { kind: definitions.get(exec.callId)?.mode === 'parallel' ? 'parallel' : 'exclusive' }
    },
    async prepare(exec) {
      const specification = definitions.get(exec.callId)
      if (!specification || specification.deny) {
        return { kind: 'final-result', exec, result: {
          content: [{ type: 'text', text: 'Tool unavailable' }], isError: true,
        } }
      }
      return { kind: 'dispatch', exec }
    },
    async dispatch(exec) {
      const specification = definitions.get(exec.callId)
      const reference = new ToolCancellationReference({ execute: async () => {
        if (specification.mode !== 'parallel' && active !== 0) exclusiveSafe = false
        active++
        peak = Math.max(peak, active)
        started.push(specification.id)
        entered.get(specification.id).resolve()
        if (specification.wait_for) await entered.get(specification.wait_for).promise
        active--
        if (specification.cancel) controller.abort()
        return specification.id
      } })
      reference.cancellationStates.set(exec, { callerSignal: controller.signal, bodyInvoked: false })
      const result = await reference.dispatchToolBody(exec)
      return { kind: 'post-result', result }
    },
    async complete(exec, completed) { return completed.result },
  }, () => input.max_parallel)
  return {
    results: outcome.results.map(entry => ({ id: entry.callId, ok: !entry.result.isError })),
    executed: started.sort(),
    barrierSafe: exclusiveSafe,
    overlap: input.check_overlap ? peak >= 2 : null,
  }
}

/** Exercise the pinned DSH tool registry's typed return and separate model rendering contract. */
async function toolOutputProjectionCase(input) {
  const { ToolsService, SystemPrompt } = await toolsReference()
  const { context } = await scopeFixture(input, async context => {
    await context.plugin(SystemPrompt)
    await context.plugin(ToolsService)
  }, ['tools', 'systemPrompt'])
  let invoked = 0
  let rendered = 0
  const text = (args, value) => {
    if (input.format === 'label') return `${args.prefix ?? ''}${value.label}`
    if (input.format === 'joined') return value.lines.join('|')
    if (input.format === 'summary') return `${value.label} (${value.count})`
    if (input.format === 'silent') return ''
    if (input.format === 'scalar') return String(value)
    throw new Error('Unknown fixture presentation')
  }
  const dispose = context.tools.register({
    name: 'projection', description: '', parameters: { type: 'object' },
    output: { schema: input.schema, render: (args, value) => {
      rendered++
      return [{ type: 'text', text: text(args, value) }]
    } },
    execute: async () => { invoked++; return input.value },
  })
  const tool = context.tools.get('projection')
  const value = await tool.execute(input.arguments, {})
  const allowed = validateJsonSchemaValue(tool.output.schema, value, 'result').length === 0
  const content = allowed ? tool.output.render(input.arguments, value) : null
  dispose()
  await context.fiber.dispose()
  return {
    accepted: allowed,
    invoked, rendered,
    display: content === null ? null : content.map(block => block.text).join('\\n'),
    value: allowed ? value : null,
  }
}

function toolArgumentsCase(input) {
  assertSupportedJsonSchema(input.schema)
  const violations = validateJsonSchemaValue(input.schema, input.value, 'arguments').sort()
  return { violations, accepted: violations.length === 0, schema: input.schema }
}

function toolOutputsCase(input) {
  assertSupportedJsonSchema(input.schema)
  const violations = validateJsonSchemaValue(input.schema, input.value, 'result').sort()
  return { violations, accepted: violations.length === 0, schema: input.schema }
}

function patchCase(input) {
  const warnings = []
  const entries = applyEntryPatches(input.entries, input.patches ?? undefined, (...warning) => warnings.push(warning))
  return { entries, warnings, originalEntries: input.entries, originalPatches: input.patches ?? null }
}

function layerCase(input) {
  const warnings = []
  const entries = composeEntries(input.layers, warning => warnings.push(warning))
  return { entries, warnings, originalLayers: input.layers }
}

function profileGroupCase(input) {
  const seen = new Set()
  const patches = input.profiles.map(profile => {
    const inserted = []
    const overrides = []
    for (const plugin of profile.plugins) {
      const configuration = profile.config ?? {}
      if (!seen.has(plugin)) {
        const entry = { id: plugin, name: plugin }
        if (Object.hasOwn(configuration, plugin)) entry.config = configuration[plugin]
        inserted.push(entry)
        seen.add(plugin)
      } else if (Object.hasOwn(configuration, plugin)) {
        overrides.push({ id: plugin, config: configuration[plugin] })
      }
    }
    return [...inserted.length ? [{ insert: inserted }] : [], ...overrides]
  })
  const entries = composeEntries(patches, () => {})
  return { plugins: entries.map(entry => entry.id),
    config: Object.fromEntries(entries.filter(entry => Object.hasOwn(entry, 'config'))
      .map(entry => [entry.id, entry.config])), originalProfiles: input.profiles }
}

async function transportCase(input) {
  const incoming = new PassThrough()
  let output = ''
  const outgoing = new Writable({ write(chunk, encoding, complete) { output += chunk.toString(); complete() } })
  const peer = new JsonRpcLineTransport(incoming, outgoing)
  const notifications = []
  const trace = []
  if (input.handler === 'echo') peer.onRequest(async (method, params) => {
    trace.push({ type: 'request', method, params })
    return { method, params }
  })
  if (input.handler === 'failure') peer.onRequest(async () => { throw new Error('fixture failure') })
  peer.onNotification((method, params) => {
    notifications.push({ method, params })
    trace.push({ type: 'notification', method, params })
  })
  peer.start()
  for (const chunk of input.chunks) {
    incoming.write(Buffer.from(chunk, 'base64'))
    await settle()
  }
  await settle()
  await peer.flush()
  peer.close()
  incoming.destroy()
  outgoing.destroy()
  const result = { frames: output.split('\n').filter(Boolean).map(line => JSON.parse(line)), notifications }
  if (input.trace) result.trace = trace
  return result
}

function requestResult(pending) {
  return pending.then(
    value => ({ ok: true, value: value ?? null, error: null }),
    error => ({ ok: false, value: null, error: {
      code: error.code ?? null, message: error.message, data: error.data ?? null,
    } }),
  )
}

async function callbackCloseCase(input) {
  const child = spawn(process.execPath, ['--disable-warning=ExperimentalWarning',
    fileURLToPath(new URL('./transport-close-peer.mjs', import.meta.url))], { stdio: ['pipe', 'pipe', 'inherit'] })
  const exit = new Promise((resolve, reject) => {
    child.once('close', resolve)
    child.once('error', reject)
  })
  const peer = new JsonRpcLineTransport(child.stdout, child.stdin)
  const notifications = []
  let callbackReturned = false
  let followup
  peer.onNotification(async (method, params) => {
    notifications.push({ method, params })
    if (input.followup) followup = await requestResult(peer.request(input.followup.method,
      input.followup.params, AbortSignal.timeout(5000)))
    peer.close()
    child.kill('SIGTERM')
    callbackReturned = true
  })
  peer.start()
  let timer
  const deadline = new Promise((resolve, reject) => {
    timer = setTimeout(() => {
      child.kill('SIGKILL')
      reject(new Error('Reference close callback did not finish'))
    }, 10000)
  })
  try {
    const pending = requestResult(peer.request(input.method, input.params, AbortSignal.timeout(10000)))
    const [result] = await Promise.race([Promise.all([pending, exit]), deadline])
    if (!callbackReturned) throw new Error('Reference close callback was not invoked')
    return { notifications, callbackReturned, processExited: true, result,
      ...input.followup ? { followup } : {} }
  } finally {
    clearTimeout(timer)
    peer.close()
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
    await exit
  }
}

async function recoveryCase(input) {
  const incoming = new PassThrough()
  const frames = []
  const outgoing = new Writable({ write(chunk, encoding, complete) {
    for (const line of chunk.toString().split('\n').filter(Boolean)) frames.push(JSON.parse(line))
    complete()
  } })
  const originalWrite = outgoing.write.bind(outgoing)
  let failures = input.failures
  outgoing.write = (...arguments_) => {
    if (failures-- > 0) throw new Error('fixture write failure')
    return originalWrite(...arguments_)
  }
  const peer = new JsonRpcLineTransport(incoming, outgoing)
  peer.start()
  const failed = []
  for (let index = 0; index < input.failures; index++) failed.push(await requestResult(peer.request('fixture/fail', {})))
  const pending = requestResult(peer.request('fixture/recover', { value: 42 }))
  await settle()
  incoming.write(JSON.stringify({ jsonrpc: '2.0', id: frames[0].id, result: input.result }) + '\n')
  const result = await pending
  peer.close()
  incoming.destroy()
  outgoing.destroy()
  return { failed, request: { ...frames[0], id: '<request-id>' }, result }
}

async function outgoingCase(input) {
  const incoming = new PassThrough()
  const frames = []
  const outgoing = new Writable({ write(chunk, encoding, complete) {
    for (const line of chunk.toString().split('\n').filter(Boolean)) frames.push(JSON.parse(line))
    complete()
  } })
  const peer = new JsonRpcLineTransport(incoming, outgoing)
  peer.start()
  const controller = new AbortController()
  const pending = requestResult(peer.request(input.method, input.params, controller.signal))
  await settle()
  if (input.close) {
    peer.close()
  } else if (input.abort) {
    controller.abort(input.abort)
  } else {
    incoming.write(JSON.stringify({ jsonrpc: '2.0', id: frames[0].id, ...input.response }) + '\n')
  }
  const result = await pending
  peer.close()
  incoming.destroy()
  outgoing.destroy()
  return { request: { ...frames[0], id: '<request-id>' }, result }
}

async function lifecycleCase(input) {
  if (input.ownership) return ownershipCase(input)
  const { Context } = await cordisReference()
  const context = new Context()
  const trace = []
  const fibers = []
  for (const specification of input.plugins) {
    const initialize = inner => {
      const dependencies = Object.fromEntries((specification.requires ?? []).map(name => [name, inner.get(name)]))
      trace.push({ action: 'activate', plugin: specification.name, dependencies })
      for (const [name, value] of Object.entries(specification.provides ?? {})) inner.provide(name, value)
      for (const label of specification.effects ?? []) {
        const dispose = () => { trace.push({ action: 'dispose', plugin: specification.name, effect: label }) }
        inner.effect(() => specification.async_cleanup ? async () => { await settle(); dispose() } : dispose)
      }
    }
    fibers.push(context.plugin({
      name: specification.name,
      inject: specification.requires ?? [],
      apply: specification.async_setup ? async inner => { await settle(); initialize(inner) } : initialize,
    }))
  }
  for (const fiber of fibers) await fiber.await()
  await settle()
  const services = Object.fromEntries((input.services ?? []).map(name => [name, context.get(name) ?? null]))
  await context.fiber.dispose()
  return { trace, services }
}

async function ownershipCase(input) {
  const { Context } = await cordisReference()
  const results = []
  for (const mode of input.owners) {
    const context = new Context()
    let owner
    const fiber = context.plugin({ apply(inner) { owner = inner } })
    await fiber.await()
    const registrations = new Map()
    const trace = []
    const counts = []
    for (const operation of input.operations) {
      if (operation.type === 'register') {
        registrations.set(operation.id, owner.effect(() => () => { trace.push(operation.id) }))
      } else if (operation.type === 'release') {
        await registrations.get(operation.id)()
      } else if (operation.type === 'close') {
        await fiber.dispose()
      } else if (operation.type === 'snapshot') {
        counts.push(owner.fiber.getEffects().length)
      }
    }
    await context.fiber.dispose()
    results.push({ owner: mode, counts, trace })
  }
  return results
}

function replacementPlugin(specification, trace) {
  return {
    name: specification.name,
    inject: specification.requires ?? [],
    apply(context) {
      trace.push({ action: 'activate', generation: specification.generation })
      for (const [name, value] of Object.entries(specification.provides)) context.provide(name, value)
      for (const label of specification.effects ?? []) context.effect(() => () => {
        trace.push({ action: 'dispose', generation: specification.generation, effect: label })
      })
      if (specification.fail) throw new Error('fixture setup failure')
    },
  }
}

async function replacementCase(input) {
  if (input.kind === 'retained') return retainedReplacementCase(input)
  if (input.kind === 'async_binding') return retainedAsyncBindingCase(input)
  const { Context } = await cordisReference()
  const trace = []
  const initial = new Context()
  await initial.plugin(replacementPlugin(input.initial, trace))
  if (input.kind === 'service') {
    const selection = initial.isolate(input.service)
    await selection.plugin(replacementPlugin(input.replacement, trace))
    const services = Object.fromEntries(input.services.map(name => [name, selection.get(name)]))
    await initial.fiber.dispose()
    return { services, trace }
  }
  const before = Object.fromEntries(input.services.map(name => [name, initial.get(name)]))
  const staged = new Context()
  let accepted = true
  try { await staged.plugin(replacementPlugin(input.replacement, trace)) }
  catch { accepted = false }
  if (accepted) await initial.fiber.dispose()
  else await staged.fiber.dispose()
  const selected = accepted ? staged : initial
  const after = Object.fromEntries(input.services.map(name => [name, selected.get(name)]))
  await selected.fiber.dispose()
  return { accepted, before, after, trace }
}

async function retainedAsyncBindingCase(input) {
  const { Context } = await cordisReference()
  const trace = []
  const retained = new Context()
  await retained.plugin(replacementPlugin(input.initial, trace))
  const service = retained.get(input.service)
  let resume
  const gate = new Promise(resolve => { resume = resolve })
  const pending = (async () => {
    trace.push({ action: 'enter', value: service })
    await gate
    trace.push({ action: 'use', value: service })
    return service
  })()
  const selected = new Context()
  await selected.plugin(replacementPlugin(input.replacement, trace))
  resume()
  const value = await pending
  await retained.fiber.dispose()
  const current = selected.get(input.service)
  await selected.fiber.dispose()
  return { value, current, trace }
}

async function retainedReplacementCase(input) {
  const { Context } = await cordisReference()
  const { ToolsService, SystemPrompt } = await toolsReference()
  const trace = []
  async function generation(specification) {
    const context = new Context()
    await context.plugin(SystemPrompt)
    await context.plugin(ToolsService)
    await context.plugin({ name: specification.name, inject: ['tools'], apply(owner) {
      trace.push({ action: 'activate', generation: specification.generation })
      owner.on('fixture', value => {
        trace.push({ action: 'event', generation: specification.generation, value })
      })
      owner.tools.register({ name: 'version', description: '', parameters: { type: 'object' },
        output: { schema: {}, render: () => [] }, execute: async arguments_ => {
          trace.push({ action: 'tool', generation: specification.generation, arguments: arguments_ })
          return specification.value
        },
      })
      owner.effect(() => () => {
        trace.push({ action: 'dispose', generation: specification.generation })
      })
    } })
    return context
  }
  async function invoke(context) {
    const definition = context.tools.get('version')
    const result = definition === undefined ? { ok: false, value: null }
      : { ok: true, value: await definition.execute(input.arguments, {}) }
    context.emit('fixture', input.event)
    return result
  }
  const retained = await generation(input.initial)
  const selected = await generation(input.replacement)
  const old = await invoke(retained)
  const current = await invoke(selected)
  const retainedTools = retained.tools
  await retained.fiber.dispose()
  const afterRelease = { ok: retainedTools.get('version') !== undefined, value: null }
  retained.emit('fixture', input.event)
  await selected.fiber.dispose()
  return { old, current, afterRelease, trace }
}

async function scopeFixture(input, configure, inject = []) {
  const { Context } = await cordisReference()
  const { createScope } = await scopedReference()
  const context = new Context()
  if (configure) await configure(context)
  const scopes = new Map([['root', { ctx: context, key: undefined, dispose: () => context.fiber.dispose() }]])
  for (const specification of input.scopes ?? []) {
    const key = {}
    const parent = scopes.get(specification.parent ?? 'root')
    let scope
    await parent.ctx.plugin({ inject, apply(inner) {
      scope = createScope(inner, key, parent.key === undefined ? undefined : { parent: parent.key })
    } })
    await scope.ctx.fiber.await()
    scopes.set(specification.name, { ...scope, key })
  }
  return { context, scopes }
}

function launchCase(input) {
  const launch = resolveDshLaunch(input.options, process.cwd())
  const environment = launch.environment()
  const keys = [...Object.keys(input.options.env ?? {}), ...input.options.dshHome === undefined ? [] : ['DSH_HOME']]
  return { arguments: ['<node>', ...launch.args], directory: launch.cwd ?? process.cwd(),
    environment: Object.fromEntries(keys.map(key => [key, environment[key]])) }
}

async function eventCase(input) {
  if (input.retained_waterfall) return retainedWaterfallCase(input)
  const { context, scopes } = await scopeFixture(input)
  const { scopeTarget } = await scopedReference()
  const trace = []
  const listeners = new Map()
  for (const specification of input.listeners) {
    const scope = scopes.get(specification.scope ?? 'root')
    const callback = (...arguments_) => {
      const next = specification.waterfall ? arguments_.pop() : undefined
      trace.push({ listener: specification.id, arguments: arguments_ })
      if (specification.waterfall && !specification.veto) {
        const result = next()
        if (specification.suffix) return result + specification.suffix
        return result
      }
      return specification.result ?? null
    }
    listeners.set(specification.id, scope.ctx[specification.once ? 'once' : 'on'](specification.event ?? 'fixture', callback,
      { prepend: specification.prepend ?? false, global: specification.global ?? false }))
  }
  const results = []
  for (const operation of input.operations) {
    if (operation.type === 'dispose') {
      listeners.get(operation.listener)()
    } else if (operation.type === 'close') {
      await scopes.get(operation.scope).dispose()
    } else {
      const scope = scopes.get(operation.scope ?? 'root')
      const arguments_ = [...operation.arguments ?? []]
      if (operation.mode === 'waterfall') arguments_.push(() => {
        trace.push({ listener: '<inner>', arguments: [] })
        return operation.inner ?? 'inner'
      })
      const result = await context[operation.mode](scopeTarget({}, scope.key), operation.event ?? 'fixture', ...arguments_)
      results.push(result ?? null)
    }
  }
  await context.fiber.dispose()
  return { trace, results }
}

async function retainedWaterfallCase(input) {
  const { Context } = await cordisReference()
  const context = new Context()
  const trace = []
  let alive = true
  context.effect(() => () => { alive = false; trace.push({ action: 'dispose' }) })
  let resume
  let downstream
  const gate = new Promise(resolve => { resume = resolve })
  context.on('fixture', next => {
    trace.push({ action: 'outer-enter' })
    next()
    return Promise.resolve(input.outer)
  })
  context.on('fixture', next => {
    trace.push({ action: 'downstream-start' })
    downstream = gate.then(() => {
      trace.push({ action: 'downstream-use', alive })
      return next()
    })
    return downstream
  })
  const result = await context.waterfall('fixture', () => {
    trace.push({ action: 'builtin', alive })
    return input.inner
  })
  trace.push({ action: 'outer-result', value: result })
  // This explicit retained root models a consumer that is still using its generation.
  trace.push({ action: 'after-retire', alive })
  resume()
  const inner = await downstream
  await context.fiber.dispose()
  return { result, inner, trace }
}

async function toolCase(input) {
  const { ToolsService, SystemPrompt } = await toolsReference()
  const { context, scopes } = await scopeFixture(input, async context => {
    await context.plugin(SystemPrompt)
    await context.plugin(ToolsService)
  }, ['tools', 'systemPrompt'])
  const registrations = new Map()
  const results = []
  const executions = []
  const guardCalls = []
  for (const operation of input.operations) {
    const scope = scopes.get(operation.scope ?? 'root')
    if (operation.type === 'register') {
      try {
        const dispose = scope.ctx.tools.register({
          name: operation.name, description: operation.description ?? '', parameters: operation.schema ?? { type: 'object' },
          output: { schema: {}, render: () => [] }, execute: async () => { executions.push(operation.name); return operation.value ?? null },
        })
        registrations.set(operation.id, dispose)
        results.push({ accepted: true })
      } catch {
        results.push({ accepted: false })
      }
    } else if (operation.type === 'guard') {
      const dispose = scope.ctx.tools.guard(exec => {
        guardCalls.push(operation.id)
        return operation.names.includes(exec.name) ? operation.reason : undefined
      })
      registrations.set(operation.id, dispose)
      results.push({ accepted: true })
    } else if (operation.type === 'restrict') {
      try {
        registrations.set(operation.id, scope.ctx.tools.restrict(operation.filter))
        results.push({ accepted: true })
      } catch {
        results.push({ accepted: false })
      }
    } else if (operation.type === 'dispose') {
      registrations.get(operation.id)()
    } else if (operation.type === 'close') {
      await scope.dispose()
    } else if (operation.type === 'snapshot') {
      results.push(context.tools.schemas(scope.key).map(tool => ({ name: tool.name, schema: tool.parameters, description: tool.description })))
    } else if (operation.type === 'invoke') {
      const definition = context.tools.get(operation.name, scope.key)
      results.push(definition === undefined ? { ok: false, value: null }
        : { ok: true, value: await definition.execute(operation.arguments ?? {}, {}) })
    } else if (operation.type === 'invoke_guarded') {
      const args = operation.arguments ?? {}
      const denial = context.tools.checkGuards({ name: operation.name, arguments: args, agent: scope.key })
      const definition = context.tools.get(operation.name, scope.key)
      results.push(denial !== undefined ? { ok: false, value: null, reason: denial }
        : definition === undefined ? { ok: false, value: null, reason: 'Unknown tool' }
        : { ok: true, value: await definition.execute(args, {}), reason: null })
    } else if (operation.type === 'trace') {
      results.push({ executions: [...executions], guards: [...guardCalls] })
    } else {
      throw new Error(`Unknown tool fixture operation: ${operation.type}`)
    }
  }
  await context.fiber.dispose()
  return results
}


/** Preserve PR #45's fixtures while replacing their delays with bounded rendezvous cohorts. */
function toolBatchProjectionPeers(input) {
  const safe = new Map(input.tools.map(tool => [tool.name, tool.parallel === true]))
  const peers = input.calls.map(() => [])
  const pending = []
  input.calls.forEach((call, index) => {
    if (safe.get(call.name)) pending.push(index)
    if (!safe.get(call.name) || pending.length === input.max_parallel) {
      for (const member of pending) peers[member] = [...pending]
      pending.length = 0
    }
  })
  for (const member of pending) peers[member] = [...pending]
  return peers
}

/** Run the existing original pinned scheduler; callbacks model only bounded value/failure behavior. */
async function toolBatchProjectionCase(input) {
  const definitions = new Map(input.tools.map(tool => [tool.name, tool]))
  const entered = input.calls.map(() => Promise.withResolvers())
  const peers = toolBatchProjectionPeers(input)
  let active = 0
  let exclusive = 0
  let peak = 0
  let exclusiveOverlap = false
  const pipeline = {
    executionMode(exec) {
      return { kind: definitions.get(exec.name)?.parallel === true ? 'parallel' : 'exclusive' }
    },
    async prepare(exec) {
      if (definitions.has(exec.name)) return { kind: 'dispatch', exec }
      return { kind: 'post-result', exec, result: {
        content: [{ type: 'text', text: 'unknown tool' }], isError: true,
      } }
    },
    async dispatch(exec) {
      const safe = definitions.get(exec.name).parallel === true
      if ((safe && exclusive > 0) || (!safe && active > 0)) exclusiveOverlap = true
      active++
      if (!safe) exclusive++
      peak = Math.max(peak, active)
      entered[exec.arguments.index].resolve()
      await Promise.all(peers[exec.arguments.index].map(member => entered[member].promise))
      active--
      if (!safe) exclusive--
      return { kind: 'post-result', result: {
        content: [{ type: 'text', text: String(exec.arguments.value) }],
        isError: exec.arguments.fail === true,
      } }
    },
    async complete(_execution, slot) { return slot.result },
  }
  const calls = input.calls.map((call, index) => ({
    id: String(index + 1), name: call.name,
    arguments: JSON.stringify({ index, value: call.value, fail: call.fail === true }),
  }))
  let watchdog
  // This deadline only bounds regressions; elapsed time does not determine any expected result.
  const deadline = new Promise((_, reject) => {
    watchdog = setTimeout(() => reject(new Error('Batch projection rendezvous timed out')), 30_000)
  })
  const settled = await Promise.race([
    executeToolBatch({ calls, signal: new AbortController().signal,
      maxParallelToolCalls: input.max_parallel }, pipeline, () => 1),
    deadline,
  ]).finally(() => clearTimeout(watchdog))
  return {
    results: settled.results.map(({ callId, result }) => ({
      id: callId, ok: !result.isError,
      value: result.isError ? null : result.content[0].text,
    })),
    peak, exclusiveOverlap,
  }
}

function sessionQueryCase(input) {
  const sessions = input.selected_sessions === undefined ? input.sessions
    : filterSessionResults(input.sessions.map(session => ({ header: { id: session.name }, session })),
      [{ kind: 'id', values: input.selected_sessions }]).map(record => record.session)
  const documents = sessions.flatMap(session => session.messages.map((message, index) => ({
    sessionId: session.name,
    seq: index,
    type: `${message.role}/message`,
    time: 0,
    surface: 'current',
    text: message.content,
  })))
  documents.sort((left, right) => left.sessionId < right.sessionId ? -1
    : left.sessionId > right.sessionId ? 1 : left.seq - right.seq)
  const filters = [{ kind: 'text', text: input.text }]
  if (input.roles !== undefined) filters.push({ kind: 'type',
    values: input.roles.map(role => `${role}/message`) })
  if (input.from_index !== undefined || input.to_index !== undefined) {
    filters.push({ kind: 'seq',
      ...input.from_index === undefined ? {} : { from: input.from_index - 1 },
      ...input.to_index === undefined ? {} : { to: input.to_index - 1 } })
  }
  const selected = filterSessionEventDocuments(documents, filters)
  return { ok: true, hits: selected.slice(0, input.limit ?? selected.length).map(document => ({
    session: input.source === 'live' ? null : document.sessionId,
    index: document.seq + 1,
    role: document.type.slice(0, document.type.indexOf('/')),
    kind: 'text',
    content: document.text,
  })) }
}

/** Compare a fork's visible message prefix using the unchanged pinned DSH seed algorithm. */
function sessionForkCase(input) {
  const events = []
  input.messages.forEach((message, index) => {
    const seq = events.length
    events.push({ type: 'turn/start', seq, time: 0, data: { turn: index } })
    events.push({ type: `${message.role}/message`, seq: seq + 1, time: 0,
      data: { message: { role: message.role, content: [{ type: 'text', text: message.content }] } } })
    events.push({ type: 'turn/end', seq: seq + 2, time: 0,
      data: { turn: index, reason: { kind: 'completed' } } })
  })
  const boundary = input.at_index === undefined ? events.length - 1 : (input.at_index - 1) * 3 + 1
  const seed = buildForkSeed(events, boundary)
  const marker = seed.findIndex(event => event.type === 'session/end-seed')
  if (marker !== boundary + 1 || seed[marker].data.inherited !== true) {
    throw new Error('Pinned DSH fork did not preserve its inherited boundary')
  }
  if (input.at_index !== undefined
    && seed.at(-1)?.data?.reason?.kind !== 'forked') {
    throw new Error('Pinned DSH fork did not terminate the cut-open turn')
  }
  return { ok: true, messages: seed.slice(0, marker)
    .filter(event => event.type === 'user/message' || event.type === 'assistant/message')
    .map(event => ({ role: event.data.message.role,
      content: event.data.message.content[0].text })) }
}

/** Project the pinned ACP admission guard and cancel method without a DSH runtime. */
function sessionControlCase(input) {
  const reference = new AcpSessionControlReference({ cancel: () => {} })
  return input.operations.map(operation => {
    if (operation === 'submit') {
      try {
        reference.admit()
        return { accepted: true }
      } catch {
        return { accepted: false }
      }
    }
    if (operation === 'cancel') {
      const alreadyCancelled = reference.inflight?.cancelled === true
      reference.cancel()
      return { cancelled: !alreadyCancelled && reference.inflight?.cancelled === true }
    }
    if (operation === 'settle') {
      const cancelled = reference.inflight?.cancelled === true
      reference.inflight = undefined
      return { cancelled }
    }
    throw new Error(`Unsupported session-control fixture operation: ${operation}`)
  })
}

/** Compare public Markdown exports using the pinned original committed-event formatter. */
function sessionMarkdownCase(input) {
  const events = []
  if (input.title !== undefined) events.push({ type: 'session/title', data: { title: input.title } })
  let active = false
  for (const message of input.messages) {
    const kind = message.kind ?? 'text'
    if (kind !== 'text' && !(message.role === 'assistant' && kind === 'answer')) continue
    if (message.role === 'user') {
      if (active) events.push({ type: 'turn/end' })
      events.push({ type: 'turn/start' })
      active = true
      events.push({ type: 'user/message', surfaceOp: 'append',
        data: { source: { kind: 'user' }, content: [{ type: 'text', text: message.content }] } })
    } else if (message.role === 'assistant') {
      if (!active) {
        events.push({ type: 'turn/start' })
        active = true
      }
      events.push({ type: 'assistant/message', surfaceOp: 'append',
        data: { message: { content: [{ type: 'text', text: message.content }] } } })
    }
  }
  if (active) events.push({ type: 'turn/end' })
  return formatSessionMarkdown(events, input.source_path)
}

async function execute(input) {
  if (input.kind === 'tool_completion') return Promise.all(input.cases.map(toolCompletionCase))
  if (input.kind === 'tool_approval') return Promise.all(input.cases.map(toolApprovalCase))
  if (input.kind === 'tool_arguments') return input.cases.map(toolArgumentsCase)
  if (input.kind === 'tool_outputs') return input.cases.map(toolOutputsCase)
  if (input.kind === 'tool_output_projection') return Promise.all(input.cases.map(toolOutputProjectionCase))
  if (input.kind === 'patches') return input.cases.map(patchCase)
  if (input.kind === 'layers') return input.cases.map(layerCase)
  if (input.kind === 'profile_groups') return input.cases.map(profileGroupCase)
  if (input.kind === 'session_query') return input.cases.map(sessionQueryCase)
  if (input.kind === 'session_titles') return input.cases.map(entry => ({
    normalized: normalizeSessionTitle(entry.input, entry.max_bytes),
    fallback: fallbackSessionTitle(entry.input, entry.max_words, entry.max_bytes),
    truncated: truncateTitleUtf8(entry.input, entry.max_bytes),
  }))
  if (input.kind === 'session_markdown') return input.cases.map(sessionMarkdownCase)
  if (input.kind === 'session_control') return input.cases.map(sessionControlCase)
  if (input.kind === 'session_fork') return input.cases.map(sessionForkCase)
  if (input.kind === 'transport') return Promise.all(input.cases.map(transportCase))
  if (input.kind === 'outgoing') return Promise.all(input.cases.map(outgoingCase))
  if (input.kind === 'recovery') return Promise.all(input.cases.map(recoveryCase))
  if (input.kind === 'callback_close') return Promise.all(input.cases.map(callbackCloseCase))
  if (input.kind === 'lifecycle') return Promise.all(input.cases.map(lifecycleCase))
  if (input.kind === 'replacements') return Promise.all(input.cases.map(replacementCase))
  if (input.kind === 'events') return Promise.all(input.cases.map(eventCase))
  if (input.kind === 'tools') return Promise.all(input.cases.map(toolCase))
  if (input.kind === 'tool_batch') return Promise.all(input.cases.map(toolBatchCase))
  if (input.kind === 'tool_batches') return Promise.all(input.cases.map(toolBatchProjectionCase))
  if (input.kind === 'tool_cancellation') return Promise.all(input.cases.map(toolCancellationCase))
  if (input.kind === 'final_response') return input.cases.map(input => finalResponse(input.events))
  if (input.kind === 'launch') return input.cases.map(launchCase)
  throw new Error(`Unknown oracle operation: ${input.kind}`)
}

for await (const line of createInterface({ input: process.stdin })) {
  if (!line.trim()) continue
  process.stdout.write(JSON.stringify(await execute(JSON.parse(line))) + '\n')
}
