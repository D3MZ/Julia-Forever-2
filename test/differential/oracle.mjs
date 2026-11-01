import { PassThrough, Writable } from 'node:stream'
import { createInterface } from 'node:readline'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { importSource, referenceSource, cordisReference, scopedReference, toolsReference } from './reference.mjs'

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
const settle = () => new Promise(resolve => setImmediate(resolve))

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
  for (const operation of input.operations) {
    const scope = scopes.get(operation.scope ?? 'root')
    if (operation.type === 'register') {
      try {
        const dispose = scope.ctx.tools.register({
          name: operation.name, description: operation.description ?? '', parameters: operation.schema ?? { type: 'object' },
          output: { schema: {}, render: () => [] }, execute: async () => operation.value ?? null,
        })
        registrations.set(operation.id, dispose)
        results.push({ accepted: true })
      } catch {
        results.push({ accepted: false })
      }
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
    } else {
      throw new Error(`Unknown tool fixture operation: ${operation.type}`)
    }
  }
  await context.fiber.dispose()
  return results
}

async function execute(input) {
  if (input.kind === 'patches') return input.cases.map(patchCase)
  if (input.kind === 'layers') return input.cases.map(layerCase)
  if (input.kind === 'transport') return Promise.all(input.cases.map(transportCase))
  if (input.kind === 'outgoing') return Promise.all(input.cases.map(outgoingCase))
  if (input.kind === 'recovery') return Promise.all(input.cases.map(recoveryCase))
  if (input.kind === 'callback_close') return Promise.all(input.cases.map(callbackCloseCase))
  if (input.kind === 'lifecycle') return Promise.all(input.cases.map(lifecycleCase))
  if (input.kind === 'replacements') return Promise.all(input.cases.map(replacementCase))
  if (input.kind === 'events') return Promise.all(input.cases.map(eventCase))
  if (input.kind === 'tools') return Promise.all(input.cases.map(toolCase))
  if (input.kind === 'final_response') return input.cases.map(input => finalResponse(input.events))
  if (input.kind === 'launch') return input.cases.map(launchCase)
  throw new Error(`Unknown oracle operation: ${input.kind}`)
}

for await (const line of createInterface({ input: process.stdin })) {
  if (!line.trim()) continue
  process.stdout.write(JSON.stringify(await execute(JSON.parse(line))) + '\n')
}
