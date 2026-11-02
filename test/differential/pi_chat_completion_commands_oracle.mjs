// Source-pinned real extension callback → editor selection → submitted command boundary.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL,fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const [rootArg,manifestArg,out]=process.argv.slice(2),root=resolve(rootArg);
const sha=x=>createHash('sha256').update(x).digest('hex'),manifest=JSON.parse(readFileSync(manifestArg));
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),manifest.reference.commit);
for(const [path,hash] of Object.entries(manifest.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,path))),hash,path);
const directory=mkdtempSync(join(tmpdir(),'pi-extension-completion-'));
process.env.PI_CODING_AGENT_DIR=directory;process.env.PI_OFFLINE='1';process.env.COLORTERM='truecolor';
globalThis.fetch=()=>{throw Error('Network forbidden')};
const load=p=>import(pathToFileURL(join(root,p)).href);
await load('packages/coding-agent/src/experimental/source-resolver.ts');
const tui=await load('packages/tui/src/index.ts'),theme=await load('packages/coding-agent/src/modes/interactive/theme/theme.ts');
const {CustomEditor}=await load('packages/coding-agent/src/modes/interactive/components/custom-editor.ts');
const {CombinedAutocompleteProvider}=await load('packages/tui/src/autocomplete.ts');
const {KeybindingsManager}=await load('packages/coding-agent/src/core/keybindings.ts');
const keys=new KeybindingsManager();tui.setKeybindings(keys);tui.setCapabilityOverrides({images:false,trueColor:true});theme.initTheme('dark');
const renderer=Object.create(tui.TuiMainScreen.prototype);renderer.showHardwareCursor=false;
const scenarios=[
 ['accept-then-submit','/test ',['u','\t','\r'],false],
 ['no-match','/test ',['z','\x1b'],false],
 ['async-accept','/test ',['s','\r','\r'],true],
 ['cancel-list','/test ',['u','\x1b'],false],
];
const cases=[],snapshots=[];
for(const [id,initial,inputs,asynchronous]of scenarios)for(const width of [30,60]){
 const calls=[],executions=[];
 const callback=prefix=>{calls.push(prefix);const items=['all','unit','smoke'].filter(value=>value.startsWith(prefix)).map(value=>({value,label:value,description:'actual argument '+value}));return asynchronous?Promise.resolve(items):items;};
 const provider=new CombinedAutocompleteProvider([{name:'test',description:'Registered real action',getArgumentCompletions:callback}],directory,null);
 const editor=new CustomEditor({terminal:{rows:32},requestRender(){}},theme.getEditorTheme(),keys);editor.focused=true;editor.setText(initial);editor.setAutocompleteProvider(provider);
 editor.onSubmit=text=>{assert(text.startsWith('/test '));executions.push(text.slice(6));};
 const steps=[];
 const capture=index=>{const lines=renderer.resolveFakeCursors(editor.render(width));renderer.extractCursorPosition(lines,lines.length);const frame={id:`extension.${id}.${index}`,width,terminalAnsiLines:renderer.applyLineResets(lines)};snapshots.push(frame);steps.push({index,frameId:frame.id,state:{text:editor.getText(),mode:editor.autocompleteState,prefix:editor.autocompletePrefix,items:editor.autocompleteList?.filteredItems??[],calls:[...calls],executions:[...executions]}});};
 capture(-1);
 for(const [index,input]of inputs.entries()){editor.handleInput(input);await editor.autocompleteRequestTask;capture(index);}
 cases.push({id,initial,inputs,asynchronous,width,steps});
}
writeFileSync(out,JSON.stringify({reference:manifest.reference,cases,snapshots,runnerSha256:sha(readFileSync(fileURLToPath(import.meta.url)))})+'\n',{flag:'wx'});
theme.stopThemeWatcher();rmSync(directory,{recursive:true,force:true});
console.log(JSON.stringify({cases:cases.length,frames:snapshots.length,sha256:sha(readFileSync(out))}));
