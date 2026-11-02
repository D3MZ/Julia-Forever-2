// Original pinned FooterComponent; fixture session/data providers only.
// Usage: node pi-footer-oracle.mjs PI_ROOT PROVENANCE_JSON NEW_OUTPUT_JSON
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';
const [r,p,o]=process.argv.slice(2);assert(r&&p&&o);
const root=resolve(r),output=resolve(o),sha=x=>createHash('sha256').update(x).digest('hex');
const bytes=readFileSync(resolve(p)),prior=JSON.parse(bytes),pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403';
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),pin);
assert.equal(prior.reference.commit,pin);assert.equal(Object.keys(prior.reference.sourceHashes).length,513);
for(const [path,hash]of Object.entries(prior.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,path))),hash,path);
const agent=mkdtempSync(join(tmpdir(),'pi-footer-only-'));process.env.PI_CODING_AGENT_DIR=agent;process.env.PI_OFFLINE='1';process.env.PI_EXPERIMENTAL='0';process.env.COLORTERM='truecolor';
process.on('exit',()=>rmSync(agent,{recursive:true,force:true}));globalThis.fetch=()=>{throw new Error('Network forbidden in footer oracle');};
const imports=[];const load=path=>{imports.push(path);return import(pathToFileURL(join(root,path)).href);};
await load('packages/coding-agent/src/experimental/source-resolver.ts');
const tui=await load('packages/tui/src/index.ts');
const {visibleWidth}=await load('packages/tui/src/utils.ts');
const {FooterComponent,formatTokens,formatCwdForFooter}=await load('packages/coding-agent/src/modes/interactive/components/footer.ts');
const totals=await load('packages/coding-agent/src/core/usage-totals.ts');
const th=await load('packages/coding-agent/src/modes/interactive/theme/theme.ts');
tui.setCapabilityOverrides({images:false,trueColor:true,hyperlinks:false});th.initTheme('dark');
const renderer=Object.create(tui.TuiMainScreen.prototype);renderer.showHardwareCursor=false;
const usage=(input=0,output=0,cacheRead=0,cacheWrite=0,cost=0)=>({input,output,cacheRead,cacheWrite,totalTokens:input+output+cacheRead+cacheWrite,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:cost}});
const model={id:'fixture-reasoner',provider:'fixture-provider',reasoning:true,contextWindow:200000};
const entries=[{type:'usage',usage:usage(1000,2000,3000,4000,.12345)},
 {type:'message',message:{role:'assistant',usage:usage(500,25,1000,500,.02)}},
 {type:'message',message:{role:'toolResult',usage:usage(30,40,50,60,.002)}},
 {type:'branch_summary',usage:usage(70,80,90,100,.003)},
 {type:'compaction',usage:usage(110,120,130,140,.004)},
 {type:'message',message:{role:'user',usage:usage(999999,999999,999999,999999,9999)}},
 {type:'custom',usage:usage(999999,999999,999999,999999,9999)},
 {type:'message',message:{role:'toolResult'}},{type:'compaction'}];
const specs=[
 ['no-model',{}],['model-context-absent',{model}],['context-empty',{model,context:{}}],
 ['context-null-percent',{model,context:{percent:null,contextWindow:128000}}],
 ['context-null-window',{model,context:{percent:25,contextWindow:null}}],
 ['context-no-model',{context:{percent:12.25,contextWindow:32000}}],
 ['totals-all-entry-types',{model,entries,context:{percent:6.25,contextWindow:200000}}],
 ['cache-write-only',{model,entries:[{type:'message',message:{role:'assistant',usage:usage(1,0,0,15)}}]}],
 ['cache-prior-zero-prompt',{model,entries:[...entries,{type:'message',message:{role:'assistant',usage:usage()}}]}],
 ['cache-no-assistant',{model,entries:[{type:'usage',usage:usage(0,0,2000,1000)}]}],
 ['subscription-zero',{model,subscriptions:['fixture-provider']}],
 ['kimi-key-subscription',{model:{...model,provider:'kimi-coding',reasoning:false}}],
 ['nonreasoning-thinking-ignored',{model:{...model,reasoning:false},thinking:'high'}],
 ['thinking-off',{model,thinking:'off'}],['thinking-high',{model,thinking:'high'}],
 ['empty-model-id',{model:{...model,id:''},thinking:''}],
 ['routed',{model:{...model,id:'router',reasoning:false},routed:{model:{...model,id:'actual-target'},thinkingLevel:'high'},available:3}],
 ['routed-no-level',{model,routed:{model:{...model,id:'actual-target'}},available:2}],
 ['multiple-provider',{model,available:2}],['single-provider',{model,available:1}],
 ['cwd-exact-home',{cwd:'/fixture/home',branch:'main',name:'Session name 漢字'}],
 ['cwd-outside-prefix',{cwd:'/fixture/homework/project',home:'/fixture/home'}],
 ['cwd-normalized-descendant',{cwd:'/fixture/home/projects/../work/./nested',branch:'feature/long-branch',name:'Long session name with lots of words'}],
 ['cwd-no-home',{cwd:'/fixture/home/work',home:''}],
 ['extension-statuses',{model,statuses:[['z-last',{text:'  Last\nline\t status  '}],['a-first',{text:'first'}],['m-middle',{text:'ok',color:'success'}]]}],
 ['extension-empty',{statuses:[['blank',{text:' \n\t '}]]}],
 ['extension-unicode-sort',{statuses:[['Z',{text:'Z'}],['a',{text:'a'}],['A',{text:'A'}],['á',{text:'accent'}],['aa',{text:'aa'}],['a-b',{text:'dash'}],['a_b',{text:'under'}]]}],
 ['extension-long-colored',{statuses:[['color',{text:'A very long success message with 漢字 👩‍💻 and more words',color:'success'}]]}],
 ['experimental',{model,experimental:true}],
];
for(const percent of [0,70,70.0001,90,90.0001,100,6.25,2.55])specs.push(['context-'+percent,{model,context:{percent,contextWindow:1000000}}]);
const scenarios=[
 ['append-and-live-state',{model,entries:[],context:{percent:0,contextWindow:200000}},[
  {type:'append',entry:entries[1],context:{percent:10,contextWindow:200000}},
  {type:'thinking',value:'high'},{type:'auto',value:false},{type:'branch',value:'feature/test'},
  {type:'name',value:'Renamed session'},{type:'providers',value:3},{type:'statuses',value:[['notice',{text:'background work',color:'warning'}]]},
  {type:'append',entry:{type:'compaction',usage:usage(100,20,30,40,.001)},context:{percent:null,contextWindow:200000}},
  {type:'append',entry:{type:'message',message:{role:'assistant',usage:usage(60,10,40,0,.002)}},context:{percent:80,contextWindow:200000}},
  {type:'routed',value:{model:{...model,id:'new-target',contextWindow:32000},thinkingLevel:'medium'},context:{percent:95,contextWindow:32000}},
  {type:'replace',value:{model:{id:'replacement',provider:'other',reasoning:false,contextWindow:64000},entries:[entries[0]],context:{percent:50,contextWindow:64000},subscriptions:['other']}},
 ]],
 ['model-replacement',{model,context:{percent:20,contextWindow:200000}},[
  {type:'model',value:{...model,id:'new-model',contextWindow:50000},context:{percent:75,contextWindow:50000}},
  {type:'model',value:null},{type:'auto',value:false},{type:'auto',value:true},
 ]],
];
const cases=[],snapshots=[];
function makeSession(spec,counters){
 const state=structuredClone(spec);
 state.entries??=[];state.home??='/fixture/home';state.cwd??='/fixture/home/work';state.thinking??='off';state.available??=1;state.statuses??=[];state.subscriptions??=[];state.id??='fixture-session';state.leaf??='leaf-0';
 const session={state:{get model(){return state.model;},get thinkingLevel(){return state.thinking;}},get model(){return state.model;},get routedModel(){return state.routed;},
 sessionManager:{getCwd:()=>state.cwd,getSessionName:()=>state.name,getEntryCount:()=>state.entries.length,getSessionId:()=>state.id,getLeafId:()=>state.leaf,
 getEntries:()=>{counters.entriesReads++;return state.entries;}},
 getContextUsage:()=>{counters.contextReads++;return state.context;},
 modelRuntime:{isUsingSubscription:provider=>{counters.subscriptionChecks.push(provider);return state.subscriptions.includes(provider);}}};
 return {state,session};
}
function statuses(state){return new Map(state.statuses.map(([key,value])=>[key,value.color?th.theme.fg(value.color,value.text):value.text]));}
for(const [id,fixture,events]of [...specs.map(([id,spec])=>[id,spec,[]]),...scenarios]){
 for(const width of [100,60,30,10,5,2]){
  const counters={entriesReads:0,contextReads:0,subscriptionChecks:[]};let current=makeSession(fixture,counters);
  const data={getGitBranch:()=>current.state.branch,getAvailableProviderCount:()=>current.state.available,getExtensionStatuses:()=>statuses(current.state)};
  const component=new FooterComponent(current.session,data);component.setAutoCompactEnabled(fixture.auto??true);
  const snapshot=()=>{process.env.HOME=current.state.home;delete process.env.USERPROFILE;process.env.PI_EXPERIMENTAL=current.state.experimental?'1':'0';
   const ansiLines=component.render(width),terminalAnsiLines=renderer.resolveFakeCursors(ansiLines),stats=component.sessionStats;
   return {usageTotals:structuredClone(stats.usageTotals),latestCacheHitRate:stats.latestCacheHitRate??null,
    contextPresent:stats.contextUsage!==undefined,context:stats.contextUsage??null,autoCompact:component.autoCompactEnabled,
    sessionId:stats.sessionId,leafId:stats.leafId,entryCount:stats.entryCount,counters:structuredClone(counters),ansiLines,terminalAnsiLines,lineDisplayWidths:terminalAnsiLines.map(visibleWidth)};};
  const initial=snapshot(),transitions=[];snapshots.push({id:`${id}.initial`,width,terminalAnsiLines:initial.terminalAnsiLines});
  for(const event of events){
   const state=current.state;
   if(event.type==='append'){state.entries.push(structuredClone(event.entry));state.leaf=`leaf-${state.entries.length}`;if('context'in event)state.context=structuredClone(event.context);}
   else if(event.type==='auto')component.setAutoCompactEnabled(event.value);
   else if(event.type==='replace'){current=makeSession(event.value,counters);component.setSession(current.session);}
   else if(event.type==='providers')state.available=event.value;
   else if(event.type==='statuses')state.statuses=structuredClone(event.value);
   else {state[event.type==='thinking'?'thinking':event.type]=structuredClone(event.value);if('context'in event)state.context=structuredClone(event.context);}
   const after=snapshot(),index=transitions.length;transitions.push({index,event,after});snapshots.push({id:`${id}.step-${index}`,width,terminalAnsiLines:after.terminalAnsiLines});
  }
  cases.push({id,width,fixture,initial,transitions});component.dispose();
 }
}
const tokenCases=[0,1,12.5,999,999.9,1000,1005,1050,1250,2550,6250,9950,9999,10000,10499,10500,999499,999500,999999,1000000,1050000,1250000,9950000,9999999,10000000,10499999,10500000,1000000000].map(count=>({count,text:formatTokens(count)}));
const cwdCases=[['/home/u','/home/u'],['/home/u/sub','/home/u'],['/home/user','/home/u'],['/home/u/../other','/home/u'],['/home/u/a/../b','/home/u'],['/','/'],['/x','/'],['relative/path','/unrelated'],['/home/u','']].map(([cwd,home])=>({cwd,home,text:formatCwdForFooter(cwd,home)}));
const usageTotals=totals.createUsageTotals();for(const item of [usage(1,2,3,4,.1),usage(10,20,30,40,.2)])totals.addUsageToTotals(usageTotals,item);
const result={schemaVersion:1,reference:prior.reference,provenance:{checkedSourceFiles:513,provenanceSha256:sha(bytes),runnerSha256:sha(readFileSync(new URL(import.meta.url))),imports:imports.map(path=>({path,sha256:sha(readFileSync(join(root,path)))}))},
 environment:{theme:'dark',forceColor:process.env.FORCE_COLOR??null,defaultHome:'/fixture/home',cwd:process.cwd()},
 method:'Unmodified original FooterComponent, formatTokens, formatCwdForFooter, and usage totals. Fixture-only session/data/runtime methods report factual supplied values; subscription checks are recorded, not authenticated. Real original ANSI, not intended UI reconstruction.',
 limits:['No full CLI/provider/auth/network calls or timing benchmarks.','Default dark palette, declared color profile.','Append-only usage lifecycle; externally mutating old entries without leaf/count/model change violates original cache assumption and is not fixture success.','Status sanitizer intentionally follows original CR/LF/TAB+ASCII-space behavior, not comment claim of all control removal.'],
 tokenCases,cwdCases,usageTotals,cases,snapshots,summary:{cases:cases.length,transitions:cases.reduce((n,c)=>n+c.transitions.length,0),frames:snapshots.length,widths:[100,60,30,10,5,2]}};
writeFileSync(output,JSON.stringify(result,null,2)+'\n',{flag:'wx'});th.stopThemeWatcher();rmSync(agent,{recursive:true,force:true});
console.log(JSON.stringify({output,sha256:sha(readFileSync(output)),...result.summary}));
