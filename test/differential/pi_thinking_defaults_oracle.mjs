// Fixture-only original Pi settings submenu. No provider/auth/network calls or candidate imports.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL,fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const [rootArg,provenanceArg,outputArg]=process.argv.slice(2),root=resolve(rootArg),output=resolve(outputArg);
const sha=data=>createHash('sha256').update(data).digest('hex');
const provenanceBytes=readFileSync(provenanceArg),prior=JSON.parse(provenanceBytes),pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403';
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),pin);
assert.equal(prior.reference.commit,pin);assert.equal(Object.keys(prior.reference.sourceHashes).length,513);
for(const [path,hash]of Object.entries(prior.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,path))),hash,path);
const fixtureRoot=mkdtempSync(join(tmpdir(),'pi-thinking-defaults-'));process.env.PI_CODING_AGENT_DIR=fixtureRoot;process.env.PI_OFFLINE='1';process.env.PI_EXPERIMENTAL='0';process.env.COLORTERM='truecolor';
globalThis.fetch=()=>{throw Error('Network forbidden in fixture oracle');};
const load=path=>import(pathToFileURL(join(root,path)).href);
await load('packages/coding-agent/src/experimental/source-resolver.ts');
const tui=await load('packages/tui/src/index.ts');
const th=await load('packages/coding-agent/src/modes/interactive/theme/theme.ts');
const {SettingsSelectorComponent}=await load('packages/coding-agent/src/modes/interactive/components/settings-selector.ts');
const {KeybindingsManager}=await load('packages/coding-agent/src/core/keybindings.ts');
tui.setKeybindings(new KeybindingsManager());tui.setCapabilityOverrides({images:false,trueColor:true,hyperlinks:false});th.initTheme('dark');
const renderer=Object.create(tui.TuiMainScreen.prototype);renderer.showHardwareCursor=false;
const normalize=rows=>{const out=renderer.resolveFakeCursors(rows);renderer.extractCursorPosition(out,out.length);return out;};
const base=prior.fixtures.settingsConfig,models=base.availableDefaultModels;
const cases=[],widths=[100,60,30,10,5];
const key=data=>({kind:'key',data}),choose=(value,activate=true)=>({kind:'choose',value,activate});
function capture(id,changes,commands){
 for(const width of widths){
  const config={...structuredClone(base),...structuredClone(changes)};const callbacks=[],saved={...config.modelThinkingLevels};
  const component=new SettingsSelectorComponent(config,new Proxy({
   onModelThinkingLevelChange:(provider,id,level)=>{callbacks.push({kind:'set',provider,id,level});saved[`${provider}/${id}`]=level;},
   onModelThinkingLevelRemove:(provider,id)=>{callbacks.push({kind:'remove',provider,id});delete saved[`${provider}/${id}`];}
  },{get:(target,name)=>target[name]??((...args)=>callbacks.push({kind:String(name),args}))}));
  const parent=component.getSettingsList();parent.selectItem('model-thinking');parent.handleInput('\r');
  function snapshot(){
   const rows=component.render(width),sub=parent.submenuComponent,active=sub?.activeComponent,list=active?.selectList;
   const items=(list?.filteredItems??[]).map(item=>({value:item.value,label:item.label,description:item.description??''}));
   return {open:!!sub,step:sub?(active.searchInput?'model':'level'):null,context:sub?{...sub.context}:{},query:active?.searchInput?.getValue()??'',cursorUtf16:active?.searchInput?.cursor??0,selectedIndex:list?.selectedIndex??null,items,overrides:{...saved},callbacks:structuredClone(callbacks),summary:parent.items.find(item=>item.id==='model-thinking').currentValue,parentSelectedIndex:parent.selectedIndex,parentValues:Object.fromEntries(parent.items.map(item=>[item.id,item.currentValue])),terminalAnsiLines:normalize(rows)};
  }
  const initial=snapshot(),transitions=[];
  function step(event){
   let dispatch=null;
   if(event.kind==='mouse'){const before=snapshot();const result=component.handleMouse({type:event.type,button:event.button??'left',x:2,y:event.y??5,screenX:2,screenY:5,width,height:before.terminalAnsiLines.length,shift:false,alt:false,ctrl:false,wheelDelta:event.wheelDelta??0});dispatch=result?Object.fromEntries(['handled','focus','render'].filter(k=>Object.hasOwn(result,k)).map(k=>[k,result[k]])):null;}
   else parent.handleInput(event.data);
   transitions.push({index:transitions.length,event,dispatch,after:snapshot()});
  }
  for(const command of commands){
   if(command.kind==='choose'){
    const list=parent.submenuComponent.activeComponent.selectList,items=list.filteredItems;assert(items.some(item=>item.value===command.value),`${id}: missing ${command.value}`);
    let count=0;while(parent.submenuComponent.activeComponent.selectList.filteredItems[parent.submenuComponent.activeComponent.selectList.selectedIndex]?.value!==command.value){assert(count++<=items.length);step(key('\x1b[B'));}
    if(command.activate)step(key('\r'));
   }else step(command);
  }
  cases.push({id,width,config,initial,transitions,final:snapshot()});
 }
}
const normal={currentModel:models[0],defaultModel:'other/gamma',modelThinkingLevels:{'demo/alpha':'high','unavailable/old':'low'}};
capture('defaults.cancel-model',normal,[key('\x1b')]);
capture('defaults.current-default-order',normal,[key('\x1b[B'),key('\x1b[A'),key('\x1b[6~'),key('\x1b[5~'),key('\x03')]);
capture('defaults.set-loop-clear',normal,[choose('demo/alpha'),choose('max'),choose('demo/alpha'),choose('__clear__'),key('\x1b')]);
capture('defaults.nonreasoning',normal,[choose('demo/beta'),choose('off'),choose('demo/beta'),choose('__clear__'),key('\x1b')]);
capture('defaults.map-exclusions',normal,[choose('other/gamma'),choose('medium'),choose('other/gamma'),key('\x1b'),key('\x1b')]);
capture('defaults.cancel-level-preserves',normal,[choose('demo/alpha'),key('\x1b[B'),key('\x03'),key('\x1b')]);
for(const query of ['gamma','demo high','model / 01','zzzzzzz','157','38','  ','\u03b1'])capture(`defaults.search-${JSON.stringify(query)}`,normal,[key(query),key('\x1b[D'),key('\x7f'),key('\x1b')]);
capture('defaults.search-select-reset',normal,[key('gamma'),key('\r'),choose('high'),key('\x1b')]);
capture('defaults.long-search',normal,[key('abcdefghijklmnop'.repeat(7)),key('\x01'),key('Z'),key('\x05'),key('\x7f'),key('\x1b')]);
capture('defaults.empty-models',{...normal,currentModel:undefined,availableDefaultModels:[],defaultModel:'missing/id'},[key('\r'),key('\x1b[A'),key('\x1b[B'),key('\r'),key('\x1b'),key('\x1b')]);
capture('defaults.unavailable-current-default',{...normal,currentModel:{...models[0],id:'absent'},defaultModel:'absent/default'},[key('\r'),key('\x1b'),key('\x1b')]);
capture('defaults.no-overrides',{...normal,modelThinkingLevels:{}},[key('\r'),key('\x1b'),key('\x1b')]);
capture('defaults.mouse-ignored',normal,[{kind:'mouse',type:'press'},{kind:'mouse',type:'click'},{kind:'mouse',type:'wheel',wheelDelta:1},{kind:'mouse',type:'release'},key('\r'),{kind:'mouse',type:'click'},key('\x1b'),key('\x1b')]);
const outputData={schemaVersion:1,reference:prior.reference,provenance:{checkedSourceFiles:513,runnerSha256:sha(readFileSync(fileURLToPath(import.meta.url))),provenanceSha256:sha(provenanceBytes)},method:'Unmodified original SettingsSelector model-thinking -> SteppedSubmenu; fixture-only callback requests; original rendering and real input dispatch; no provider calls or persistence claim.',cases,summary:{cases:cases.length,transitions:cases.reduce((n,c)=>n+c.transitions.length,0),frames:cases.reduce((n,c)=>n+1+c.transitions.length,0),widths}};
writeFileSync(output,JSON.stringify(outputData)+'\n',{flag:'wx'});th.stopThemeWatcher();rmSync(fixtureRoot,{recursive:true,force:true});console.log(JSON.stringify({...outputData.summary,sha256:sha(readFileSync(output))}));
