// Test-only original pinned main-screen renderer. Every input is generated fixture data.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const [rootArg,provenanceArg,output]=process.argv.slice(2),root=resolve(rootArg);
const provenance=JSON.parse(readFileSync(provenanceArg));
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),provenance.reference.commit);
for(const [path,hash]of Object.entries(provenance.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,path))),hash,path);
globalThis.fetch=()=>{throw Error('Network forbidden in terminal renderer oracle');};
await import(pathToFileURL(join(root,'packages/coding-agent/src/experimental/source-resolver.ts')));
const {TuiMainScreen,CURSOR_MARKER,setCapabilityOverrides}=await import(pathToFileURL(join(root,'packages/tui/src/index.ts')));
setCapabilityOverrides({images:false});
const cases=[];
const row=i=>`row ${i} \x1b[38;2;95;168;204mvalue\x1b[39m`;
for(const width of [30,60,100])for(const height of [5,12,32])for(const clear of [false,true]){
 const writes=[],terminal={columns:width,rows:height,write:data=>writes.push(data),hideCursor(){this.write('\x1b[?25l');},showCursor(){this.write('\x1b[?25h');},stop(){},start(){},moveBy(){}};
 const ui=new TuiMainScreen(terminal,false);ui.setClearOnShrink(clear);let lines=[];
 ui.addChild({render:()=>lines,invalidate(){}});
 const steps=[];
 const capture=(name,source,cursor,resize)=>{
  if(resize){terminal.columns=resize[0];terminal.rows=resize[1];}
  lines=source.map((value,index)=>cursor&&index===cursor[1]?value.slice(0,cursor[0])+CURSOR_MARKER+value.slice(cursor[0]):value);
  const start=writes.length;ui.renderNow();
  steps.push({name,lines:source,cursor:cursor??null,width:terminal.columns,height:terminal.rows,clear,writes:writes.slice(start).join(''),state:ui.captureRenderState()});
 };
 capture('first-short',[row(0),row(1),'editor'],[2,2]);
 capture('unchanged',[row(0),row(1),'editor'],[4,2]);
 capture('edit',[row(0),row(1),'edit changed'],[4,2]);
 capture('append',[row(0),row(1),'edit changed','new last'],[3,3]);
 const long=Array.from({length:height+8},(_,i)=>row(i));
 capture('overflow',long,[2,long.length-2]);
 capture('tail-edit',[...long.slice(0,-1),'tail changed'],[4,long.length-1]);
 capture('tail-delete',long.slice(0,-3),[2,long.length-4]);
 capture('change-scrollback',['first replaced',...long.slice(1,-3)],[2,long.length-4]);
 capture('shrink',['short','editor'],[3,1]);
 capture('empty',[],null);
 capture('unicode',['界👩‍💻é','abc'],[1,1]);
 capture('resize-width',['narrow','editor'],[2,1],[width-3,height]);
 capture('resize-height',['narrow','editor'],[3,1],[width-3,height+2]);
 capture('remove-cursor',['narrow','editor'],null);
 const start=writes.length;ui.stop();steps.push({name:'stop',writes:writes.slice(start).join(''),width:terminal.columns,height:terminal.rows});
 cases.push({id:`regular.w${width}.h${height}.clear${clear}`,width,height,steps});
}
writeFileSync(output,JSON.stringify({reference:provenance.reference,oracleSha256:sha(readFileSync(new URL(import.meta.url))),method:'Unmodified original TuiMainScreen.renderNow and stop; persistent terminal effects compared separately. Fixture-only rows, no CLI/provider/auth calls.',cases})+'\n',{flag:'wx'});
console.log(JSON.stringify({cases:cases.length,steps:cases.reduce((n,c)=>n+c.steps.length,0),sha256:sha(readFileSync(output))}));
