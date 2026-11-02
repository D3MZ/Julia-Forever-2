// Test-only oracle for original Pi tool renderers; MIT copyright Mario Zechner.
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';import {execFileSync} from 'node:child_process';import {createHash} from 'node:crypto';import {createRequire} from 'node:module';import {join} from 'node:path';
const provenance=JSON.parse(readFileSync(process.argv[3]));
const root=process.argv[2],pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403';
if(!root||execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim()!==pin)throw Error('Original pin required');
execFileSync('git',['-C',root,'diff','--exit-code',pin,'--','packages/coding-agent/src','packages/tui/src','packages/ai/src']);
if(provenance.reference.commit!==pin||Object.keys(provenance.reference.sourceHashes).length!==513)throw Error('Invalid provenance');for(const [path,hash]of Object.entries(provenance.reference.sourceHashes))if(createHash('sha256').update(readFileSync(join(root,path))).digest('hex')!==hash)throw Error('Hash mismatch '+path);
const paths=['packages/coding-agent/src/utils/syntax-highlight.ts','packages/coding-agent/src/modes/interactive/theme/theme.ts','packages/coding-agent/src/core/tools/renderers/read.ts','packages/coding-agent/src/core/tools/renderers/edit.ts','packages/coding-agent/src/core/tools/renderers/bash.ts','packages/coding-agent/src/modes/interactive/components/tool-execution.ts','packages/coding-agent/src/modes/interactive/components/diff.ts'];
const hashes={};for(const path of paths){const original=execFileSync('git',['-C',root,'show',pin+':'+path]);const actual=readFileSync(join(root,path));if(!original.equals(actual))throw Error('Source mismatch');hashes[path]=createHash('sha256').update(actual).digest('hex');}
const temp=mkdtempSync('/tmp/jf2-pi-tools-');process.env.PI_CODING_AGENT_DIR=temp;process.env.PI_OFFLINE='1';process.env.PI_EXPERIMENTAL='0';process.env.TERM='xterm-256color';process.env.COLORTERM='truecolor';process.env.FORCE_COLOR='3';process.env.TZ='UTC';globalThis.fetch=()=>{throw Error('Network forbidden')};
await import(root+'/packages/coding-agent/src/experimental/source-resolver.ts');
const tui=await import(root+'/packages/tui/src/index.ts');const th=await import(root+'/packages/coding-agent/src/modes/interactive/theme/theme.ts');const {KeybindingsManager}=await import(root+'/packages/coding-agent/src/core/keybindings.ts');tui.setKeybindings(new KeybindingsManager());tui.setCapabilityOverrides({images:false,hyperlinks:false});th.initTheme('dark');
const {ToolExecutionComponent}=await import(root+'/packages/coding-agent/src/modes/interactive/components/tool-execution.ts');const {readRenderers}=await import(root+'/packages/coding-agent/src/core/tools/renderers/read.ts');const {editRenderers}=await import(root+'/packages/coding-agent/src/core/tools/renderers/edit.ts');const {createShellRenderers}=await import(root+'/packages/coding-agent/src/core/tools/renderers/bash.ts');
const definitions={read:readRenderers,edit:{...editRenderers,renderShell:'self'},bash:createShellRenderers('$')};
const result=(text,isError=false,details=undefined,extra={})=>({content:[{type:'text',text}],isError,details,...extra});
const cases=JSON.parse(readFileSync(process.argv[4]));
const snapshots=[];const fake={requestRender(){},terminal:{rows:40,columns:100}};
function capturePhase(phase){
for(const fixture of cases){const comp=new ToolExecutionComponent(fixture.tool,'call',fixture.args,{outputPad:1,showImages:false},definitions[fixture.tool],fake,'/tmp/project');
const states=[{name:'expanded',expanded:true,padding:1,result:true}];
for(const state of states){if(state.result)comp.updateResult(fixture.result);comp.setExpanded(state.expanded);comp.setOutputPad(state.padding);for(const width of [100,40])snapshots.push({id:phase+'/'+fixture.name+'/'+state.name,fixture:fixture.name,languagePhase:phase,state,width,ansiLines:comp.render(width)});}}
}

const {loadAllHighlightLanguages}=await import(root+'/packages/coding-agent/src/utils/syntax-highlight.ts');await loadAllHighlightLanguages();capturePhase('full');
const require=createRequire(join(root,'package.json'));const {Terminal}=require('@xterm/headless');
for(const frame of snapshots){const term=new Terminal({cols:frame.width,rows:Math.max(2,frame.ansiLines.length+1),allowProposedApi:true,disableStdin:true});await new Promise(done=>term.write(frame.ansiLines.join('\r\n'),done));let canonical='';for(let y=0;y<frame.ansiLines.length;y++)for(let x=0;x<frame.width;x++){const cell=term.buffer.active.getLine(y).getCell(x);let fg=[cell.getFgColorMode(),cell.getFgColor()],bg=[cell.getBgColorMode(),cell.getBgColor()];if(cell.isInverse())[fg,bg]=[bg,fg];const values=[cell.getChars()||' ',...fg,...bg,+!!cell.isBold(),+!!cell.isDim(),+!!cell.isItalic(),+!!cell.isUnderline(),+!!cell.isStrikethrough()];canonical+=values.join('\0')+'\n';}frame.visualCellsSha256=createHash('sha256').update(canonical).digest('hex');frame.rowCount=frame.ansiLines.length;term.dispose();}
writeFileSync(process.argv[5],JSON.stringify({schemaVersion:1,pin,hashes,sourceHashes:provenance.reference.sourceHashes,cwd:'/tmp/project',cases,snapshots},null,2)+'\n');th.stopThemeWatcher();rmSync(temp,{recursive:true,force:true});
