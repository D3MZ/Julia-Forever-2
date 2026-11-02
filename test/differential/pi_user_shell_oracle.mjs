// Test-only exact original shell executor; no network or model access.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,rmSync,existsSync} from 'node:fs';
import {join,resolve} from 'node:path';import{tmpdir}from'node:os';import{pathToFileURL,fileURLToPath}from'node:url';
import{createHash}from'node:crypto';import{execFileSync}from'node:child_process';
const[rootArg,manifestArg,out]=process.argv.slice(2),root=resolve(rootArg),manifest=JSON.parse(readFileSync(manifestArg)),sha=x=>createHash('sha256').update(x).digest('hex');
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),manifest.reference.commit);
for(const[p,h]of Object.entries(manifest.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,p))),h,p);
globalThis.fetch=()=>{throw Error('Network forbidden in shell oracle')};
const{executeBashWithOperations}=await import(pathToFileURL(join(root,'packages/coding-agent/src/core/bash-executor.ts')));
const{createLocalBashOperations}=await import(pathToFileURL(join(root,'packages/coding-agent/src/core/tools/bash.ts')));
const{convertToLlm,bashExecutionToText}=await import(pathToFileURL(join(root,'packages/coding-agent/src/core/messages.ts')));
const{truncateTail}=await import(pathToFileURL(join(root,'packages/coding-agent/src/core/tools/truncate.ts')));
const cwd=mkdtempSync(join(tmpdir(),'jf2-shell-oracle-')),cases=[];
async function collect(id,chunks,{cancelled=false,exitCode=0,error=null}={}){
 const streamed=[],controller=new AbortController();
 const operations={async exec(command,path,{onData}){for(const chunk of chunks)onData(Buffer.from(chunk));if(cancelled)controller.abort();if(error)throw Error(error);return{exitCode};}};
 let value;try{const r=await executeBashWithOperations('fixture',cwd,operations,{onChunk:x=>streamed.push(x),signal:controller.signal});let full=null;if(r.fullOutputPath){const until=Date.now()+5000;while(Date.now()<until){await new Promise(resolve=>setTimeout(resolve,5));if(existsSync(r.fullOutputPath)){full=readFileSync(r.fullOutputPath,'utf8');if(Buffer.byteLength(full)===Buffer.byteLength(streamed.join('')))break;}}assert.equal(full,streamed.join(''),'original output stream must finish before file comparison');}value={ok:true,output:r.output,exitCode:r.exitCode??null,cancelled:r.cancelled,truncated:r.truncated,fullOutput:full,streamed:streamed.join('')};if(r.fullOutputPath)rmSync(r.fullOutputPath,{force:true});}catch(e){value={ok:false,error:e.message,streamed:streamed.join('')};}cases.push({id,chunks:chunks.map(x=>Array.from(x)),cancelled,exitCode,error,value});
}
await collect('empty',[]);await collect('plain',[Buffer.from('one\ntwo\n')]);
await collect('ansi-fragmented',[Buffer.from('a\x1b['),Buffer.from('31mred\x1b]8;;https://unused.invalid'),Buffer.from('\x07link\x1b]8;;\x1b\\z\r\n')]);
await collect('utf8-fragmented',[Buffer.from([0xf0,0x9f]),Buffer.from([0x98,0x80,0xff,0x00,0x61])]);
await collect('binary-controls',[Buffer.from('\x00\x01\tkeep\r\n\x7f\ufff9\ufffa\ufffb')]);
await collect('nonzero',[Buffer.from('failure\n')],{exitCode:7});await collect('cancelled',[Buffer.from('partial\n')],{cancelled:true,error:'aborted'});
await collect('backend-error',[Buffer.from('partial\n')],{error:'fixture backend failed'});
await collect('line-tail',[Buffer.from(Array.from({length:2003},(_,i)=>`line ${i}\n`).join(''))]);
await collect('byte-tail',[Buffer.from('α'.repeat(30000))]);await collect('empty-line-tail',[Buffer.from('\n'.repeat(2004))]);
await collect('separate-overflow',[Buffer.from('A'.repeat(40000)),Buffer.from('B'.repeat(40000)),Buffer.from('END\n')]);
const real=[];
for(const[id,command]of[['stdout',"printf 'fixture output\\n'"],['stderr',"printf 'fixture stderr\\n' >&2"],['nonzero',"printf 'failed\\n'; exit 7"],['cwd',"printf '%s' \"${PWD##*/}\""],['ansi',"printf '\\033[31mred\\033[0m\\r\\n'"]]){
 const r=await executeBashWithOperations(command,cwd,createLocalBashOperations());real.push({id,command,output:id==='cwd'?'<fixture-directory>':r.output,exitCode:r.exitCode??null,cancelled:r.cancelled,truncated:r.truncated});
}
const tail=[];for(const text of ['','abc\n','αβγ\nnext\n','\n\n\n','long😀'.repeat(20)])for(const[maxLines,maxBytes]of[[2,10],[1,3],[4,100]])tail.push({text,maxLines,maxBytes,result:truncateTail(text,{maxLines,maxBytes})});
const messageCases=[];for(const excludeFromContext of[false,true])for(const[exitCode,cancelled,truncated]of[[0,false,false],[7,false,false],[undefined,true,false],[0,false,true]]){const record={role:'bashExecution',command:'printf fixture',output:'harmless fixture\n',exitCode,cancelled,truncated,excludeFromContext,timestamp:123,...(truncated?{fullOutputPath:'/fixture/full-output.log'}:{})};messageCases.push({record,text:bashExecutionToText(record),messages:convertToLlm([record])});}
writeFileSync(out,JSON.stringify({reference:manifest.reference,runnerSha256:sha(readFileSync(fileURLToPath(import.meta.url))),cases,real,tail,messageCases})+'\n',{flag:'wx'});rmSync(cwd,{recursive:true,force:true});
