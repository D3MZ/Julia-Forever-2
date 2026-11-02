// Test-only original Pi display transition oracle (MIT, copyright Mario Zechner).
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {join} from 'node:path';
import {createRequire} from 'node:module';
const root=process.env.PI_SOURCE_ROOT;
const pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403';
if(!root||execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim()!==pin) throw Error('Exact original Pi required');
execFileSync('git',['-C',root,'diff','--exit-code',pin,'--','packages/coding-agent/src','packages/tui/src','packages/ai/src']);
const hashes={
 'packages/tui/src/tui.ts':'aefbe5a8e9ef9ee32936ca4646309ad7dbbb88c460fac0850456e4717855fbed',
 'packages/tui/src/tui-main-screen.ts':'2482c5fe887b8887014a8848ce0488f02f0314ac03bbca2d16dce2aa057e3582',
 'packages/tui/src/tui-alt-screen.ts':'467ae17db826865c24489af17384112c0eb82f42a624aab374f9747afb8d6dab',
 'packages/coding-agent/src/core/session-manager.ts':'51398209d139707e18c7c2d33a8225813d7db1337800631be410b0aca412e597',
 'packages/coding-agent/src/core/messages.ts':'5397e3c96c9504266e4ee8b6e88d5098b3280ee7dbb0c687b74708c62a06c8d4',
 'packages/coding-agent/src/modes/interactive/interactive-mode.ts':'ee4ba8aeee85b772aee57b342356da3030eed3b2c32656fa9c0927e6a81fbab0'};
for(const [path,hash] of Object.entries(hashes))if(createHash('sha256').update(readFileSync(join(root,path))).digest('hex')!==hash) throw Error('Original source changed');
const privateDir=mkdtempSync('/tmp/jf2-pi-display-');
process.env.PI_CODING_AGENT_DIR=privateDir;process.env.PI_OFFLINE='1';process.env.PI_EXPERIMENTAL='0';process.env.TERM='xterm-256color';process.env.COLORTERM='truecolor';process.env.TZ='UTC';process.env.FORCE_COLOR='3';
globalThis.fetch=()=>{throw Error('Network forbidden in display oracle')};
const {InteractiveMode}=await import(root+'/packages/coding-agent/src/modes/interactive/interactive-mode.ts');
const {buildContextEntries}=await import(root+'/packages/coding-agent/src/core/session-manager.ts');
const tui=await import(root+'/packages/tui/src/index.ts');
const theme=await import(root+'/packages/coding-agent/src/modes/interactive/theme/theme.ts');
const {KeybindingsManager}=await import(root+'/packages/coding-agent/src/core/keybindings.ts');
tui.setKeybindings(new KeybindingsManager());tui.setCapabilityOverrides({images:false});theme.initTheme('dark');
const contexts=JSON.parse(readFileSync(process.argv[2],'utf8'));
const cases=contexts.cases.filter(x=>['plain','compaction-edits','nested-compaction','rich','custom-edit','bash-cancelled-empty','empty-summary-compaction'].includes(x.name)).map(x=>({name:x.name,entries:x.entries}));
const rich=contexts.cases.find(x=>x.name==='rich');
const stamp='2026-11-01T21:00:00.123Z';
const usage={input:7,output:3,cacheRead:0,cacheWrite:0,cost:{total:0.01}};
cases.push({name:'usage-visible',entries:[...rich.entries,{type:'usage',id:'usage1',parentId:'empty-summary',timestamp:stamp,kind:'cache_warm',provider:'openai',model:'fixture',usage}],showUsage:true});
cases.push({name:'summary-usage',entries:[{type:'compaction',id:'c',parentId:null,timestamp:stamp,summary:'Billed',tokensBefore:9,firstKeptEntryId:'c',usage}],showUsage:true});
cases.push({name:'extension-visible',entries:rich.entries,customRenderer:true});
cases.push({name:'empty-user-system-orphan-result',entries:[{type:'message',id:'s',parentId:null,timestamp:stamp,message:{role:'system',content:'system'}},{type:'message',id:'u',parentId:'s',timestamp:stamp,message:{role:'user',content:[{type:'image',data:'AQID',mimeType:'image/png'}]}},{type:'message',id:'r',parentId:'u',timestamp:stamp,message:{role:'toolResult',toolCallId:'missing',content:[{type:'text',text:'orphan'}],isError:false}}]});
const call={type:'toolCall',id:'error-call',name:'read',arguments:{path:'fixture'}};
for(const stopReason of ['aborted','error'])cases.push({name:`tool-${stopReason}`,retryAttempt:2,entries:[{type:'message',id:'call',parentId:null,timestamp:stamp,message:{role:'assistant',content:[call],stopReason,errorMessage:'Actual failure',provider:'fixture',model:'fixture'}},{type:'message',id:'late',parentId:'call',timestamp:stamp,message:{role:'toolResult',toolCallId:'error-call',content:[{type:'text',text:'late result'}],isError:false}}]});
cases.push({name:'signed-display-text',entries:[{type:'message',id:'signed',parentId:null,timestamp:stamp,message:{role:'assistant',content:[{type:'text',text:'Signed text',textSignature:'opaque-signature'}],provider:'fixture',model:'fixture',stopReason:'stop'}}]});
cases.push({name:'summary-usage-hidden',entries:cases.find(x=>x.name==='summary-usage').entries});
cases.push({name:'explicit-full-archive',entries:contexts.cases.find(x=>x.name==='compaction-edits').entries,mode:'archive'});
const imageFree=structuredClone(rich.entries);for(const entry of imageFree){if(entry.type==='message'&&Array.isArray(entry.message.content))entry.message.content=entry.message.content.filter(block=>block.type!=='image');}cases.push({name:'rich-text-tools',entries:imageFree});
const snapshots=[];
const lineRenderer=Object.create(tui.TuiMainScreen.prototype);lineRenderer.showHardwareCursor=false;
const framing={method:'actual TuiMainScreen.applyLineResets before terminal cell readback',source:'packages/tui/src/tui.ts',sha256:hashes['packages/tui/src/tui.ts']};
for(const fixture of cases){
 for(const entry of fixture.entries){if(entry.type==='message'&&entry.message.role==='assistant'){const value=entry.message.usage??{};entry.message.usage={input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0},...value};}}
 const entries=fixture.mode==='archive'?fixture.entries:buildContextEntries(fixture.entries,fixture.leaf);
 const mode=Object.create(InteractiveMode.prototype);
 const chat=new tui.Container();const observations=[];const itemObservations=[];const itemSources=new Map();
 const setup={renderer:null,chatContainer:chat,pendingTools:new Map(),ui:{requestRender(){},terminal:{rows:40,columns:100},setFocus(){}},outputPad:1,toolOutputExpanded:false,hideThinkingBlock:false,hiddenThinkingLabel:'Thinking...',
 session:{modelRuntime:{getModel:()=>undefined},extensionRunner:{getEntryRenderer:()=>fixture.customRenderer?((entry)=>new tui.Text(`Custom ${entry.customType}`,0,0)):undefined,getMessageRenderer:()=>undefined},retryAttempt:fixture.retryAttempt??0},
 sessionManager:{getEntries:()=>fixture.entries,getCwd:()=>'/tmp'},settingsManager:{getShowCacheMissNotices:()=>!!fixture.showUsage,getShowImages:()=>false,getImageWidthCells:()=>60},
 getMarkdownThemeWithSettings:()=>theme.getMarkdownTheme(),getMarkdownTransformers:()=>[],getRegisteredToolDefinition:()=>undefined,editor:{addToHistory(){}},footer:{invalidate(){}},updateEditorBorderColor(){}};
 Object.defineProperties(mode,Object.fromEntries(Object.entries(setup).map(([key,value])=>[key,{value,writable:true,configurable:true}])));
 let captured=[];
 mode.renderSessionItems=function(items,meta,options){let lastId=null,lastTime=null;captured=items.map(item=>{const origin=meta?.get(item);if(origin){lastId=origin.id;lastTime=origin.timestamp;}else if(item.id){lastId=item.id;lastTime=item.timestamp;}itemSources.set(item,lastId);return {sourceId:lastId,timestamp:lastTime,payload:structuredClone(item)};});return InteractiveMode.prototype.renderSessionItems.call(this,items,meta,options);};
 mode.addMessageToChat=function(message,options){const before=chat.children.length;const result=InteractiveMode.prototype.addMessageToChat.call(this,message,options);const visible=chat.children.slice(before).filter(child=>child.constructor.name!=='Spacer');observations.push({sourceId:options?.messageId??null,role:message.role,visible:visible.length>0,componentTypes:visible.map(x=>x.constructor.name)});return result;};
 for(const [method,kind] of [['addCustomEntryToChat','custom'],['addCacheWarmingUsage','usage'],['addCompactionCostNotice','compaction_cost']]){
  mode[method]=function(item){const before=chat.children.length;const result=InteractiveMode.prototype[method].call(this,item);const visible=chat.children.slice(before).some(child=>child.constructor.name!=='Spacer');itemObservations.push({sourceId:itemSources.get(item),kind,visible});return result;};
 }
 InteractiveMode.prototype.renderSessionEntries.call(mode,entries);
 const toolComponents=chat.children.filter(child=>child.constructor.name==='ToolExecutionComponent');
 fixture.expected={entries,items:captured,observations,itemObservations,tools:toolComponents.map(child=>({id:child.toolCallId,name:child.toolName,args:child.args,result:child.result??null})),componentTypes:chat.children.filter(child=>child.constructor.name!=='Spacer').map(child=>child.constructor.name),lines:chat.render(100)};
 const states=[{name:'collapsed',expanded:false,hideThinking:false,padding:1},{name:'expanded',expanded:true,hideThinking:false,padding:1},{name:'collapsed-again',expanded:false,hideThinking:false,padding:1},{name:'thinking-hidden',expanded:false,hideThinking:true,padding:1},{name:'padding-zero',expanded:false,hideThinking:false,padding:0}];
 for(const state of states){for(const child of chat.children){child.setExpanded?.(state.expanded);child.setHideThinkingBlock?.(state.hideThinking);child.setOutputPad?.(state.padding);}
 for(const width of [100,60,30])snapshots.push({id:fixture.name+'/'+state.name,fixture:fixture.name,state,width,ansiLines:lineRenderer.applyLineResets(chat.render(width))});}

}
const require=createRequire(join(root,'package.json'));const {Terminal}=require('@xterm/headless');
for(const frame of snapshots){const term=new Terminal({cols:frame.width,rows:Math.max(2,frame.ansiLines.length+1),allowProposedApi:true,disableStdin:true});await new Promise(done=>term.write(frame.ansiLines.join('\r\n'),done));let canonical='';for(let y=0;y<frame.ansiLines.length;y++)for(let x=0;x<frame.width;x++){const cell=term.buffer.active.getLine(y).getCell(x);const values=[cell.getChars()||' ',cell.getFgColorMode(),cell.getFgColor(),cell.getBgColorMode(),cell.getBgColor(),+!!cell.isBold(),+!!cell.isDim(),+!!cell.isItalic(),+!!cell.isUnderline(),+!!cell.isStrikethrough()];canonical+=values.join('\0')+'\n';}frame.cellsSha256=createHash('sha256').update(canonical).digest('hex');frame.rowCount=frame.ansiLines.length;term.dispose();}
writeFileSync(process.argv[3],JSON.stringify({schemaVersion:1,pin,hashes,framing,cases,snapshots},null,2)+'\n');theme.stopThemeWatcher();rmSync(privateDir,{recursive:true,force:true});
