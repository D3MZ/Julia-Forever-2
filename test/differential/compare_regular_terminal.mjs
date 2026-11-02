import assert from 'node:assert/strict';import {readFileSync,writeFileSync} from 'node:fs';import {createRequire} from 'node:module';import {resolve,join} from 'node:path';
const [rootArg,originalPath,nativePath,reportPath]=process.argv.slice(2),root=resolve(rootArg);
const require=createRequire(join(root,'package.json'));const {Terminal}=require('@xterm/headless');
const original=JSON.parse(readFileSync(originalPath)),native=JSON.parse(readFileSync(nativePath));
const cell=c=>[c.getChars()||' ',c.getWidth(),c.getFgColorMode(),c.getFgColor(),c.getBgColorMode(),c.getBgColor(),c.isBold(),c.isDim(),c.isItalic(),c.isUnderline(),c.isInverse(),c.isStrikethrough(),c.isInvisible()];
const state=t=>{const b=t.buffer.active;return{type:b.type,cursor:[b.cursorX,b.cursorY],base:b.baseY,viewport:b.viewportY,rows:Array.from({length:b.length},(_,i)=>Array.from({length:t.cols},(_,x)=>cell(b.getLine(i).getCell(x))))};};
const failures=[];let checked=0;const snapshots=[];
for(const a of original.cases){const b=native.cases.find(c=>c.id===a.id);assert(b,a.id);const terminals=[a,b].map(()=>new Terminal({cols:a.width,rows:a.height,allowProposedApi:true,scrollback:1000}));
 for(const t of terminals)await new Promise(done=>t.write('prior shell output\r\n',done));
 for(let i=0;i<a.steps.length;i++){
  for(let side=0;side<2;side++){const t=terminals[side],step=[a,b][side].steps[i];t.resize(step.width,step.height);await new Promise(done=>t.write(step.writes,done));}
  const states=terminals.map(state);const equal=JSON.stringify(states[0])===JSON.stringify(states[1]);checked++;if(!equal)failures.push({id:a.id,step:a.steps[i].name,original:states[0],native:states[1]});
  snapshots.push({id:a.id+'.'+a.steps[i].name,width:a.steps[i].width,height:a.steps[i].height,equal,states});
 }terminals.forEach(t=>t.dispose());
}
writeFileSync(reportPath,JSON.stringify({method:'Persistent original/native @xterm/headless normal screen plus full scrollback, cursor and cell attributes after every update. Seeded prior shell output.',checked,matching:checked-failures.length,failures,snapshots})+'\n');console.log(JSON.stringify({checked,matching:checked-failures.length,failures:failures.map(f=>[f.id,f.step])}));
