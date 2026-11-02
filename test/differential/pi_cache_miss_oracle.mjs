// Execute the unchanged pinned Pi cache scanner; no provider, credentials or network.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const [rootArg,pinArg,out]=process.argv.slice(2),root=resolve(rootArg),prior=JSON.parse(readFileSync(pinArg));
const sha=x=>createHash('sha256').update(x).digest('hex');
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),prior.reference.commit);
for(const[p,h]of Object.entries(prior.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,p))),h,p);
globalThis.fetch=()=>{throw Error('No network in cache oracle');};
const {collectCacheMisses}=await import(pathToFileURL(join(root,'packages/coding-agent/src/core/cache-stats.ts')));
const message=(id,input,read,write,time=0,model='fixture')=>({id,type:'message',timestamp:new Date(time).toISOString(),message:{role:'assistant',provider:'fixture',model,timestamp:time,content:[{type:'text',text:id}],usage:{input,cacheRead:read,cacheWrite:write,output:1,cost:{input:input*3e-6,cacheRead:read*.3e-6,cacheWrite:write*3.75e-6,total:0}}}});
const seed=message('seed',0,0,50000);
const cases=[
 ['first',[seed]],['hit',[seed,message('hit',100,50000,0,1000)]],
 ['idle',[seed,message('miss',50000,0,0,360000)]],
 ['partial',[seed,message('partial',25000,25000,0,1000)]],
 ['switch',[seed,message('switch',50000,0,0,1000,'different')]],
 ['noise',[seed,message('noise',1024,48976,0,1000)]],
 ['no-support',[message('plain1',50000,0,0),message('plain2',50000,0,0,1000)]],
 ['compaction',[seed,{id:'compact',type:'compaction'},message('after',50000,0,0,360000)]],
 ['branch',[seed,{id:'branch',type:'branch_summary'},message('after',50000,0,0,360000)]],
 ['warm',[seed,{id:'warm',type:'usage',kind:'cache_warm',provider:'fixture',model:'fixture',timestamp:new Date(300000).toISOString(),usage:{input:0,cacheRead:50000,cacheWrite:0}},message('after',50000,0,0,360000)]],
 ['zero',[seed,message('empty',0,0,0,1000),message('after',50000,0,0,360000)]]
];
const models={getModel:()=>({cost:{cacheRead:.3}})};
const results=cases.map(([id,entries])=>({id,entries,misses:[...collectCacheMisses(entries,models)].map(([m,miss])=>({id:entries.find(e=>e.message===m).id,...miss}))}));
writeFileSync(out,JSON.stringify({reference:prior.reference,runnerSha256:sha(readFileSync(new URL(import.meta.url))),cases:results})+'\n',{flag:'wx'});
console.log(JSON.stringify({cases:results.length}));
