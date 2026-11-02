// Original pinned FooterComponent; fixture session/data providers only.
// Usage: node pi-footer-oracle.mjs PI_ROOT PROVENANCE_JSON NEW_OUTPUT_JSON
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';
const [r,p,o,f]=process.argv.slice(2);assert(r&&p&&o&&f);
const root=resolve(r),output=resolve(o),sha=x=>createHash('sha256').update(x).digest('hex');
const bytes=readFileSync(resolve(p)),prior=JSON.parse(bytes),pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403';
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),pin);
assert.equal(prior.reference.commit,pin);assert.equal(Object.keys(prior.reference.sourceHashes).length,513);
for(const [path,hash]of Object.entries(prior.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,path))),hash,path);
const agent=mkdtempSync(join(tmpdir(),'pi-metered-only-'));process.env.PI_CODING_AGENT_DIR=agent;process.env.PI_OFFLINE='1';process.env.PI_EXPERIMENTAL='0';process.env.COLORTERM='truecolor';
process.on('exit',()=>rmSync(agent,{recursive:true,force:true}));
const imports=[];const load=path=>{imports.push(path);return import(pathToFileURL(join(root,path)).href);};
await load('packages/coding-agent/src/experimental/source-resolver.ts');

const fixtureBytes=readFileSync(resolve(f)),fixtures=JSON.parse(fixtureBytes),cases=[];
let active;
globalThis.fetch=async(url,options)=>{assert(active,'No active local transport fixture');active.requests.push({url:String(url),body:JSON.parse(options.body)});return new Response(active.response,{status:200,headers:{'content-type':'text/event-stream'}});};
const openai=await load('packages/ai/src/api/openai-completions.ts');
const anthropic=await load('packages/ai/src/api/anthropic-messages.ts');
for(const fixture of fixtures.cases){
 active={response:fixture.response,requests:[]};const model={...fixture.model,baseUrl:'https://fixture.invalid'};
 const output=(fixture.protocol==='anthropic'?anthropic:openai).stream(model,{messages:[{role:'user',content:'Fixture prompt',timestamp:0}]},{apiKey:'fixture-only',maxRetries:0,cacheRetention:'none'});
 const events=[];for await(const event of output){const value={};for(const key of ['type','contentIndex','delta','content','toolCall','reason'])if(event[key]!==undefined)value[key]=structuredClone(event[key]);events.push(value);}
 const message=structuredClone(await output.result());delete message.timestamp;delete message.durationMs;
 cases.push({id:fixture.id,message,events,requests:active.requests});
}
const result={reference:prior.reference,provenance:{checkedSourceFiles:513,runnerSha256:sha(readFileSync(new URL(import.meta.url))),fixtureSha256:sha(fixtureBytes),imports:imports.map(path=>({path,sha256:sha(readFileSync(join(root,path)))}))},method:'Original source stream APIs over fixture-only fetch Responses. No network, auth lookup or external provider calls; separate native report expectations are raw-field presence contracts, not upstream output claims.',cases};
writeFileSync(output,JSON.stringify(result,null,2)+'\n',{flag:'wx'});console.log(JSON.stringify({output,cases:cases.length,sha256:sha(readFileSync(output))}));
