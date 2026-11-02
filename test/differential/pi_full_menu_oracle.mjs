// Original-source whole-scene oracle: original components, original fullscreen layout and footer.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join,resolve} from 'node:path';import {tmpdir} from 'node:os';
import {pathToFileURL,fileURLToPath} from 'node:url';import {createHash} from 'node:crypto';import {execFileSync} from 'node:child_process';
const [rootArg,provenanceArg,out]=process.argv.slice(2),root=resolve(rootArg),prior=JSON.parse(readFileSync(provenanceArg)),sha=x=>createHash('sha256').update(x).digest('hex');
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),'2c8d1feb147f6b3d97e855da803bfe7b19f3c403');
for(const [file,hash]of Object.entries(prior.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,file))),hash,file);
const temp=mkdtempSync(join(tmpdir(),'pi-full-menu-'));process.env.PI_CODING_AGENT_DIR=temp;process.env.PI_OFFLINE='1';process.env.COLORTERM='truecolor';process.env.TERM='xterm-256color';process.env.PI_EXPERIMENTAL='0';globalThis.fetch=()=>{throw Error('Network forbidden');};
const load=p=>import(pathToFileURL(join(root,p)).href);await load('packages/coding-agent/src/experimental/source-resolver.ts');
const tui=await load('packages/tui/src/index.ts'),layout=await load('packages/tui/src/layout.ts'),th=await load('packages/coding-agent/src/modes/interactive/theme/theme.ts');
const {KeybindingsManager}=await load('packages/coding-agent/src/core/keybindings.ts'),keys=new KeybindingsManager();tui.setKeybindings(keys);tui.setCapabilityOverrides({images:false,trueColor:true,hyperlinks:false});th.initTheme('dark');
const {createChatViewport}=await load('packages/coding-agent/src/modes/interactive/chat-viewport.ts');
const components=await Promise.all(['thinking-selector','theme-selector','model-selector','scoped-models-selector','user-message-selector','custom-editor','footer'].map(name=>load(`packages/coding-agent/src/modes/interactive/components/${name}.ts`)));
const [{ThinkingSelectorComponent},{ThemeSelectorComponent},{ModelSelectorComponent},{ScopedModelsSelectorComponent},{UserMessageSelectorComponent},{CustomEditor},{FooterComponent}]=components;
const renderer=Object.create(tui.TuiMainScreen.prototype);renderer.showHardwareCursor=false;
const normalize=lines=>{const rows=renderer.resolveFakeCursors(lines);const cursor=renderer.extractCursorPosition(rows,rows.length);return{rows:renderer.applyLineResets(rows),cursor};};
const model=(id,provider='demo')=>({id,name:id,provider,api:'openai-completions',baseUrl:'http://fixture.invalid',reasoning:true,input:['text'],contextWindow:128000,maxTokens:8192,cost:{input:0,output:0,cacheRead:0,cacheWrite:0}});
const models=[model('alpha'),model('beta'),model('gamma','other'),...Array.from({length:11},(_,i)=>model(`model-${i}`,i%2?'other':'demo'))];
const messages=Array.from({length:15},(_,i)=>({id:`message-${i}`,text:`Message ${i}: fixture 指示 👩‍💻`}));
const specs=[['thinking',['\x1b[B','deep','\x15','\x1b']],['theme',['\x1b[B','\x1b']],['model',['\x1b[B','gamma','\x15','\x1b']],['scoped',['\x1b[B','gamma','\x15','\x1b']],['fork',['\x1b[A','\x1b[5~','\x1b']]];
const snapshots=[],cases=[];
for(const [kind,inputs]of specs)for(const width of [100,60,30])for(const height of [32,12,5]){
 th.setTheme('dark');const events=[],fakeTui={terminal:{rows:height,columns:width},requestRender(){}};
 const editor=new CustomEditor(fakeTui,th.getEditorTheme(),keys);editor.focused=true;
 const host=new tui.Container();let active;const close=()=>{events.push({kind:'cancel'});host.clear();host.addChild(editor);};
 const cb=kind=>value=>events.push({kind,value});
 if(kind==='thinking')active=new ThinkingSelectorComponent('medium',['off','minimal','low','medium','high','xhigh','max'],cb('select'),close,cb('default'),'high');
 if(kind==='theme')active=new ThemeSelectorComponent('dark',cb('select'),close,name=>{th.setTheme(name);events.push({kind:'preview',value:name});});
 if(kind==='model'){
  const runtime={getAvailableSnapshot:()=>models,getModel:(p,id)=>models.find(m=>m.provider===p&&m.id===id),getError:()=>undefined,refresh:async()=>({aborted:false,errors:new Map()})};
  active=new ModelSelectorComponent(fakeTui,models[0],runtime,[],cb('select'),close,undefined,cb('default'),models[1]);await new Promise(resolve=>setImmediate(resolve));
 }
 if(kind==='scoped')active=new ScopedModelsSelectorComponent({allModels:models,enabledModelIds:null},{onChange:cb('change'),onPersist:cb('persist'),onCancel:close});
 if(kind==='fork')active=new UserMessageSelectorComponent(messages,cb('select'),close);
 if('focused'in active)active.focused=true;host.addChild(active);
 const session={state:{},model:undefined,getContextUsage:()=>undefined,modelRuntime:{isUsingSubscription:()=>false},sessionManager:{getCwd:()=>'/fixture/project',getSessionName:()=>undefined,getSessionId:()=> 'fixture',getLeafId:()=>null,getEntryCount:()=>0,getEntries:()=>[]}};
 const footer=new FooterComponent(session,{getGitBranch:()=>undefined,getAvailableProviderCount:()=>0,getExtensionStatuses:()=>new Map()});const empty=new tui.Container();
 const viewport=createChatViewport({document:empty,pendingMessages:empty,status:empty,widgetsAbove:new tui.Spacer(1),editor:host,widgetsBelow:empty,footer,scrollbar:'hidden'});
 const steps=[];
 const capture=step=>{const frame=layout.renderLayoutFrame(viewport.root,width,height,()=>{}),normalized=normalize(frame.lines),id=`${kind}.h${height}.${step}`;snapshots.push({id,width,terminalAnsiLines:normalized.rows});steps.push({id,step,cursor:normalized.cursor??null,events:structuredClone(events),theme:th.theme.name,page:host.children[0]===editor?'chat':kind});};
 capture(-1);for(const [index,input]of inputs.entries()){(kind==='theme'?active.getSelectList():kind==='fork'?active.getMessageList():active).handleInput(input);capture(index);}cases.push({kind,width,height,inputs,steps});if(kind==='model')active.dispose();
}
writeFileSync(out,JSON.stringify({reference:prior.reference,runnerSha256:sha(readFileSync(fileURLToPath(import.meta.url))),method:'Original unmodified components, CustomEditor cancel destination, FooterComponent and createChatViewport/renderLayoutFrame. Fixture-only models/callbacks, no provider/auth/CLI calls. Native side must render actual App.',models,messages,themes:th.getAvailableThemes(),cases,snapshots})+'\n',{flag:'wx'});th.stopThemeWatcher();rmSync(temp,{recursive:true,force:true});console.log(JSON.stringify({cases:cases.length,frames:snapshots.length,sha256:sha(readFileSync(out))}));
