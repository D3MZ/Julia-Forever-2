// Pinned original status method and real Container/ThemedText. Fixture-only; no CLI/provider.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const [rootArg,provenanceArg,out]=process.argv.slice(2),root=resolve(rootArg),prior=JSON.parse(readFileSync(provenanceArg));
const sha=b=>createHash('sha256').update(b).digest('hex');
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),prior.reference.commit);
for(const [path,hash]of Object.entries(prior.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,path))),hash,path);
globalThis.fetch=()=>{throw Error('No network in notice oracle');};
await import(pathToFileURL(join(root,'packages/coding-agent/src/experimental/source-resolver.ts')));
const load=p=>import(pathToFileURL(join(root,p)));
const tui=await load('packages/tui/src/index.ts');
const th=await load('packages/coding-agent/src/modes/interactive/theme/theme.ts');
const {InteractiveMode}=await load('packages/coding-agent/src/modes/interactive/interactive-mode.ts');
th.initTheme('dark');tui.setCapabilityOverrides({images:false,trueColor:true,hyperlinks:false});
const normalize=Object.create(tui.TuiMainScreen.prototype);normalize.showHardwareCursor=false;
const events=[['notice','TUI mode: fullscreen'],['notice','TUI mode: regular'],['record','message one'],['notice','Tool output: expanded'],['notice','Tool output: collapsed'],['document','real command output'],['notice','After the command'],['record','message two'],['notice','Long notice 界 👩‍💻 é abcdefghijklmnopqrstuvwxyz'],['notice','first line\nsecond line'],['theme','light'],['reset','new session'],['notice','New session notice']];
const snapshots=[];
for(const width of [5,10,30,60,100]){
 th.setTheme('dark');const mode=Object.create(InteractiveMode.prototype);mode.chatContainer=new tui.Container();mode.ui={requestRender(){}};
 for(const [index,event]of events.entries()){
  const [action,text]=event;
  if(action==='notice')mode.showStatus(text);
  else if(action==='theme'){th.setTheme(text);mode.chatContainer.invalidate();}
  else if(action==='reset')mode.chatContainer.clear();
  else mode.chatContainer.addChild(new tui.Text(text,1,0));
  snapshots.push({id:`notice.${index}`,width,event,terminalAnsiLines:normalize.applyLineResets(mode.chatContainer.render(width))});
 }
}
writeFileSync(out,JSON.stringify({reference:prior.reference,runnerSha256:sha(readFileSync(new URL(import.meta.url))),events,snapshots})+'\n',{flag:'wx'});
th.stopThemeWatcher();
console.log(JSON.stringify({frames:snapshots.length}));
