// Test-only, unmodified exact-revision Pi components. Synthetic options are not provider support claims.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL,fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const [rootArg,provenanceArg,outputArg]=process.argv.slice(2),root=resolve(rootArg);
const pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403',sha=data=>createHash('sha256').update(data).digest('hex');
const prior=JSON.parse(readFileSync(provenanceArg));assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),pin);
assert.equal(prior.reference.commit,pin);for(const [path,hash]of Object.entries(prior.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,path))),hash,path);
const temporary=mkdtempSync(join(tmpdir(),'pi-auth-selector-'));process.env.PI_CODING_AGENT_DIR=temporary;process.env.PI_OFFLINE='1';process.env.COLORTERM='truecolor';process.env.FORCE_COLOR='1';delete process.env.NO_COLOR;
globalThis.fetch=()=>{throw Error('Network forbidden in auth selector oracle');};
const load=path=>import(pathToFileURL(join(root,path)).href);await load('packages/coding-agent/src/experimental/source-resolver.ts');
const tui=await load('packages/tui/src/index.ts');const th=await load('packages/coding-agent/src/modes/interactive/theme/theme.ts');
const {LoginDialogComponent}=await load('packages/coding-agent/src/modes/interactive/components/login-dialog.ts');
const {KeybindingsManager}=await load('packages/coding-agent/src/core/keybindings.ts');
tui.setKeybindings(new KeybindingsManager());tui.setCapabilityOverrides({images:false,trueColor:true,hyperlinks:false});
const renderer=Object.create(tui.TuiMainScreen.prototype);renderer.showHardwareCursor=false;
const normalize=rows=>{const out=renderer.resolveFakeCursors(rows);renderer.extractCursorPosition(out,out.length);return out;};


// The original browser launcher sees an empty fixture PATH; no program or external page is launched.
const oldPath=process.env.PATH;process.env.PATH=temporary;
const {envApiKeyAuth}=await load('packages/ai/src/auth/helpers.ts');
const cases=[],widths=[100,60,30,10],themes=['dark','light'];
const stages=[{op:'prompt'},{op:'input',data:'SYNTHETIC_KEY'},{op:'input',data:'\x1b[D'},{op:'input',data:'\x7f'},{op:'input',data:'\r'}];
for(const theme of themes)for(const width of widths){
 th.initTheme(theme);const callbacks=[];const component=new LoginDialogComponent({requestRender(){}},'fixture',(ok,message)=>callbacks.push({kind:'complete',ok,message}),'Fixture provider');component.focused=true;
 const snapshot=()=>{
  const terminalAnsiLines=renderer.resolveFakeCursors(component.render(width));
  const cursor=renderer.extractCursorPosition(terminalAnsiLines,terminalAnsiLines.length);
  const originalValue=component.input.getValue(),originalCursor=component.input.cursor;
  const submitted=component.contentContainer.children.find(child=>typeof child.text==='string'&&child.text.startsWith('> ')&&child!==component.input);
  const originalSubmitted=submitted?.text;
  if(submitted)submitted.setText('> API key received; validating…');
  else component.input.setValue('•'.repeat(originalValue.length));
  component.input.cursor=originalCursor;
  const privacyProjectedAnsiLines=normalize(component.render(width));
  if(submitted)submitted.setText(originalSubmitted);else component.input.setValue(originalValue);
  component.input.cursor=originalCursor;
  return{terminalAnsiLines,cursor,privacyProjectedAnsiLines,privacyProjection:{pendingInputMasked:!submitted&&originalValue.length>0,submittedInputReplaced:!!submitted},state:{callbacks:structuredClone(callbacks),aborted:component.signal.aborted,input:originalValue}};
 };
 const initial=snapshot(),transitions=[];for(const stage of stages){
  if(stage.op==='prompt')envApiKeyAuth('Fixture API key',['FIXTURE_KEY']).login({signal:component.signal,prompt:options=>component.showPrompt(options.message)}).then(value=>callbacks.push({kind:'intake',value}),error=>callbacks.push({kind:'rejected',reason:error.message}));
  else component.handleInput(stage.data);
  await Promise.resolve();await Promise.resolve();transitions.push({...stage,after:snapshot()});
 }
 cases.push({id:'auth.api-key',theme,width,initial,transitions});
}
process.env.PATH=oldPath;
const snapshots=cases.flatMap(c=>[{after:c.initial},...c.transitions].flatMap((stage,i)=>[{id:c.theme+'.'+c.id+'.'+(i+1),width:c.width,terminalAnsiLines:stage.after.terminalAnsiLines},{id:c.theme+'.'+c.id+'.'+(i+1)+'.private',width:c.width,terminalAnsiLines:stage.after.privacyProjectedAnsiLines}]));
writeFileSync(outputArg,JSON.stringify({reference:prior.reference,capabilities:{trueColor:true,bold:true,hyperlinks:false,images:false},snapshots,pin,sourceHashes:prior.reference.sourceHashes,runnerSha256:sha(readFileSync(fileURLToPath(import.meta.url))),cases,frames:cases.reduce((n,c)=>n+1+c.transitions.length,0),method:'Original Pi envApiKeyAuth and full LoginDialogComponent. Synthetic key only. No network, clipboard, code exchange or real credentials. Masked native key value and receipt-only status before provider validation are explicit security exceptions. Raw reference renders are preserved. The additional privacy projection renders original components with only pending input replaced by same-length bullets or submitted input replaced by the fixed receipt-only text; all geometry and styles still come from original components.'}));
th.stopThemeWatcher();rmSync(temporary,{recursive:true,force:true});console.log(JSON.stringify({cases:cases.length,frames:cases.reduce((n,c)=>n+1+c.transitions.length,0)}));
