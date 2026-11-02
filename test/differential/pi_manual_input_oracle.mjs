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
const temporary=mkdtempSync(join(tmpdir(),'pi-auth-selector-'));process.env.PI_CODING_AGENT_DIR=temporary;process.env.PI_OFFLINE='1';process.env.COLORTERM='truecolor';
globalThis.fetch=()=>{throw Error('Network forbidden in auth selector oracle');};
const load=path=>import(pathToFileURL(join(root,path)).href);await load('packages/coding-agent/src/experimental/source-resolver.ts');
const tui=await load('packages/tui/src/index.ts');const th=await load('packages/coding-agent/src/modes/interactive/theme/theme.ts');
const {LoginDialogComponent}=await load('packages/coding-agent/src/modes/interactive/components/login-dialog.ts');
const {KeybindingsManager}=await load('packages/coding-agent/src/core/keybindings.ts');
tui.setKeybindings(new KeybindingsManager());tui.setCapabilityOverrides({images:false,trueColor:true,hyperlinks:false});
const renderer=Object.create(tui.TuiMainScreen.prototype);renderer.showHardwareCursor=false;
const normalize=rows=>{const out=renderer.resolveFakeCursors(rows);renderer.extractCursorPosition(out,out.length);return out;};

const cases=[],widths=[80,40,15],themes=['dark','light'];
const synthetic='http://127.0.0.1:1455/auth/callback?code=SYNTHETIC_ONLY&state=SYNTHETIC_ONLY&client_id=SYNTHETIC_ONLY';
const scenarios=[
 {id:'manual.edit-submit',events:[synthetic,'\x1b[D','\x7f','Y','\r','\r']},
 {id:'manual.paste',events:['\x1b[200~'+synthetic,'\x1b[20','1~\r','\r']},
 {id:'manual.cancel',events:[synthetic,'\x1b']},
 {id:'manual.controls',events:['\x1b[200~synthetic\r\x03\x1b[201~','\r']},
];
for(const theme of themes)for(const width of widths)for(const {id,events}of scenarios){
 th.initTheme(theme);const callbacks=[];const component=new LoginDialogComponent({requestRender(){}},'chatgpt',(ok,message)=>callbacks.push({kind:'complete',ok,message}),'ChatGPT');component.focused=true;
 component.showManualInput('Complete login in your browser, or paste the final redirect URL here:').then(value=>callbacks.push({kind:'intake',value}),error=>callbacks.push({kind:'rejected',reason:error.message}));
 const snapshot=()=>({terminalAnsiLines:normalize(component.render(width)),state:{callbacks:structuredClone(callbacks),aborted:component.signal.aborted,input:component.input.getValue()}});
 const initial=snapshot(),transitions=[];for(const data of events){component.handleInput(data);await Promise.resolve();transitions.push({data,after:snapshot()});}
 cases.push({id,theme,width,initial,transitions});
}
writeFileSync(outputArg,JSON.stringify({pin,sourceHashes:prior.reference.sourceHashes,runnerSha256:sha(readFileSync(fileURLToPath(import.meta.url))),cases,frames:cases.reduce((n,c)=>n+1+c.transitions.length,0),method:'Original Pi LoginDialogComponent, synthetic manual callbacks only; no auth URL, launch, clipboard, network, code exchange or credentials. Original unmasked rendering is evidence, not a requirement to expose secrets in native UI.'}));
th.stopThemeWatcher();rmSync(temporary,{recursive:true,force:true});console.log(JSON.stringify({cases:cases.length,frames:cases.reduce((n,c)=>n+1+c.transitions.length,0)}));
