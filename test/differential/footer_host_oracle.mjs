// Original pinned FooterComponent; fixture session/data providers only.
// Usage: node pi-footer-oracle.mjs PI_ROOT PROVENANCE_JSON NEW_OUTPUT_JSON
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';
const [r,p,o,f]=process.argv.slice(2);assert(r&&p&&o&&f);
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

const {AgentSession}=await load('packages/coding-agent/src/core/agent-session.ts');
const {buildSessionProjection,SessionManager}=await load('packages/coding-agent/src/core/session-manager.ts');
const fixtureBytes=readFileSync(resolve(f)),fixtures=JSON.parse(fixtureBytes),snapshots=[];
for(const fixture of fixtures.cases)for(const theme of fixtures.themes)for(const width of fixtures.widths){
 th.setTheme(theme);const entries=structuredClone(fixture.entries),leaf=fixture.selectedLeaf??fixture.leaf;
 const current=fixture.noModel?undefined:fixture.replacementModel??fixture.model;
 const sessionManager={getCwd:()=>fixture.cwd,getSessionName:()=>entries.filter(e=>e.type==='session_info').at(-1)?.name,
  getEntryCount:()=>entries.length,getSessionId:()=>fixture.id,getLeafId:()=>leaf,getEntries:()=>entries,
  leafId:leaf,byId:new Map(entries.map(e=>[e.id,e])),getBranch(){return SessionManager.prototype.getBranch.call(this);},buildSessionProjection:()=>buildSessionProjection(entries,leaf)};
 const session={sessionManager,_limitsModel:()=>current,state:{model:current,thinkingLevel:fixture.thinking},model:current,
  getContextUsage(){return AgentSession.prototype.getContextUsage.call(this);},
  modelRuntime:{isUsingSubscription:p=>(fixture.verifiedSubscriptions??[]).includes(p)}};
 const data={getGitBranch:()=>fixture.branch,getAvailableProviderCount:()=>fixture.noModel?0:new Set(fixture.availableModels.map(m=>m.provider)).size,
  getExtensionStatuses:()=>new Map(fixture.extraStatuses??fixture.statuses)};
 process.env.HOME=fixture.home;const component=new FooterComponent(session,data);component.setAutoCompactEnabled(fixture.auto);
 const ansiLines=component.render(width),terminalAnsiLines=renderer.resolveFakeCursors(ansiLines);
 snapshots.push({id:`${fixture.id}.${theme}`,width,context:session.getContextUsage()??null,terminalAnsiLines});component.dispose();
}
const result={reference:prior.reference,provenance:{checkedSourceFiles:513,provenanceSha256:sha(bytes),fixtureSha256:sha(fixtureBytes),runnerSha256:sha(readFileSync(new URL(import.meta.url))),imports:imports.map(path=>({path,sha256:sha(readFileSync(join(root,path)))}))},snapshots};
writeFileSync(output,JSON.stringify(result,null,2)+'\n',{flag:'wx'});th.stopThemeWatcher();console.log(JSON.stringify({output,frames:snapshots.length,sha256:sha(readFileSync(output))}));
