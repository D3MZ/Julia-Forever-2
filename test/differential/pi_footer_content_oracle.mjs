// Pure original token-estimate function; schema-valid parity plus explicit legacy/invalid compatibility probes.
import assert from'node:assert/strict';import{readFileSync,writeFileSync}from'node:fs';import{resolve,join}from'node:path';import{pathToFileURL}from'node:url';import{execFileSync}from'node:child_process';import{createHash}from'node:crypto';
const[rootArg,pinArg,out]=process.argv.slice(2),root=resolve(rootArg),prior=JSON.parse(readFileSync(pinArg)),sha=x=>createHash('sha256').update(x).digest('hex');
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),prior.reference.commit);for(const[p,h]of Object.entries(prior.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,p))),h,p);
globalThis.fetch=()=>{throw Error('No network in footer oracle');};await import(pathToFileURL(join(root,'packages/coding-agent/src/experimental/source-resolver.ts')));
const{estimateTokens}=await import(pathToFileURL(join(root,'packages/coding-agent/src/core/compaction/compaction.ts')));
const cases=[];
for(const [id,content,nativeTextFallback]of[
 ['empty-array',[],false],['plain-array',[{type:'text',text:'plain text'}],false],['unicode-array',[{type:'text',text:'界👩‍💻é'}],false],
 ['rich',[{type:'text',text:'hello'},{type:'thinking',thinking:'reason'},{type:'toolCall',name:'read',arguments:{path:'file'}},{type:'image',data:'ignored'}],false],
 ['empty-string','',true],['legacy-string','plain text',true],['legacy-unicode','界👩‍💻é',true],['invalid-null',null,true],['invalid-number',42,true],['invalid-object',{text:'not an array'},true],['invalid-blocks',[null,7,'not a block'],true],['invalid-text',[{type:'text',text:null},{type:'thinking',thinking:false}],true]]){
 const message={role:'assistant',content};let original;try{original={ok:true,tokens:estimateTokens(message)}}catch(error){original={ok:false,error:error.name}}
 cases.push({id,message,nativeTextFallback,original});
}
writeFileSync(out,JSON.stringify({reference:prior.reference,runnerSha256:sha(readFileSync(new URL(import.meta.url))),cases})+'\n',{flag:'wx'});console.log(JSON.stringify({cases:cases.length}));
