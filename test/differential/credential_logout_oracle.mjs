// Test-only: unchanged pinned Pi credential store, isolated in-memory fake credentials.
import assert from 'node:assert/strict';import {readFileSync,writeFileSync} from 'node:fs';import {resolve,join} from 'node:path';import {createHash} from 'node:crypto';import {execFileSync} from 'node:child_process';import {pathToFileURL} from 'node:url';
const root=resolve(process.argv[2]),out=process.argv[3],pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403';
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),pin);
const files=['packages/ai/src/auth/credential-store.ts','packages/ai/src/utils/abort.ts'];execFileSync('git',['-C',root,'diff','--exit-code',pin,'--',...files]);
const hashes=Object.fromEntries(files.map(file=>[file,createHash('sha256').update(readFileSync(join(root,file))).digest('hex')]));
globalThis.fetch=()=>{throw Error('Network forbidden in logout oracle')};await import(pathToFileURL(join(root,'packages/coding-agent/src/experimental/source-resolver.ts')));
const {InMemoryCredentialStore}=await import(pathToFileURL(join(root,files[0])));const store=new InMemoryCredentialStore();const cases=[];
const snapshot=async id=>cases.push({id,ids:(await store.list()).map(x=>x.providerId).sort()});
await store.modify('alpha',async()=>({type:'api_key',key:'fake-alpha'}));await store.modify('beta',async()=>({type:'api_key',key:'fake-beta'}));await snapshot('before');
await store.delete('alpha');await snapshot('selected-only');await store.delete('alpha');await snapshot('absent-idempotent');
const controller=new AbortController();controller.abort();let cancelled=false;try{await store.delete('beta',{signal:controller.signal})}catch{cancelled=true}assert(cancelled);await snapshot('cancelled-retains');
let release;let entered;const started=new Promise(r=>entered=r);const block=new Promise(r=>release=r);const writing=store.modify('beta',async()=>{entered();await block;return {type:'api_key',key:'fake-replaced'}});await started;const deleting=store.delete('beta');await snapshot('queued-delete-waits-for-writer');release();await writing;await deleting;await snapshot('delete-after-writer');
writeFileSync(out,JSON.stringify({pin,hashes,cases},null,2));console.log(JSON.stringify({cases:cases.length,network:false,realCredentials:false}));
