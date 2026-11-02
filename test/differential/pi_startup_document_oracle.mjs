// Test-only extraction executes unmodified, hash-checked original header initialization;
// all resource/status rendering and viewport layout use the original classes directly.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,rmSync,chmodSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir,homedir} from 'node:os';
import {pathToFileURL,fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {stripTypeScriptTypes} from 'node:module';
const [rootArg,provenanceArg,outputArg]=process.argv.slice(2),root=resolve(rootArg),output=resolve(outputArg);
const sha=data=>createHash('sha256').update(data).digest('hex');
const provenanceBytes=readFileSync(provenanceArg),prior=JSON.parse(provenanceBytes),pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403';
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),pin);
for(const [path,hash]of Object.entries(prior.reference.sourceHashes))assert.equal(sha(readFileSync(join(root,path))),hash,path);
process.env.HOME='/fixture/home'; // Stable synthetic fixture home, never the caller's real profile.
const fixtureRoot=mkdtempSync(join(tmpdir(),'pi-startup-document-'));process.env.PI_CODING_AGENT_DIR=fixtureRoot;process.env.PI_OFFLINE='1';process.env.PI_EXPERIMENTAL='0';process.env.COLORTERM='truecolor';
globalThis.fetch=()=>{throw Error('Network forbidden in fixture oracle');};
const load=path=>import(pathToFileURL(join(root,path)).href);
await load('packages/coding-agent/src/experimental/source-resolver.ts');
const tui=await load('packages/tui/src/index.ts'),layout=await load('packages/tui/src/layout.ts');
const th=await load('packages/coding-agent/src/modes/interactive/theme/theme.ts');
const {InteractiveMode}=await load('packages/coding-agent/src/modes/interactive/interactive-mode.ts');
const {ThemedText}=await load('packages/coding-agent/src/modes/interactive/components/themed-text.ts');
const hints=await load('packages/coding-agent/src/modes/interactive/components/keybinding-hints.ts');
const logo=await load('packages/coding-agent/src/modes/interactive/components/pi-logo.ts');
const {createChatViewport}=await load('packages/coding-agent/src/modes/interactive/chat-viewport.ts');
const {SettingsSelectorComponent}=await load('packages/coding-agent/src/modes/interactive/components/settings-selector.ts');
const {KeybindingsManager}=await load('packages/coding-agent/src/core/keybindings.ts');
const source=readFileSync(join(root,'packages/coding-agent/src/modes/interactive/interactive-mode.ts'),'utf8');
const classStart=source.indexOf('class ExpandableText extends'),classEnd=source.indexOf('\ntype ExtensionDialogComponent',classStart);
const classes=source.slice(classStart,classEnd);assert(classes.includes('class BuiltInHeader')&&classEnd>classStart);
const start=source.indexOf('// Add header with keybindings from config (unless silenced)'),end=source.indexOf('if (this.renderer.mode === "fullscreen") this.showFullscreenModelScopeNotice();',start);assert(start>0&&end>start);
const block=source.slice(start,end),script=stripTypeScriptTypes(classes+'\nfunction build(){\n'+block+'\n}\n',{mode:'strip'})+'\nreturn build;';
const keys=new KeybindingsManager();tui.setKeybindings(keys);tui.setCapabilityOverrides({images:false,trueColor:true,hyperlinks:false});th.initTheme('dark');
const normalizeRenderer=Object.create(tui.TuiMainScreen.prototype);normalizeRenderer.showHardwareCursor=false;
const normalize=rows=>{const out=normalizeRenderer.resolveFakeCursors(rows);normalizeRenderer.extractCursorPosition(out,out.length);return normalizeRenderer.applyLineResets(out);};
const bindings=Object.fromEntries(['app.interrupt','app.clear','app.exit','app.suspend','tui.editor.deleteToLineEnd','app.thinking.cycle','app.model.cycleForward','app.model.cycleBackward','app.model.select','app.tools.expand','app.thinking.toggle','app.editor.external','app.message.followUp','app.message.dequeue','app.clipboard.pasteImage'].map(id=>[id,keys.getKeys(id).join('/')]));
const cwd='/fixture/project',home=homedir();
const local=(scope='project')=>({source:'local',scope});
const base={quiet:false,verbose:false,expanded:false,logo:true,version:'1.4.0',theme:'dark',cwd,home,bindings,scopedModels:[],context:[],skills:[],prompts:[],extensions:[],skillDiagnostics:[],promptDiagnostics:[],themeDiagnostics:[],extensionDiagnostics:[],statuses:[],force:false,diagnosticsWhenQuiet:false};
const resources={context:[{path:cwd+'/AGENTS.md'},{path:home+'/.pi/agent/APPEND.md'},{path:cwd+'/nested/指示.md'}],skills:[{name:'review',filePath:cwd+'/.pi/skills/review/SKILL.md',sourceInfo:local()},{name:'alpha',filePath:home+'/.pi/agent/skills/alpha/SKILL.md',sourceInfo:local('user')},{name:'temp',filePath:'/fixture/temp/SKILL.md',sourceInfo:{source:'cli',scope:'temporary'}}],prompts:[{name:'ship',filePath:cwd+'/.pi/prompts/ship.md',sourceInfo:local()},{name:'audit',filePath:home+'/.pi/agent/prompts/audit.md',sourceInfo:local('user')}],extensions:[{path:cwd+'/.pi/extensions/one/index.ts',sourceInfo:local()},{path:home+'/.pi/agent/extensions/two.ts',sourceInfo:local('user')},{path:'/fixture/packages/widget/extensions/index.ts',sourceInfo:{source:'npm:widget',scope:'project',baseDir:'/fixture/packages/widget'}}]};
const diagnostics={skillDiagnostics:[{type:'warning',path:cwd+'/.pi/skills/review/SKILL.md',message:'Missing optional description'},{type:'collision',collision:{name:'review',winnerPath:cwd+'/.pi/skills/review/SKILL.md',loserPath:home+'/.pi/agent/skills/alpha/SKILL.md'}}],promptDiagnostics:[{type:'error',message:'Invalid prompt metadata'}],themeDiagnostics:[{type:'warning',path:cwd+'/theme.json',message:'Ignored invalid color token'}],extensionDiagnostics:[{path:cwd+'/broken.ts',error:'Fixture extension failed to load'}]};
const statuses=[{type:'warning',message:'fd not found. Offline mode enabled, skipping download.'},{type:'info',message:'Using installed rg'}];
const specs=[['default',{}],['quiet-header',{quiet:'header',...resources}],['quiet',{quiet:true,...resources,...diagnostics}],['verbose-overrides-quiet',{quiet:true,verbose:true,...resources}],['expanded',{expanded:true}],['fallback-wordmark',{logo:false}],['scoped',{scopedModels:[{model:{id:'alpha'},thinkingLevel:'high'},{model:{id:'β-model'}}]}],['resources',resources],['resources-expanded',{...resources,expanded:true}],['diagnostics',{...resources,...diagnostics}],['quiet-diagnostics',{quiet:true,...resources,...diagnostics,diagnosticsWhenQuiet:true}],['force-resources',{quiet:true,...resources,force:true}],['tool-status',{statuses}],['long-status',{statuses:[{type:'warning',message:'A very long status with Unicode 指示 and combining café, then /very/long/no-break/path/abcdefghijklmnopqrstuvwxyz.'}]}],['custom-keys',{bindings:{...bindings,'app.interrupt':'escape','app.clear':'ctrl+l','app.tools.expand':'alt+o','app.model.cycleForward':''}}]];
const snapshots=[],cases=[];
for(const [id,changes]of specs)for(const width of [100,60,30,10,5]){
 const config={...structuredClone(base),...structuredClone(changes)};const mode=Object.create(InteractiveMode.prototype);
 const customKeys=new KeybindingsManager(Object.fromEntries(Object.entries(config.bindings).map(([k,v])=>[k,v?v.split('/'):[]])));tui.setKeybindings(customKeys);
 Object.defineProperties(mode,Object.fromEntries(Object.entries({options:{verbose:config.verbose},toolOutputExpanded:config.expanded,version:config.version,settingsManager:{getQuietStartup:()=>config.quiet},keybindings:customKeys,sessionManager:{getCwd:()=>cwd},headerContainer:new tui.Container(),loadedResourcesContainer:new tui.Container(),chatContainer:new tui.Container(),ui:{requestRender(){}},renderer:{mode:'fullscreen'},managedToolStatusStarted:false}).map(([name,value])=>[name,{value,writable:true,configurable:true}])));
 const runner={getCommandDiagnostics:()=>[],getShortcutDiagnostics:()=>[],getRegisteredCommands:()=>[]};
 Object.defineProperty(mode,'session',{value:{scopedModels:config.scopedModels,promptTemplates:config.prompts,extensionRunner:runner,resourceLoader:{getSkills:()=>({skills:config.skills,diagnostics:config.skillDiagnostics}),getPrompts:()=>({prompts:config.prompts,diagnostics:config.promptDiagnostics}),getThemes:()=>({themes:[],diagnostics:config.themeDiagnostics}),getExtensions:()=>({extensions:config.extensions,errors:config.extensionDiagnostics,warnings:[]}),getSystemPromptSource:()=>undefined,getAppendSystemPromptSources:()=>[],getAgentsFiles:()=>({agentsFiles:config.context})}}});
 th.setTheme(config.theme);
 const build=new Function('ThemedText','Text','Spacer','theme','supportsPiLogo','piWordmark','piLogoLines','keyHint','keyText','rawKeyHint','playPiLogo3d',script)(ThemedText,tui.Text,tui.Spacer,th.theme,()=>config.logo,logo.piWordmark,logo.piLogoLines,hints.keyHint,hints.keyText,hints.rawKeyHint,()=>{});build.call(mode);mode.showFullscreenModelScopeNotice();mode.showLoadedResources({force:config.force,showDiagnosticsWhenQuiet:config.diagnosticsWhenQuiet});for(const status of config.statuses)mode.showManagedToolStatus(status);
 const document=new tui.Container();for(const child of [mode.headerContainer,mode.loadedResourcesContainer,mode.chatContainer])document.addChild(child);
 const rows=normalize(document.render(width));snapshots.push({id,width,terminalAnsiLines:rows});
 const settings=new SettingsSelectorComponent(structuredClone(prior.fixtures.settingsConfig),new Proxy({}, {get:()=>()=>{}}));
 const empty=new tui.Container(),footer=new tui.Text('fixture cwd\n0.0%/0 (auto)',0,0),widgets=new tui.Spacer(1);
 const viewport=createChatViewport({document,pendingMessages:empty,status:empty,widgetsAbove:widgets,editor:settings,widgetsBelow:empty,footer,scrollbar:'hidden'});
 const sceneFrame=layout.renderLayoutFrame(viewport.root,width,32,()=>{});const scene=normalize(sceneFrame.lines);snapshots.push({id:id+'.scene',width,terminalAnsiLines:scene});
 cases.push({id,width,config:structuredClone(config),documentRows:rows.length,sceneRows:scene.length,documentHeight:sceneFrame.root.children[0].rect.height,dockRects:sceneFrame.root.children[1].children.map(box=>({top:box.rect.y+1,height:box.rect.height,first_row:(box.lineOffset??0)+1}))});
 if(id==='resources'&&width>=30){
  const initial=structuredClone(config);
  const actions=[{kind:'expand',value:true},{kind:'expand',value:true},{kind:'expand',value:false},{kind:'theme',value:'light'},{kind:'resources',value:'empty'},{kind:'resources',value:'restore'},{kind:'theme',value:'dark'},{kind:'expand',value:true},{kind:'expand',value:false}];
  for(const [index,action] of actions.entries()){
   if(action.kind==='expand'){
    const changed=config.expanded!==action.value;mode.setToolsExpanded(action.value);config.expanded=action.value;
    if(changed){const notice={type:'notice',message:`Tool output: ${action.value?'expanded':'collapsed'}`};if(config.statuses.at(-1)?.type==='notice')config.statuses[config.statuses.length-1]=notice;else config.statuses.push(notice);}
   }else if(action.kind==='theme'){th.setTheme(action.value);config.theme=action.value;document.invalidate();}
   else {for(const key of ['context','skills','prompts','extensions'])config[key]=action.value==='empty'?[]:structuredClone(initial[key]);mode.session.promptTemplates=config.prompts;mode.showLoadedResources();}
   const frameid=`transition.${index}.${action.kind}`,updated=normalize(document.render(width));
   snapshots.push({id:frameid,width,terminalAnsiLines:updated});
   cases.push({id:frameid,width,config:structuredClone(config),sequenceInitial:initial,action,documentRows:updated.length,documentOnly:true});
  }
 }

}
const {ensureTool}=await load('packages/coding-agent/src/utils/tools-manager.ts');
const previousPath=process.env.PATH;process.env.PATH=fixtureRoot;const toolProbes=[];
for(const [tool,present]of [['fd',null],['rg',null],['fd','fd'],['fd','fdfind'],['rg','rg']]){
 for(const name of ['fd','fdfind','rg'])rmSync(join(fixtureRoot,name),{force:true});
 if(present){const path=join(fixtureRoot,present);writeFileSync(path,'#!/bin/sh\nexit 0\n');chmodSync(path,0o700);}
 const statuses=[];const result=await ensureTool(tool,status=>statuses.push(status));toolProbes.push({tool,present,found:result!==undefined,statuses});
}
process.env.PATH=previousPath;
const data={schemaVersion:1,reference:prior.reference,provenance:{checkedSourceFiles:513,runnerSha256:sha(readFileSync(fileURLToPath(import.meta.url))),headerBlockSha256:sha(block),extractedClassesSha256:sha(classes)},method:'Original unchanged header source block and classes; original InteractiveMode resource/status methods, Text, SettingsSelector, createChatViewport and renderLayoutFrame. Fixture-only inputs; no CLI, auth, provider, filesystem resource-loading or model calls.',cases,snapshots,toolProbes};
writeFileSync(output,JSON.stringify(data)+'\n',{flag:'wx'});th.stopThemeWatcher();rmSync(fixtureRoot,{recursive:true,force:true});console.log(JSON.stringify({cases:cases.length,frames:snapshots.length,sha256:sha(readFileSync(output))}));
