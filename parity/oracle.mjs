import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const reference = resolve(process.argv[2]);
const load = (path) => import(pathToFileURL(resolve(reference, path)).href);
const { createModels } = await load('packages/ai/src/models.ts');
const { InMemoryModelsStore } = await load('packages/ai/src/models-store.ts');
const { createAssistantMessageEventStream } = await load('packages/ai/src/utils/event-stream.ts');
const scenarios = JSON.parse(readFileSync(0, 'utf8'));

function scriptedProvider(specification) {
    const catalog = () => {
        if (specification.catalog_error) throw new Error('scripted catalog failure');
        return specification.models;
    };
    const stream = (model, context) => {
        const prompt = context.messages.filter((message) => message.role === 'user').at(-1).content;
        const text = `${specification.prefix}/${specification.id}/${model.id}/${prompt}`;
        const output = createAssistantMessageEventStream();
        const message = {
            role: 'assistant', content: [{ type: 'text', text }], api: model.api,
            provider: model.provider, model: model.id, timestamp: 0, stopReason: 'stop',
            usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
                cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        };
        output.push({ type: 'start', partial: message });
        output.push({ type: 'done', reason: 'stop', message });
        output.end();
        return output;
    };
    return {
        id: specification.id, name: specification.id,
        auth: { apiKey: { name: 'Offline fixture', resolve: async () => ({ auth: { apiKey: 'fixture-only' } }) } },
        getModels: () => catalog().filter((model) => (model.type ?? 'chat') === 'chat'),
        getAllModels: catalog, stream, streamSimple: stream,
    };
}

async function registryScenario(scenario) {
    const models = createModels();
    const outputs = [];
    for (const step of scenario.steps) {
        switch (step.operation) {
            case 'register': models.setProvider(scriptedProvider(step.provider)); break;
            case 'delete': models.deleteProvider(step.provider); break;
            case 'clear': models.clearProviders(); break;
            case 'providers': outputs.push(models.getProviders().map((provider) => provider.id)); break;
            case 'models': {
                const result = step.kind === 'all' ? models.getAllModels(step.provider)
                    : models.getModelsOfType(step.kind ?? 'chat', step.provider);
                outputs.push(structuredClone(result));
                break;
            }
            case 'lookup':
                outputs.push(structuredClone(models.getModelOfType(step.kind ?? 'chat', step.provider, step.id) ?? null));
                break;
            case 'dispatch': {
                const model = models.getModel(step.provider, step.id);
                if (!model) { outputs.push({ missing: true }); break; }
                const response = await models.complete(model, {
                    messages: [{ role: 'user', content: step.prompt, timestamp: 0 }],
                });
                outputs.push({ text: response.content.filter((block) => block.type === 'text').map((block) => block.text).join(''),
                    stopReason: response.stopReason });
                break;
            }
            default: throw new Error(`Unknown registry operation: ${step.operation}`);
        }
    }
    return outputs;
}

function mutate(value, path, replacement) {
    let parent = value;
    for (const key of path.slice(0, -1)) parent = parent[key];
    parent[path.at(-1)] = replacement;
}

async function storeScenario(scenario) {
    const store = new InMemoryModelsStore();
    const variables = new Map();
    const outputs = [];
    for (const step of scenario.steps) {
        switch (step.operation) {
            case 'write': {
                const value = structuredClone(step.entry);
                variables.set(step.variable, value);
                await store.write(step.provider, value);
                break;
            }
            case 'read': {
                const value = await store.read(step.provider);
                variables.set(step.variable, value);
                outputs.push(structuredClone(value ?? null));
                break;
            }
            case 'mutate': mutate(variables.get(step.variable), step.path, step.value); break;
            case 'delete': await store.delete(step.provider); break;
            default: throw new Error(`Unknown store operation: ${step.operation}`);
        }
    }
    return outputs;
}

const outputs = [];
for (const scenario of scenarios) {
    const result = scenario.family === 'registry' ? await registryScenario(scenario) : await storeScenario(scenario);
    outputs.push({ id: scenario.id, result });
}
process.stdout.write(JSON.stringify(outputs));
