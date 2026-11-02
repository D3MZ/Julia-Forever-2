// Test-only oracle for original Pi tool renderers; MIT copyright Mario Zechner.
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';import {execFileSync} from 'node:child_process';import {createHash} from 'node:crypto';import {createRequire} from 'node:module';import {join} from 'node:path';
const root=process.env.PI_SOURCE_ROOT,pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403';
if(!root||execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim()!==pin)throw Error('Original pin required');
execFileSync('git',['-C',root,'diff','--exit-code',pin,'--','packages/coding-agent/src','packages/tui/src','packages/ai/src']);
const paths=['packages/tui/src/tui.ts','packages/tui/src/tui-main-screen.ts','packages/tui/src/tui-alt-screen.ts','packages/coding-agent/src/core/tools/renderers/read.ts','packages/coding-agent/src/core/tools/renderers/edit.ts','packages/coding-agent/src/core/tools/renderers/bash.ts','packages/coding-agent/src/modes/interactive/components/tool-execution.ts','packages/coding-agent/src/modes/interactive/components/diff.ts'];
const hashes={};for(const path of paths){const original=execFileSync('git',['-C',root,'show',pin+':'+path]);const actual=readFileSync(join(root,path));if(!original.equals(actual))throw Error('Source mismatch');hashes[path]=createHash('sha256').update(actual).digest('hex');}
const temp=mkdtempSync('/tmp/jf2-pi-tools-');process.env.PI_CODING_AGENT_DIR=temp;process.env.PI_OFFLINE='1';process.env.PI_EXPERIMENTAL='0';process.env.TERM='xterm-256color';process.env.COLORTERM='truecolor';process.env.FORCE_COLOR='3';process.env.TZ='UTC';globalThis.fetch=()=>{throw Error('Network forbidden')};
const tui=await import(root+'/packages/tui/src/index.ts');const th=await import(root+'/packages/coding-agent/src/modes/interactive/theme/theme.ts');const {KeybindingsManager}=await import(root+'/packages/coding-agent/src/core/keybindings.ts');tui.setKeybindings(new KeybindingsManager());tui.setCapabilityOverrides({images:false,hyperlinks:false});th.initTheme('dark');
const {ToolExecutionComponent}=await import(root+'/packages/coding-agent/src/modes/interactive/components/tool-execution.ts');const {readRenderers}=await import(root+'/packages/coding-agent/src/core/tools/renderers/read.ts');const {editRenderers}=await import(root+'/packages/coding-agent/src/core/tools/renderers/edit.ts');const {createShellRenderers}=await import(root+'/packages/coding-agent/src/core/tools/renderers/bash.ts');
const definitions={read:readRenderers,edit:{...editRenderers,renderShell:'self'},bash:createShellRenderers('$')};
const result=(text,isError=false,details=undefined,extra={})=>({content:[{type:'text',text}],isError,details,...extra});
const cases=[
{name:'read-text',tool:'read',args:{path:'notes.txt'},result:result('first\nsecond\n')},
{name:'read-range',tool:'read',args:{file_path:'/tmp/project/notes.txt',offset:12,limit:8},result:result('twelve\nthirteen')},
{name:'read-error',tool:'read',args:{path:'missing.txt'},result:result('Not found',true)},
{name:'read-error-many',tool:'read',args:{path:'missing.txt'},result:result(Array.from({length:14},(_,i)=>'error '+i).join('\n'),true)},
{name:'read-resource',tool:'read',args:{path:'AGENTS.md'},result:result('Trusted instructions')},
{name:'read-skill',tool:'read',args:{path:'skills/analysis/SKILL.md'},result:result('Skill source')},
{name:'read-invalid-path',tool:'read',args:{path:42},result:result('Invalid path',true)},
{name:'read-truncated-lines',tool:'read',args:{path:'log.txt'},result:result('retained',false,{truncation:{truncated:true,truncatedBy:'lines',outputLines:2,totalLines:50,maxLines:2}})},
{name:'edit-diff',tool:'edit',args:{path:'note.txt',oldText:'old',newText:'new'},result:result('Edited',false,{diff:' 1 unchanged\n-2 old first\n-3 old second\n+2 new first\n+3 new second\n 4 unchanged',firstChangedLine:2})},
{name:'edit-word-diff',tool:'edit',args:{path:'note.txt',oldText:'hello world',newText:'hello Julia'},result:result('Edited',false,{diff:'-1 hello world\n+1 hello Julia',firstChangedLine:1})},
...[
['edit-whitespace','  old value','  new  value'],
['edit-punctuation','foo(a, b);','foo(a + b);'],
['edit-insertion','hello world','hello brave world'],
['edit-empty','','nonempty'],
['edit-unicode','héllo κόσμε','héllo Julia'],
].map(([name,oldText,newText])=>({name,tool:'edit',args:{path:'file.txt',oldText,newText},result:result('Edited',false,{diff:'-1 '+oldText+'\n+1 '+newText,firstChangedLine:1})})),
{name:'edit-error',tool:'edit',args:{path:'note.txt',oldText:'old',newText:'new'},result:result('Actual edit failed',true)},
{name:'edit-no-diff',tool:'edit',args:{path:'note.txt'},result:result('Edited successfully')},
{name:'bash-text',tool:'bash',args:{command:'printf hello'},result:result('hello')},
{name:'bash-many',tool:'bash',args:{command:'list',timeout:2},result:result(Array.from({length:14},(_,i)=>'output '+i).join('\n'))},
{name:'bash-long-line',tool:'bash',args:{command:'long'},result:result('begin '+('many words '.repeat(30))+' end')},
{name:'bash-error',tool:'bash',args:{command:'false'},result:result('Command failed',true)},
{name:'bash-duration',tool:'bash',args:{command:'work'},result:result('Finished',false,undefined,{durationMs:4200})},
{name:'bash-truncation',tool:'bash',args:{command:'logs'},result:result('retained\n\n[Full output /tmp/all.log]',false,{fullOutputPath:'/tmp/all.log',truncation:{truncated:true,truncatedBy:'lines',outputLines:2,totalLines:55}})},
{name:'bash-invalid',tool:'bash',args:{command:42},result:result('Bad command',true)}];
const lineRenderer=Object.create(tui.TuiMainScreen.prototype);lineRenderer.showHardwareCursor=false;
const framing={method:'actual TuiMainScreen.applyLineResets before terminal cell readback',source:'packages/tui/src/tui.ts',sha256:hashes['packages/tui/src/tui.ts']};
const snapshots=[];const fake={requestRender(){},terminal:{rows:40,columns:100}};
for(const fixture of cases){const comp=new ToolExecutionComponent(fixture.tool,'call',fixture.args,{outputPad:1,showImages:false},definitions[fixture.tool],fake,'/tmp/project');
const states=[{name:'pending',expanded:false,padding:1,result:false},{name:'complete',expanded:false,padding:1,result:true},{name:'expanded',expanded:true,padding:1,result:true},{name:'collapsed-again',expanded:false,padding:1,result:true},{name:'padding-zero',expanded:false,padding:0,result:true}];
for(const state of states){if(state.result)comp.updateResult(fixture.result);comp.setExpanded(state.expanded);comp.setOutputPad(state.padding);for(const width of [100,60,30])snapshots.push({id:fixture.name+'/'+state.name,fixture:fixture.name,state,width,ansiLines:lineRenderer.applyLineResets(comp.render(width))});}}
const require=createRequire(join(root,'package.json'));const {Terminal}=require('@xterm/headless');
for(const frame of snapshots){const term=new Terminal({cols:frame.width,rows:Math.max(2,frame.ansiLines.length+1),allowProposedApi:true,disableStdin:true});await new Promise(done=>term.write(frame.ansiLines.join('\r\n'),done));let canonical='';for(let y=0;y<frame.ansiLines.length;y++)for(let x=0;x<frame.width;x++){const cell=term.buffer.active.getLine(y).getCell(x);let fg=[cell.getFgColorMode(),cell.getFgColor()],bg=[cell.getBgColorMode(),cell.getBgColor()];if(cell.isInverse())[fg,bg]=[bg,fg];const values=[cell.getChars()||' ',...fg,...bg,+!!cell.isBold(),+!!cell.isDim(),+!!cell.isItalic(),+!!cell.isUnderline(),+!!cell.isStrikethrough()];canonical+=values.join('\0')+'\n';}frame.visualCellsSha256=createHash('sha256').update(canonical).digest('hex');frame.rowCount=frame.ansiLines.length;term.dispose();}
writeFileSync(process.argv[2],JSON.stringify({schemaVersion:1,pin,hashes,framing,cwd:'/tmp/project',cases,snapshots},null,2)+'\n');th.stopThemeWatcher();rmSync(temp,{recursive:true,force:true});
