import { importSource } from './reference.mjs'

const { JsonRpcLineTransport } = await importSource('packages/sdk/protocol/src/transport.ts')
const peer = new JsonRpcLineTransport(process.stdin, process.stdout)
peer.onRequest(async (method, params) => {
  if (method === 'fixture/respond') return params
  peer.notify(method, params)
  await new Promise(() => {})
})
peer.start()
