import { createHash } from 'node:crypto'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { registerHooks, stripTypeScriptTypes } from 'node:module'
import { dirname, resolve, relative, sep, isAbsolute } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const directory = dirname(fileURLToPath(import.meta.url))
export const referenceLock = JSON.parse(readFileSync(resolve(directory, 'reference-lock.json'), 'utf8'))
const coverage = JSON.parse(readFileSync(resolve(directory, 'coverage.json'), 'utf8'))
if (coverage.reference.commit !== referenceLock.commit) throw new Error('Coverage metadata and oracle source lock disagree')
for (const comparison of coverage.native_comparisons) {
  for (const source of comparison.sources) {
    if (!Object.hasOwn(referenceLock.sources, source.path)) throw new Error(`Coverage source is not locked: ${source.path}`)
  }
}
export const referenceRoot = resolve(process.env.DSH_REFERENCE_ROOT ?? resolve(directory, '../../../deepseek-harness'))

let gitDirectory = resolve(referenceRoot, '.git')
if (statSync(gitDirectory).isFile()) gitDirectory = resolve(referenceRoot, readFileSync(gitDirectory, 'utf8').trim().slice('gitdir: '.length))
const head = readFileSync(resolve(gitDirectory, 'HEAD'), 'utf8').trim()
const reference = head.startsWith('ref: ') ? head.slice(5) : null
const commonDirectory = existsSync(resolve(gitDirectory, 'commondir'))
  ? resolve(gitDirectory, readFileSync(resolve(gitDirectory, 'commondir'), 'utf8').trim()) : gitDirectory
const referencePath = reference && resolve(commonDirectory, reference)
const revision = !reference ? head : existsSync(referencePath)
  ? readFileSync(referencePath, 'utf8').trim()
  : readFileSync(resolve(commonDirectory, 'packed-refs'), 'utf8').split('\n').find(line => line.endsWith(` ${reference}`))?.split(' ')[0]
if (revision !== referenceLock.commit) {
  throw new Error(`DSH reference revision ${revision} differs from locked ${referenceLock.commit}`)
}

export function referenceSource(path) {
  const source = readFileSync(resolve(referenceRoot, path), 'utf8')
  const expected = referenceLock.sources[path]
  const actual = createHash('sha256').update(source).digest('hex')
  if (!expected || actual !== expected) throw new Error(`DSH oracle source hash mismatch: ${path}`)
  return source
}

export async function importSource(path, select = source => source) {
  const source = select(referenceSource(path))
  const javascript = stripTypeScriptTypes(source, { mode: 'transform' })
  return import(`data:text/javascript;base64,${Buffer.from(javascript).toString('base64')}`)
}

registerHooks({
  resolve(specifier, context, nextResolve) {
    const entries = {
      '@deepseek-ai/cosmokit': 'vendor/cosmokit/src/index.ts',
      '@deepseek-ai/cordis': 'vendor/cordis/src/index.ts',
      '@deepseek-ai/schemastery': 'vendor/schemastery/src/index.ts',
      '@deepseek-ai/dsh-scope': 'packages/core/scope/src/index.ts',
      '@deepseek-ai/dsh-util-values': 'packages/util/values/src/index.ts',
      // The tool registry imports only HarnessError; use its original defining module.
      '@deepseek-ai/dsh-llm': 'packages/llm/llm/src/error.ts',
    }
    if (Object.hasOwn(entries, specifier)) {
      return { url: pathToFileURL(resolve(referenceRoot, entries[specifier])).href, shortCircuit: true }
    }
    return nextResolve(specifier, context)
  },
  load(url, context, nextLoad) {
    if (url.startsWith('file:') && url.endsWith('.ts')) {
      const path = fileURLToPath(url)
      const sourcePath = relative(referenceRoot, path).split(sep).join('/')
      if (sourcePath !== '..' && !sourcePath.startsWith('../') && !isAbsolute(sourcePath)) {
        return { format: 'module', source: stripTypeScriptTypes(referenceSource(sourcePath), { mode: 'transform' }), shortCircuit: true }
      }
    }
    return nextLoad(url, context)
  },
})

export async function cordisReference() {
  return import(pathToFileURL(resolve(referenceRoot, 'vendor/cordis/src/index.ts')).href)
}

export async function scopedReference() {
  return import(pathToFileURL(resolve(referenceRoot, 'packages/core/scope/src/index.ts')).href)
}

export async function toolsReference() {
  const tools = await import(pathToFileURL(resolve(referenceRoot, 'packages/core/tools/src/index.ts')).href)
  const prompt = await import(pathToFileURL(resolve(referenceRoot, 'packages/core/system-prompt/src/index.ts')).href)
  return { ToolsService: tools.ToolsService, SystemPrompt: prompt.default }
}
