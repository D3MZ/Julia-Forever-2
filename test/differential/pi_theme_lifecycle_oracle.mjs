// Execute unchanged, exact-hash-checked Pi parsers, query queue and real fs watcher.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,mkdirSync,rmSync,renameSync} from 'node:fs';
import {join,resolve} from 'node:path'; import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto'; import {execFileSync} from 'node:child_process'; import {pathToFileURL} from 'node:url';
const root=resolve(process.argv[2]),out=process.argv[3],pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403';
const git=(...a)=>execFileSync('git',['-C',root,...a],{encoding:'utf8'}).trim(); assert.equal(git('rev-parse','HEAD'),pin);git('diff','--exit-code',pin,'--','packages/tui/src','packages/coding-agent/src');
const sourceHashes=Object.fromEntries(git('ls-files','packages/tui/src','packages/coding-agent/src').split('\n').map(p=>[p,createHash('sha256').update(readFileSync(join(root,p))).digest('hex')]));
const temp=mkdtempSync(join(tmpdir(),'pi-theme-lifecycle-'));mkdirSync(join(temp,'themes'));process.env.PI_CODING_AGENT_DIR=temp;process.env.PI_OFFLINE='1';process.env.COLORTERM='truecolor';delete process.env.COLORFGBG;globalThis.fetch=()=>{throw Error('Network forbidden')};
const load=p=>import(pathToFileURL(join(root,p)).href);await load('packages/coding-agent/src/experimental/source-resolver.ts');
const tui=await load('packages/tui/src/index.ts'); const parsers=await load('packages/tui/src/terminal-colors.ts'); const th=await load('packages/coding-agent/src/modes/interactive/theme/theme.ts'); const {validateThemeJson}=await load('packages/coding-agent/src/modes/interactive/theme/theme-schema.ts'); th.setThemeJsonValidator(validateThemeJson); tui.setCapabilityOverrides({trueColor:true,images:false,hyperlinks:false});
const clean=x=>JSON.parse(JSON.stringify(x));
const parserInputs=['\x1b]10;rgb:ffff/8000/0000\x07','\x1b]11;#112233\x1b\\','\x1b]4;15;#0000ffff8080\x07','\x1b]4;255;RGBA:f/0/a/ffff\x07','\x1b]4;000;0/80/fff\x07','\x1b]10; rgb:abc/def/012 \x07','\x1b]10;#123\x07','\x1b]10;rgb:/ffff/0000\x07','\x1b]10;blue\x07','\x1b]4;999;#abcdef\x07','\x1b]4;1000;#abcdef\x07','\x1b]12;#abcdef\x07','text','\x1b[?997;1n','\x1b[?997;2n','\x1b[?997;1n\x1b[?997;2n','\x1b[?997;3n'];
const parsersCases=parserInputs.map(input=>({input,color:parsers.parseOscColorResponse(input)??null,scheme:parsers.parseTerminalColorSchemeReport(input)??null}));
// Fake only the clock: original query, parser, queue and callback code is executed intact.
const realSet=globalThis.setTimeout,realClear=globalThis.clearTimeout;let timers=[],now=0;
globalThis.setTimeout=(callback,delay)=>{const h={callback,delay,due:now+delay,cancelled:false};timers.push(h);return h};globalThis.clearTimeout=h=>{if(h)h.cancelled=true};
async function advance(ms){now+=ms;for(const h of timers.filter(h=>!h.cancelled&&h.due<=now)){h.cancelled=true;h.callback()}await Promise.resolve();}
const cases=[];
async function queryCase(id,steps){timers=[];now=0;let events=[],writes=[];const ui=Object.create(tui.TuiMainScreen.prototype);ui.pendingTerminalColorQueries=[];ui.terminal={write:s=>writes.push(s)};let next=0;const snapshots=[];for(const step of [{type:'start'},...steps]){let consumed=null;if(step.type==='start'){const index=next++;ui.queryTerminalColors({timeoutMs:100,onLateReply:colors=>events.push({index,kind:'late',colors:clean(colors)})}).then(colors=>events.push({index,kind:'initial',colors:clean(colors)}));}else if(step.type==='input')consumed=ui.consumeTerminalColorResponse(step.input);else if(step.type==='advance')await advance(step.ms);await Promise.resolve();snapshots.push({step,consumed,events:clean(events),writes:clean(writes),pending:ui.pendingTerminalColorQueries.length,timers:timers.filter(h=>!h.cancelled).map(h=>h.delay)});}cases.push({id,snapshots});}
const input=s=>({type:'input',input:s}),adv=ms=>({type:'advance',ms});const osc=(target,value)=>`\x1b]${target};${value}\x07`,da='\x1b[?1;2c';const full=[input(osc('10','#ffffff')),input(osc('11','#000000')),...Array.from({length:16},(_,i)=>input(osc('4;'+i,'#'+(i*0x10101).toString(16).padStart(6,'0'))))];
await queryCase('partial-da',[input(osc('10','#abcdef')),input(osc('11','#123456')),input(da),adv(100)]);
await queryCase('timeout-late-partial',[adv(99),adv(1),input(osc('11','#111111')),input(da),adv(100)]);
await queryCase('timeout-partial-late-full',[input(osc('10','#ffffff')),adv(100),...full,input(da)]);
await queryCase('duplicate-invalid',[input(osc('10','invalid')),input(osc('10','#ffffff')),input(osc('4;1','invalid')),input(osc('4;1','#ff0000')),input(da)]);
await queryCase('complete-before-da-next-query',[...full,{type:'start'},input(osc('11','#333333')),input(da),input(osc('11','#eeeeee')),input(da)]);
await queryCase('unrelated-input',[input('hello'),input('\x1b[A'),input(osc('4;255','#123456')),input(da)]);
// Real native fs.watch receives actual directory changes; fake timer permits exact debounce assertions.
let changed=0;th.onThemeChange(()=>changed++);const template=JSON.parse(readFileSync(join(root,'packages/coding-agent/src/modes/interactive/theme/dark.json')));const document=accent=>({...structuredClone(template),name:'fixture',colors:{...template.colors,accent}});const path=join(temp,'themes','fixture.json');writeFileSync(path,JSON.stringify(document('#112233')));th.initTheme('fixture',true);timers=[];now=0;
const watcher=[];const capture=(event)=>watcher.push({event,accent:tui.colorToHex(th.theme.colors.accent),changed,delays:timers.filter(h=>!h.cancelled).map(h=>h.delay)});
const yieldFs=()=>new Promise(r=>realSet(r,25));capture('start');
writeFileSync(path,JSON.stringify(document('#445566')));await yieldFs();capture('write');await advance(99);capture('before-debounce');await advance(1);capture('reload');
writeFileSync(path,'{');await yieldFs();await advance(100);capture('invalid-retains');
rmSync(path);await yieldFs();await advance(100);capture('missing-retains');
writeFileSync(path,JSON.stringify(document('#778899')));await yieldFs();await advance(100);capture('recreate-reloads');
writeFileSync(join(temp,'themes','other.json'),JSON.stringify(document('#ffffff')));await yieldFs();await advance(100);capture('unrelated-ignored');
writeFileSync(join(temp,'replacement.json'),JSON.stringify(document('#aabbcc')));renameSync(join(temp,'replacement.json'),path);await yieldFs();await advance(100);capture('atomic-replace-reloads');
writeFileSync(path,JSON.stringify(document('#abcdef')));await yieldFs();capture('pending-before-stop');th.stopThemeWatcher();await advance(100);capture('stopped-retains');

// Exercise the real controller against the real original query queue, with only IO and time replaced.
th.stopThemeWatcher();th.setTerminalColors({});th.setTerminalColorScheme(undefined);timers=[];now=0;
const {InteractiveThemeController}=await load('packages/coding-agent/src/modes/interactive/theme/theme-controller.ts');
const ui=Object.create(tui.TuiMainScreen.prototype),writes=[];ui.pendingTerminalColorQueries=[];ui.terminal={write:s=>writes.push(s)};ui.terminalColorSchemeListeners=new Set();ui.terminalColorSchemeNotificationsEnabled=false;ui.stopped=false;ui.invalidate=()=>{};ui.requestRender=()=>{};
let controller=new InteractiveThemeController(ui,{getSettingsManager:()=>({getThemeSetting:()=>undefined}),showError:()=>{},onChanged:()=>{}});
const controllerCases=[];const cc=step=>controllerCases.push({step,active:th.theme.name,appearance:th.getTerminalTheme(),accent:tui.colorToHex(th.theme.colors.accent),accentAnsi:th.theme.getFgAnsi('accent'),writes:[...writes]});
controller.applyFromSettings();cc({type:'start'});await advance(99);cc({type:'advance',ms:99});await advance(1);cc({type:'advance',ms:1});
for(const data of [osc('10','#eeeeee'),osc('11','#111111'),da]){ui.consumeTerminalColorResponse(data);await Promise.resolve();cc({type:'input',data});}
ui.consumeTerminalColorSchemeReport('\x1b[?997;2n');cc({type:'input',data:'\x1b[?997;2n'});await advance(100);cc({type:'advance',ms:100});ui.consumeTerminalColorResponse(da);await Promise.resolve();cc({type:'input',data:da});
controller.setThemeSetting('light/dark');cc({type:'setting',value:'light/dark'});ui.consumeTerminalColorResponse(osc('10','#111111'));ui.consumeTerminalColorResponse(osc('11','#eeeeee'));ui.consumeTerminalColorResponse(da);await Promise.resolve();cc({type:'colors',foreground:'#111111',background:'#eeeeee'});
controller.setThemeName('dark');cc({type:'fixed',value:'dark'});controller.preview('light');cc({type:'preview',value:'light'});ui.consumeTerminalColorSchemeReport('\x1b[?997;1n');cc({type:'input',data:'\x1b[?997;1n'});controller.dispose();cc({type:'dispose'});th.stopThemeWatcher();


// A missing automatic-pair target falls back system; watcher last-good semantics do not apply here.
th.setTerminalColors({});th.setTerminalColorScheme(undefined);timers=[];now=0;ui.pendingTerminalColorQueries=[];writes.length=0;controller=new InteractiveThemeController(ui,{initialThemeSetting:'missing/dark',getSettingsManager:()=>({getThemeSetting:()=>undefined}),showError:()=>{},onChanged:()=>{}});controller.applyFromSettings();cc({type:'reset',setting:'missing/dark'});
for(const data of [osc('10','#eeeeee'),osc('11','#111111'),da,'\x1b[?997;2n',osc('10','#111111'),osc('11','#eeeeee'),da]){if(!ui.consumeTerminalColorResponse(data))ui.consumeTerminalColorSchemeReport(data);await Promise.resolve();cc({type:'input',data});}
controller.setThemeInstance(th.getThemeByName('dark'));cc({type:'instance',value:'dark'});controller.preview('light');cc({type:'preview',value:'light'});controller.applyTerminalColors({background:{r:17,g:17,b:17}});cc({type:'direct-colors',background:[17,17,17]});controller.dispose();cc({type:'dispose'});th.stopThemeWatcher();

globalThis.setTimeout=realSet;globalThis.clearTimeout=realClear;rmSync(temp,{recursive:true,force:true});
writeFileSync(out,JSON.stringify({reference:{commit:pin,sourceHashes},parsers:parsersCases,queries:cases,watcher,controller:controllerCases},null,2));console.log(`Original: ${parsersCases.length} parsers, ${cases.length} query lifecycles, ${watcher.length} watcher transitions`);
