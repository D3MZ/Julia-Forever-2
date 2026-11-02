// Original pinned session-resume/fork components; fixture-only async owners and disposable files.
// Usage: node pi-resume-fork-oracle.mjs PI_ROOT PROVENANCE_JSON NEW_OUTPUT_JSON
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [rootArg, provenanceArg, outputArg] = process.argv.slice(2);
assert(rootArg && provenanceArg && outputArg);
const root=resolve(rootArg), output=resolve(outputArg), sha=x=>createHash("sha256").update(x).digest("hex");
const provenanceBytes=readFileSync(resolve(provenanceArg)), prior=JSON.parse(provenanceBytes);
const pin="2c8d1feb147f6b3d97e855da803bfe7b19f3c403";
assert.equal(execFileSync("git",["-C",root,"rev-parse","HEAD"],{encoding:"utf8"}).trim(),pin);
assert.equal(prior.reference.commit,pin);
assert.equal(Object.keys(prior.reference.sourceHashes).length,513);
for(const [path,hash] of Object.entries(prior.reference.sourceHashes)) assert.equal(sha(readFileSync(join(root,path))),hash,path);
const fixtureRoot=join(tmpdir(),"pi-resume-fork-component-fixtures");
assert(!existsSync(fixtureRoot),"Refusing to reuse an existing fixture directory; serialize oracle runs");
mkdirSync(fixtureRoot); mkdirSync(join(fixtureRoot,"agent")); mkdirSync(join(fixtureRoot,"empty-path"));
process.on("exit",()=>rmSync(fixtureRoot,{recursive:true,force:true}));
process.env.HOME=fixtureRoot;
process.env.PI_CODING_AGENT_DIR=join(fixtureRoot,"agent");
process.env.PI_OFFLINE="1"; process.env.PI_EXPERIMENTAL="0"; process.env.TZ="UTC";
process.env.COLORTERM="truecolor";process.env.TERM="xterm-256color";
// Original deletion must take its real unlink fallback, never a user's installed trash program.
process.env.PATH=join(fixtureRoot,"empty-path");
globalThis.fetch=()=>{throw new Error("Network forbidden in resume/fork oracle");};
const fixedTime="2026-11-01T12:34:56.000Z", RealDate=Date;
class FixtureDate extends RealDate {constructor(...args){super(...(args.length?args:[fixedTime]));} static now(){return RealDate.parse(fixedTime);}}
globalThis.Date=FixtureDate;
const imports=[];
const load=path=>{imports.push(path);return import(pathToFileURL(join(root,path)).href);};
await load("packages/coding-agent/src/experimental/source-resolver.ts");
const tui=await load("packages/tui/src/index.ts");
const {getGraphemeSegmenter,visibleWidth}=await load("packages/tui/src/utils.ts");
const {KeybindingsManager}=await load("packages/coding-agent/src/core/keybindings.ts");
const {SessionSelectorComponent}=await load("packages/coding-agent/src/modes/interactive/components/session-selector.ts");
const {UserMessageSelectorComponent}=await load("packages/coding-agent/src/modes/interactive/components/user-message-selector.ts");
const search=await load("packages/coding-agent/src/modes/interactive/components/session-selector-search.ts");
const th=await load("packages/coding-agent/src/modes/interactive/theme/theme.ts");
tui.setKeybindings(new KeybindingsManager());tui.setCapabilityOverrides({images:false,trueColor:true,hyperlinks:false});th.initTheme("dark");
const renderer=Object.create(tui.TuiMainScreen.prototype);renderer.showHardwareCursor=false;
const segmenter=getGraphemeSegmenter();
let timerId=0;
const timers=new Map();
globalThis.setTimeout=(callback,delay)=>{const id=++timerId;timers.set(id,{callback,delay});return id;};
globalThis.clearTimeout=id=>timers.delete(id);
const settle=async()=>{await new Promise(setImmediate);await new Promise(setImmediate);};
const dateAgo=milliseconds=>new Date(Date.now()-milliseconds);
const catalog=Array.from({length:16},(_,i)=>({
  id:`session-${String(i).padStart(2,"0")}`,path:join(fixtureRoot,`session-${String(i).padStart(2,"0")}.jsonl`),
  cwd:i<12?join(fixtureRoot,"work"):join(fixtureRoot,"other"),created:dateAgo((i+3)*86400000),
  modified:dateAgo([0,60000,59*60000,3600000,23*3600000,86400000,6*86400000,7*86400000,29*86400000,30*86400000,364*86400000,365*86400000,2000,70000,7200000,172800000][i]),
  messageCount:i*7+1,firstMessage:i===2?"message with\nline\ttab\x01control":`First message ${i} 漢字 👩‍💻`,
  allMessagesText:i===3?"exact node\n CVE phrase and alpha token":`Conversation ${i} alpha ${i%2?"project":"analysis"}`,
  ...(i%3===0?{name:i===0?"Current project":i===3?"Alpha Service":i===6?"alphabet report":i===9?"   ":`Named ${i}`} : {}),
  ...(i===1||i===2?{parentSessionPath:join(fixtureRoot,"session-03.jsonl")}:i===4?{parentSessionPath:join(fixtureRoot,"session-01.jsonl")}:{}),
}));
const blocked={...catalog[5],id:"blocked",path:join(fixtureRoot,"blocked-dir"),name:"Blocked deletion",modified:dateAgo(500),parentSessionPath:undefined};
const messages=Array.from({length:15},(_,i)=>({id:`user-${i}`,text:i===7?"line one\nline two 漢字 👩‍💻\ttab":`User message ${i} `+"word ".repeat(i),timestamp:dateAgo(i*1000).toISOString()}));
function resetFiles(){for(const item of catalog)writeFileSync(item.path,"fixture only\n");if(!existsSync(blocked.path))mkdirSync(blocked.path);}
function inputSnapshot(input){const value=input.getValue(),bounds=[...segmenter.segment(value)].map(x=>x.index).concat(value.length);return{value,cursorUtf16:input.cursor,cursorGrapheme:bounds.indexOf(input.cursor),renderedStartColumn:input.renderedStartColumn,pasting:input.isInPaste,pasteBuffer:input.pasteBuffer};}
const cases=[],snapshots=[];
async function captureResume(id,spec,commands){
 for(const width of [100,60,30]){
  timers.clear();resetFiles();
  let currentRows=structuredClone(catalog.slice(0,12)),allRows=structuredClone(catalog);
  if(spec.empty)currentRows=allRows=[];
  if(spec.blocked){currentRows=[structuredClone(blocked),...currentRows];allRows=[structuredClone(blocked),...allRows];}
  const loads=[],renames=[],operations=[],callbackEvents=[];
  const callbacks={selectRequests:[],renameRequests:[],cancelCount:0,exitCount:0,renderCount:0,operationErrors:[]};
  const loader=scope=>(progress,signal)=>new Promise((resolve,reject)=>{loads.push({id:loads.length+1,scope,progress,signal,resolve,reject,settled:false});callbackEvents.push({action:"load",scope,id:loads.length});});
  const rename=async(path,value)=>{callbacks.renameRequests.push({path,value});callbackEvents.push({action:"rename",path,value});await new Promise((resolve,reject)=>renames.push({path,value,resolve,reject,settled:false}));};
  const component=new SessionSelectorComponent(loader("current"),loader("all"),path=>{callbacks.selectRequests.push(path);callbackEvents.push({action:"select",path});},()=>{callbacks.cancelCount++;callbackEvents.push({action:"cancel"});},()=>{callbacks.exitCount++;callbackEvents.push({action:"exit"});},()=>callbacks.renderCount++,{keybindings:new KeybindingsManager(),...(spec.rename===false?{}:{renameSession:rename}),...(spec.showRenameHint===undefined?{}:{showRenameHint:spec.showRenameHint})},spec.noCurrent?undefined:catalog[0].path);
  component.focused=spec.focused??true;
  // Observe promises returned by original methods; never replace state or render logic.
  for(const [owner,key] of [[component,"confirmRename"],[component.getSessionList(),"onDeleteSession"]]){
    const original=owner[key].bind(owner);
    owner[key]=(...args)=>{const operation={key,settled:false,loadCount:loads.length};const promise=original(...args);operations.push(operation);promise.then(()=>operation.settled=true,error=>{operation.settled=true;callbacks.operationErrors.push(String(error.message??error));});return promise;};
  }
  function snapshot(){
    const ansiLines=component.render(width),terminalAnsiLines=renderer.applyLineResets(renderer.resolveFakeCursors(ansiLines)),list=component.getSessionList(),header=component.header;
    return {mode:component.mode,scope:component.scope,sortMode:component.sortMode,nameFilter:component.nameFilter,capturesViewportInput:component.capturesViewportInput,
      selectedIndex:list.selectedIndex,selectedPath:list.getSelectedSessionPath()??null,selectionTouched:list.selectionTouched,
      search:inputSnapshot(list.searchInput),renameInput:inputSnapshot(component.renameInput),renameTargetPath:component.renameTargetPath,
      showCwd:list.showCwd,showPath:list.showPath,confirmingDeletePath:list.confirmingDeletePath,maxVisible:list.maxVisible,
      rows:list.filteredSessions.map(n=>({path:n.session.path,depth:n.depth,isLast:n.isLast,ancestorContinues:n.ancestorContinues})),
      currentSessions:component.currentSessions,allSessions:component.allSessions,currentLoading:!!component.currentLoad,allLoading:!!component.allLoad,
      header:{scope:header.scope,sortMode:header.sortMode,nameFilter:header.nameFilter,loading:header.loading,progress:header.loadProgress,showPath:header.showPath,showRenameHint:header.showRenameHint,confirmingDeletePath:header.confirmingDeletePath,status:header.statusMessage},
      loads:loads.map(l=>({id:l.id,scope:l.scope,settled:l.settled,aborted:l.signal.aborted})),timerDelays:[...timers.values()].map(t=>t.delay),
      callbackState:structuredClone(callbacks),hardwareCursor:renderer.extractCursorPosition(terminalAnsiLines,terminalAnsiLines.length)??null,
      ansiLines,terminalAnsiLines,lineDisplayWidths:terminalAnsiLines.map(visibleWidth)};
  }
  const initial=snapshot(),initialEvents=callbackEvents.splice(0),transitions=[];
  snapshots.push({id:id+".initial",width,terminalAnsiLines:initial.terminalAnsiLines});
  async function step(event){
    let result=null;
    const operationCount=operations.length;
    if(event.type==="key")component.handleInput(event.data);
    else if(event.type==="load"){
      const pending=loads.find(l=>!l.settled&&(event.id?l.id===event.id:l.scope===event.scope));assert(pending,`${id}: pending load missing`);
      const source=pending.scope==="current"?currentRows:allRows;
      if(event.action==="progress")pending.progress(event.loaded,event.total,event.partial===false?undefined:structuredClone(source.slice(0,event.loaded)));
      else{pending.settled=true;if(event.action==="reject")pending.reject(new Error(event.error??"fixture load denied"));else pending.resolve(structuredClone(source.filter(row=>existsSync(row.path))));}
    }else if(event.type==="rename"){
      const pending=renames.find(r=>!r.settled);assert(pending);pending.settled=true;
      if(event.action==="reject")pending.reject(new Error("fixture rename denied"));
      else{for(const row of [...currentRows,...allRows])if(row.path===pending.path)row.name=pending.value;pending.resolve();}
    }else if(event.type==="timers"){const queued=[...timers.entries()];timers.clear();for(const[,timer]of queued)timer.callback();}
    else if(event.type==="mouse"){
      const list=component.getSessionList(),input=component.renameInput;
      let targetY=0;
      function locate(node,target,top=0){if(node===target)return top;let y=top;for(const child of node.children??[]){const found=locate(child,target,y);if(found!==null)return found;y+=child.render(width).length;}return null;}
      targetY=event.target==="rename"?locate(component,input)??0:locate(component,list)??0;
      const dispatched=component.handleMouse({type:event.action,button:"left",x:event.x??3,y:targetY+(event.y??0),screenX:event.x??3,screenY:targetY+(event.y??0),width,height:component.render(width).length,shift:false,alt:false,ctrl:false,wheelDelta:event.wheelDelta??1,clickCount:1});
      result=dispatched?{handled:dispatched.handled??false,focus:dispatched.focus??false,capture:dispatched.capture??false,render:dispatched.render??null,target:dispatched.target?.component===input?"rename":null,focusTarget:dispatched.focusTarget===component?"selector":null}:null;
    }else if(event.type!=="settle")throw new Error("Unknown event");
    const startedDelete=operations.length>operationCount&&operations.at(-1).key==="onDeleteSession";
    if(event.type==="settle"){
      const pending=operations.at(-1);let guard=0;
      while(pending&&!pending.settled&&loads.length===pending.loadCount){assert(guard++<10000,"Original delete did not reach load or completion boundary");await new Promise(setImmediate);}
    }
    // Enter is captured synchronously before original filesystem I/O completes.
    // Explicit settle advances to original refresh-request or failure completion.
    if(!startedDelete)await settle();
    const after=snapshot(),index=transitions.length;
    transitions.push({index,event,result,callbackEvents:callbackEvents.splice(0),after});
    snapshots.push({id:`${id}.step-${index}`,width,terminalAnsiLines:after.terminalAnsiLines});
  }
  for(const command of commands){
    if(command.choose){const path=join(fixtureRoot,command.choose+".jsonl");let guard=0;while(component.getSessionList().getSelectedSessionPath()!==path){assert(guard++<30,"Choice not reached");const list=component.getSessionList(),target=list.filteredSessions.findIndex(n=>n.session.path===path);assert(target>=0);await step({type:"key",data:target<list.selectedIndex?"\x1b[A":"\x1b[B",origin:{choose:path}});}}
    else await step(command);
  }
  cases.push({id,width,kind:"resume",fixture:{...spec,currentRows:spec.empty?[]:spec.blocked?[blocked,...catalog.slice(0,12)]:catalog.slice(0,12),allRows:spec.empty?[]:spec.blocked?[blocked,...catalog]:catalog,currentPath:spec.noCurrent?null:catalog[0].path},commands,initialEvents,initial,transitions});
  component.cancelLoads();component.header.setStatusMessage(null);
 }
}
const k=data=>({type:"key",data}),loadCurrent={type:"load",scope:"current",action:"resolve"},loadAll={type:"load",scope:"all",action:"resolve"};
await captureResume("resume.loading-progress",{},[{type:"load",scope:"current",action:"progress",loaded:3,total:12},k("\x1b[B"),{type:"load",scope:"current",action:"progress",loaded:8,total:12},loadCurrent,k("\r")]);
await captureResume("resume.scope-races",{},[k("\t"),{type:"load",scope:"current",action:"progress",loaded:3,total:12},loadAll,loadCurrent,k("\t"),k("\t"),k("\x1b")]);
await captureResume("resume.cancel-stale-load",{},[k("\x03"),{type:"load",scope:"current",action:"progress",loaded:4,total:12},loadCurrent]);
await captureResume("resume.loading-failure-retry",{},[{type:"load",scope:"current",action:"reject"},k("\t"),loadAll,k("\t"),loadCurrent,{type:"timers"}]);
await captureResume("resume.navigation-modes",{},[loadCurrent,k("\x1b[A"),k("\x1b[B"),k("\x1b[6~"),k("\x1b[6~"),k("\x1b[5~"),k("\x13"),k("\x13"),k("\x13"),k("\x10"),k("\x0e"),k("\x0e"),k("\x10")]);
for(const query of ["alpha","\"node cve\"","session-03","prj","alpha project","re:alpha|project","re:[","re:","\"unclosed quote","   "]){await captureResume("resume.search-"+Buffer.from(query).toString("hex"),{},[loadCurrent,k(query),k("\x13"),k("\x13"),k("\x7f"),k("\x1b")]);}
await captureResume("resume.rename-save-refresh",{},[loadCurrent,{choose:"session-03"},k("\x12"),k("\x05"),k("\x15"),k(" Renamed 漢字 "),k("\r"),{type:"rename",action:"resolve"},loadCurrent,k("\x12"),k("\x1b")]);
await captureResume("resume.rename-empty-denied-cancel",{},[loadCurrent,k("\x12"),k("\x05"),k("\x15"),k("   "),k("\r"),k("\x15"),k("name"),k("\r"),{type:"rename",action:"reject"},k("\x12"),k("\x03")]);
await captureResume("resume.rename-disabled",{rename:false},[loadCurrent,k("\x12"),k("\x1b")]);
await captureResume("resume.rename-loading-ignored",{},[{type:"load",scope:"current",action:"progress",loaded:3,total:12},k("\x12"),loadCurrent]);
await captureResume("resume.delete-current-guard",{},[loadCurrent,{choose:"session-00"},k("\x04"),{type:"timers"}]);
await captureResume("resume.delete-cancel-intercepts",{},[loadCurrent,{choose:"session-02"},k("\x04"),k("\t"),k("ignored"),k("\x1b[B"),k("\x1b"),k("\x04"),k("\x03")]);
await captureResume("resume.delete-unlink-refresh",{},[loadCurrent,{choose:"session-02"},k("\x04"),k("\r"),{type:"settle"},loadCurrent,{type:"timers"}]);
await captureResume("resume.delete-failure",{blocked:true},[loadCurrent,k("\x1b[B"),k("\x04"),k("\r"),{type:"settle"},{type:"timers"}]);
await captureResume("resume.empty-all-named",{empty:true},[loadCurrent,k("\x1b[B"),k("\x0e"),k("\t"),loadAll,k("\x0e"),k("\r"),k("\x1b")]);
await captureResume("resume.mouse-boundaries",{},[loadCurrent,{type:"mouse",action:"press",target:"list"},{type:"mouse",action:"wheel",target:"list",y:2},k("\x12"),{type:"mouse",action:"press",target:"rename",x:4},k("\x1b")]);
await captureResume("resume.scope-all-path",{},[loadCurrent,k("\t"),loadAll,k("\x10"),k("\x1b[6~"),k("\x0e"),k("\x1b")]);

for(const [id,source,selected] of [["empty",[],undefined],["single",messages.slice(0,1),undefined],["recent",messages,undefined],["initial",messages,"user-3"],["missing",messages,"absent"]]){
 for(const width of [100,60,30]){
  timers.clear();const state={selectRequests:[],cancelCount:0},events=[];
  const component=new UserMessageSelectorComponent(structuredClone(source),entryId=>{state.selectRequests.push(entryId);events.push({action:"select",entryId});},()=>{state.cancelCount++;events.push({action:"cancel"});},selected);
  const snapshot=()=>{const ansiLines=component.render(width),terminalAnsiLines=renderer.applyLineResets(renderer.resolveFakeCursors(ansiLines)),list=component.getMessageList();return{selectedIndex:list.selectedIndex,selectedId:list.messages[list.selectedIndex]?.id??null,maxVisible:list.maxVisible,callbackState:structuredClone(state),timerDelays:[...timers.values()].map(t=>t.delay),ansiLines,terminalAnsiLines,lineDisplayWidths:terminalAnsiLines.map(visibleWidth)};};
  const initial=snapshot(),transitions=[],name="fork."+id;
  snapshots.push({id:name+".initial",width,terminalAnsiLines:initial.terminalAnsiLines});
  for(const event of [k("\x1b[A"),k("\x1b[B"),k("\x1b[5~"),k("\x1b[6~"),k("text ignored"),k("\r"),{type:"mouse",action:"press"},k("\x1b"),{type:"timers"}]){
   let result=null;
   if(event.type==="key")component.getMessageList().handleInput(event.data);
   else if(event.type==="timers"){const queued=[...timers.values()];timers.clear();for(const timer of queued)timer.callback();}
   else result=component.handleMouse({type:"press",button:"left",x:3,y:8,screenX:3,screenY:8,width,height:component.render(width).length,shift:false,alt:false,ctrl:false})??null;
   const after=snapshot(),index=transitions.length;transitions.push({index,event,result,callbackEvents:events.splice(0),after});snapshots.push({id:`${name}.step-${index}`,width,terminalAnsiLines:after.terminalAnsiLines});
  }
  cases.push({id:name,width,kind:"fork",fixture:{messages:source,initialSelected:selected??null},initial,transitions});
 }
}
const searchCases=[];
for(const query of ["alpha","project","prj","3session","session3","\"node cve\"","alpha project","re:alpha|project","re:[","re:","\"unclosed quote",""," "]){
 const parsed=search.parseSearchQuery(query);
 searchCases.push({query,parsed:{mode:parsed.mode,tokens:parsed.tokens,regex:parsed.regex?{source:parsed.regex.source,flags:parsed.regex.flags}:null,error:parsed.error??null},matches:catalog.map(session=>({id:session.id,...search.matchSession(session,parsed)})),orders:Object.fromEntries(["threaded","recent","relevance"].flatMap(sort=>["all","named"].map(filter=>[sort+"/"+filter,search.filterAndSortSessions(catalog,query,sort,filter).map(s=>s.id)])))});
}
const result={schemaVersion:1,reference:prior.reference,provenance:{checkedSourceFiles:513,provenanceSha256:sha(provenanceBytes),runnerSha256:sha(readFileSync(new URL(import.meta.url))),imports:imports.map(path=>({path,sha256:sha(readFileSync(join(root,path)))}))},
 environment:{fixedTime,fixtureRoot,home:fixtureRoot,timeZone:"UTC",theme:"dark",forceColor:process.env.FORCE_COLOR??null},
 method:"Unmodified original components and search functions. Original rename/delete method wrappers only observe returned promises. Delete Enter is captured synchronously before filesystem completion; explicit settle waits until the original refresh request or failure completion. Original deletion performs actual unlink on disposable fixture files; PATH excludes any installed trash utility. Fixture rename callbacks alter only fixture memory, not persisted sessions. Timers are explicit fixture queue events, not timing measurements.",
 limits:["No full CLI/auth/provider calls or native imports.","Default Linux bindings; actual terminal host unverified.","Original regex semantics are JavaScript RegExp; candidate regex implementation must declare unsupported constructs rather than silently match all.","Rename owner rejection is observed and original finally closes overlay; no persistence success is claimed.","Main-list mouse ignored by original; rename input mouse routed by original Container."],
 catalog,messages,searchCases,cases,snapshots,summary:{cases:cases.length,transitions:cases.reduce((sum,c)=>sum+c.transitions.length,0),frames:snapshots.length,widths:[100,60,30]}};
writeFileSync(output,JSON.stringify(result,null,2)+"\n",{flag:"wx"});
th.stopThemeWatcher();rmSync(fixtureRoot,{recursive:true,force:true});
console.log(JSON.stringify({output,sha256:sha(readFileSync(output)),...result.summary}));
