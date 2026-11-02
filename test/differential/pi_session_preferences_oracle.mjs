// Test-only actual pinned AgentSession queue restoration and InteractiveMode runtime setting rebinding.
import assert from'node:assert/strict';import{readFileSync,writeFileSync}from'node:fs';import{resolve,join}from'node:path';import{pathToFileURL}from'node:url';import{execFileSync}from'node:child_process';import{createHash}from'node:crypto';
const[rootArg,pinArg,out]=process.argv.slice(2),root=resolve(rootArg),prior=JSON.parse(readFileSync(pinArg)),sha=x=>createHash('sha256').update(x).digest('hex');
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),prior.reference.commit);for(const[p,h]of Object.entries(prior.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,p))),h,p);
globalThis.fetch=()=>{throw Error('No provider/network in session preference oracle');};await import(pathToFileURL(join(root,'packages/coding-agent/src/experimental/source-resolver.ts')));
const{AgentSession}=await import(pathToFileURL(join(root,'packages/coding-agent/src/core/agent-session.ts')));const{InteractiveMode}=await import(pathToFileURL(join(root,'packages/coding-agent/src/modes/interactive/interactive-mode.ts')));
const cases=[];
for(const[steering,follow,hidden]of[['all','all',true],['one-at-a-time','all',true],['all','one-at-a-time',false],['one-at-a-time','one-at-a-time',false]]){
 const values={getSteeringMode:steering,getFollowUpMode:follow,getHideThinkingBlock:hidden,getTerminalCapabilityOverrides:{},getHttpIdleTimeoutMs:300000,getOutputPad:1,getShowHardwareCursor:false,getClearOnShrink:false,getEditorPaddingX:0,getAutocompleteMaxVisible:5};
 const settings=new Proxy({}, {get:(_t,k)=>()=>values[k]});const session=Object.create(AgentSession.prototype);session.agent={steeringMode:'one-at-a-time',followUpMode:'one-at-a-time'};session.settingsManager=settings;session.syncQueueModesFromSettings();
 const ui=Object.create(InteractiveMode.prototype);Object.defineProperties(ui,{session:{value:session},settingsManager:{value:settings},sessionManager:{value:{getCwd:()=>'/fixture'}}});Object.assign(ui,{renderer:{},footer:{setSession(){},setAutoCompactEnabled(){}},footerDataProvider:{setCwd(){}},statusContainer:{clear(){}},ui:{setShowHardwareCursor(){},setClearOnShrink(){}},defaultEditor:{setPaddingX(){},setAutocompleteMaxVisible(){}},ensurePngTranscoder(){},applyFullscreenScrollbarSetting(){}});ui.editor=ui.defaultEditor;ui.applyRuntimeSettings();
 cases.push({steering:session.steeringMode,followUp:session.followUpMode,hideThinking:ui.hideThinkingBlock});
}
writeFileSync(out,JSON.stringify({reference:prior.reference,runnerSha256:sha(readFileSync(new URL(import.meta.url))),scope:'Original queue sync method and original UI runtime-rebind method, fixture-only settings/agent/UI capabilities. No claim of complete original session storage transition.',cases})+'\n',{flag:'wx'});
console.log(JSON.stringify({cases:cases.length}));
