// Test-only original editor. Fixture callbacks only; no CLI/provider/filesystem completion calls.
import assert from 'node:assert/strict';import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';import {join,resolve} from 'node:path';import {tmpdir} from 'node:os';import {pathToFileURL,fileURLToPath} from 'node:url';import {createHash} from 'node:crypto';import {execFileSync} from 'node:child_process';
const [rootArg,provenanceArg,outArg]=process.argv.slice(2),root=resolve(rootArg),sha=x=>createHash('sha256').update(x).digest('hex'),prior=JSON.parse(readFileSync(provenanceArg));
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),prior.reference.commit);for(const [file,hash]of Object.entries(prior.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,file))),hash,file);
const temp=mkdtempSync(join(tmpdir(),'pi-editor-priority-'));process.env.PI_CODING_AGENT_DIR=temp;process.env.PI_OFFLINE='1';process.env.COLORTERM='truecolor';globalThis.fetch=()=>{throw Error('Network forbidden');};
const load=path=>import(pathToFileURL(join(root,path)).href);await load('packages/coding-agent/src/experimental/source-resolver.ts');
const tui=await load('packages/tui/src/index.ts'),th=await load('packages/coding-agent/src/modes/interactive/theme/theme.ts');const {CustomEditor}=await load('packages/coding-agent/src/modes/interactive/components/custom-editor.ts');const {KeybindingsManager}=await load('packages/coding-agent/src/core/keybindings.ts');
const keys=new KeybindingsManager();tui.setKeybindings(keys);tui.setCapabilityOverrides({images:false,trueColor:true});th.initTheme('dark');
const renderer=Object.create(tui.TuiMainScreen.prototype);renderer.showHardwareCursor=false;
const big=n=>Array.from({length:n},(_,i)=>'line '+i).join('\n');
const specs=[
 ['hardware-cursor','hello',[{hardware:true},'\x1b[D',{focused:false},{hardware:false},{focused:true}]],
 ['typed-undo','',['h','e','l','l','o',' ','w','o','r','l','d',' ','!','\x1f','\x1f','\x1f','\x1f']],
 ['kill-merge','alpha beta gamma',['\x17','\x17','\x19','\x01','\x0b','\x19','\x1f']],
 ['kill-lines','first\nsecond\nthird',['\x01','\x15','\x15','\x19','\x01','\x0b','\x0b','\x19']],
 ['yank-rotate','alpha beta',['\x17','\x01','\x0b','\x19','\x1by','\x1by','\x1f']],
 ['word-punctuation','one_two camelCase foo.bar /path/file 12.34 foo:bar!',['\x1bb','\x1bb','\x1bb','\x17','\x19','\x01','\x1bf','\x1bf','\x1bd']],
 ['word-japanese','こんにちは世界 日本語の文章を編集する',['\x1bb','\x1bb','\x1bb','\x17','\x19','\x01','\x1bf','\x1bf']],
 ['word-thai','ภาษาไทยยินดีต้อนรับสวัสดี',['\x1bb','\x1bb','\x17','\x19','\x01','\x1bf']],
 ['jump','alpha beta\nsecond alpha\nlast beta',['\x01','\x1d','a','\x1d','b','\x1b\x1d','a','\x1d','\x1d']],
 ['sticky','123456789\nx\n123456789',['\x1b[A','\x1b[A','\x1b[B','\x1b[B','\x1b[D','\x1b[A','\x1b[A']],
 ['sticky-unicode','café 👩‍💻 text\nx\ncafé 👩‍💻 text',['\x1b[D','\x1b[D','\x1b[A','\x1b[A','\x1b[B','\x1b[B']],
 ['scroll',big(24),['\x1b[5~','\x1b[5~','\x1b[6~','\x1b[6~',{width:10},'\x1b[A',{width:60}], [30]],
 ['paste-renumber','',['\x1b[200~'+big(20)+'\x1b[201~','\x1b[200~'+big(25)+'\x1b[201~','\x01','\x1b[C','\x7f','\x1f','\x1b[3~'], [30]],
 ['paste-controls','word',['\x1b[200~/tmp/path\tfile\r\nnext\x1b[106;5uend\x01\x1b[201~','\x1f']],
 ['paste-vertical','top\n',['\x1b[200~'+big(20)+'\x1b[201~','\n','bottom','\x1b[A','\x1b[A','\x1b[A','\x1b[B','\x1b[B'], [10]],
 ['programmatic','draft',[{set:'tabs\tand\r\nlines'},'\x1f',{disabled:true},'\r',{disabled:false},'\r']],
 ['padding','123456789012345678901234567890',[{padding:1},{padding:3},'\x1b[D',{width:8},'\x01','\x1b[C']],
 ['mouse','first line\nsecond line\nthird',[{mouse:{type:'press',button:'left',x:2,y:1}},{mouse:{type:'release',button:'left',x:2,y:1}},{mouse:{type:'click',button:'left',x:2,y:1}},{mouse:{type:'click',button:'left',x:5,y:2}},{mouse:{type:'click',button:'left',x:100,y:0}},{mouse:{type:'wheel',button:'none',x:2,y:1,scroll:1}}]],
 ['kitty-keys','abc',['\x1b[97;5u','\x1b[101;5u','\x1b[98;5u','\x1b[99u','\x1b[127;2u','\x1b[13;2u','x','\x1b[57350u','\x1b[13u'], [30]],
];
const cases=[],snapshots=[];
for(const [id,initial,inputs,widths=[30,60]] of specs)for(const originalWidth of widths){
 let width=originalWidth,padding=0;renderer.showHardwareCursor=false;const events=[];
 const editor=new CustomEditor({terminal:{rows:32},requestRender(){}},th.getEditorTheme(),keys);editor.focused=true;
 editor.onSubmit=text=>events.push({kind:'submit',text});editor.onCtrlD=()=>events.push({kind:'exit'});editor.onEscape=()=>events.push({kind:'interrupt'});
 editor.addToHistory('oldest');editor.addToHistory('newest');editor.setText(initial);
 const steps=[];
 const capture=index=>{const lines=renderer.resolveFakeCursors(editor.render(width));const cursor=renderer.extractCursorPosition(lines,lines.length);const state={text:editor.getText(),expanded:editor.getExpandedText(),cursorLine:editor.state.cursorLine,cursorCol:editor.state.cursorCol,scrollOffset:editor.scrollOffset,historyIndex:editor.historyIndex,pastes:Array.from(editor.pastes),events:structuredClone(events),cursor};const frame={id:`editor-extended.${id}.base${originalWidth}.${index}`,width,terminalAnsiLines:renderer.applyLineResets(lines)};snapshots.push(frame);steps.push({index,state,frameId:frame.id,frameWidth:width,padding});};
 capture(-1);for(const [index,action]of inputs.entries()){
 if(typeof action==='string')editor.handleInput(action);
 else if(action.width)width=action.width;
 else if('padding'in action){padding=action.padding;editor.setPaddingX(padding);}
 else if('set'in action)editor.setText(action.set);
 else if('disabled'in action)editor.disableSubmit=action.disabled;
 else if('hardware'in action)renderer.showHardwareCursor=action.hardware;
 else if('focused'in action)editor.focused=action.focused;
 else if(action.mouse)editor.handleMouse({...action.mouse,width,height:editor.render(width).length});
 await editor.autocompleteRequestTask;capture(index);
 }cases.push({id,width:originalWidth,initial,inputs,steps});
}
writeFileSync(outArg,JSON.stringify({reference:prior.reference,method:'Exact original CustomEditor action families, actual rendering and source handlers. No network or live provider calls.',runnerSha256:sha(readFileSync(fileURLToPath(import.meta.url))),cases,snapshots})+'\n',{flag:'wx'});th.stopThemeWatcher();rmSync(temp,{recursive:true,force:true});console.log(JSON.stringify({cases:cases.length,frames:snapshots.length,sha256:sha(readFileSync(outArg))}));
