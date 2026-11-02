// Fixture-only original Undici client/HTTP parser and clock. No real sockets or requests.
import assert from 'node:assert/strict';import{readFileSync,writeFileSync}from'node:fs';import{createHash}from'node:crypto';import{execFileSync}from'node:child_process';import{createRequire}from'node:module';import{Duplex}from'node:stream';import{once}from'node:events';import{join,resolve}from'node:path';
const[rootArg,provenanceArg,output]=process.argv.slice(2),root=resolve(rootArg),pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403',sha=b=>createHash('sha256').update(b).digest('hex'),p=JSON.parse(readFileSync(provenanceArg));
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),pin);assert.equal(p.reference.commit,pin);assert.equal(Object.keys(p.reference.sourceHashes).length,513);for(const[path,hash]of Object.entries(p.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,path))),hash,path);
await import(root+'/packages/coding-agent/src/experimental/source-resolver.ts');const{HTTP_IDLE_TIMEOUT_CHOICES}=await import(root+'/packages/coding-agent/src/core/http-dispatcher.ts');const req=createRequire(join(root,'package.json')),{Client}=req('undici'),timers=req('undici/lib/util/timers.js');
class FixtureSocket extends Duplex{_read(){} _write(chunk,enc,callback){callback()}setNoDelay(){return this}setKeepAlive(){return this}ref(){return this}unref(){return this}}
const flush=()=>new Promise(setImmediate),cases=[];
for(const choice of HTTP_IDLE_TIMEOUT_CHOICES)for(const scenario of ['headers-idle','partial-headers','body-idle','slow-body']){
 timers.reset();const socket=new FixtureSocket(),events=[],steps=[];let controller;
 const client=new Client('http://fixture.invalid',{headersTimeout:choice.timeoutMs,bodyTimeout:choice.timeoutMs,allowH2:false,connect:(options,callback)=>queueMicrotask(()=>callback(null,socket))});
 const connected=once(client,'connect');client.dispatch({method:'GET',path:'/'},{onRequestStart(c){controller=c;events.push({kind:'start'})},onResponseStart(c,status){events.push({kind:'headers',status})},onResponseData(c,data){events.push({kind:'data',data:data.toString()})},onResponseEnd(){events.push({kind:'complete'})},onResponseError(c,error){events.push({kind:'error',code:error.code??null})}});
 await connected;await flush();timers.tick(0);
 const capture=action=>steps.push({action,events:structuredClone(events)});
 async function data(text){socket.push(Buffer.from(text));await flush();capture({type:'data',text});timers.tick(0)}
 async function advance(milliseconds){timers.tick(milliseconds);await flush();capture({type:'advance',milliseconds})}
 if(scenario==='partial-headers')await data('HTTP/1.1 200 OK\r\nX-Partial: yes\r\n');
 if(scenario==='body-idle')await data('HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\none');
 if(scenario==='slow-body'){
  await data('HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\none');
  for(const chunk of ['two','tri','end']){await advance(choice.timeoutMs?choice.timeoutMs/2:1_000_000);await data(chunk)}
 }else await advance(choice.timeoutMs?choice.timeoutMs+2000:1_000_000);
 cases.push({label:choice.label,timeoutMs:choice.timeoutMs,scenario,steps,outcome:events.at(-1)});
 await client.destroy();timers.reset();
}
const dependencyPaths=['node_modules/undici/package.json','node_modules/undici/lib/dispatcher/client.js','node_modules/undici/lib/dispatcher/client-h1.js','node_modules/undici/lib/core/request.js','node_modules/undici/lib/util/timers.js'];
writeFileSync(output,JSON.stringify({schemaVersion:1,pin,sourceHashes:p.reference.sourceHashes,dependencyHashes:Object.fromEntries(dependencyPaths.map(path=>[path,sha(readFileSync(join(root,path)))])),cases,networkCalls:0,clock:'Original Undici exported testing clock; ticks include its documented coarse timer resolution, not wall-clock benchmarks.'},null,2)+'\n');
