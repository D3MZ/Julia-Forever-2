// Original Pi is a pinned, source-checked test oracle only. No provider or external I/O.
import assert from'node:assert/strict';import{readFileSync,writeFileSync}from'node:fs';import{join,resolve}from'node:path';import{pathToFileURL}from'node:url';import{createHash}from'node:crypto';import{execFileSync}from'node:child_process';
import{createGraphemeTerminal,graphemeTerminalProfile,graphemeScreen}from'./terminal_grapheme_profile.mjs';
const[rootArg,output]=process.argv.slice(2),root=resolve(rootArg),pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403';
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),pin);const hashes={};
for(const p of ['packages/tui/src/tui.ts','packages/tui/src/tui-alt-screen.ts','packages/tui/src/utils.ts','packages/tui/src/components/text.ts']){const b=readFileSync(join(root,p));assert(b.equals(execFileSync('git',['-C',root,'show',`${pin}:${p}`])));hashes[p]=createHash('sha256').update(b).digest('hex');}
globalThis.fetch=()=>{throw Error('Network forbidden in grapheme oracle')};await import(pathToFileURL(join(root,'packages/coding-agent/src/experimental/source-resolver.ts')));
const{Text,TuiAltScreen,setCapabilityOverrides,visibleWidth}=await import(pathToFileURL(join(root,'packages/tui/src/index.ts')));setCapabilityOverrides({images:false,hyperlinks:false});
const cases=[];
for(const glyph of ['👩‍💻','👨‍👩‍👧‍👦','👍🏽','✈️','🇨🇦','🙂','é','界']){
 const writes=[],terminal={columns:24,rows:4,write:data=>writes.push(data),hideCursor(){this.write('\x1b[?25l');},showCursor(){this.write('\x1b[?25h');},stop(){},start(){},moveBy(){}};
 const ui=new TuiAltScreen(terminal,false,undefined,{mouse:false});const text=new Text('',0,0);ui.addChild(text);const steps=[];
 const specs=[['initial',glyph+(glyph==='👨‍👩‍👧‍👦'?'      ':'  ')+'X',24],['unchanged',glyph+(glyph==='👨‍👩‍👧‍👦'?'      ':'  ')+'X',24],['gap',glyph+'      X',24],['contiguous',glyph+'X',24],['replaced','     Y',24],['multiline',glyph+'  Z\nA'+glyph+' B',24],['colored','\x1b[38;2;230;30;20m'+glyph+'  X\x1b[39m',24],['resize',glyph+'  X',8],['edge','123456'+glyph,8],['empty','',8]];
 const emulator=createGraphemeTerminal(24,4);ui.start();let captured=0;
 for(const[name,value,width]of specs){terminal.columns=width;emulator.resize(width,4);text.setText(value);ui.renderNow();const bytes=writes.slice(captured).join('');captured=writes.length;await new Promise(done=>emulator.write(bytes,done));steps.push({name,text:value,width,height:4,writes:bytes,lines:text.render(width),cellsSha256:createHash('sha256').update(JSON.stringify(graphemeScreen(emulator))).digest('hex')});}
 cases.push({glyph,width:visibleWidth(glyph),steps});ui.stop();emulator.dispose();
}
const wraps=[];
for(const glyph of ['👩‍💻','👨‍👩‍👧‍👦','👍🏽','✈️','🇨🇦','🙂','é','界'])for(const width of [6,8,12])for(const text of [glyph.repeat(5)+'X','A'+glyph+' '+glyph+' B']){
 wraps.push({text,width,padding:1,lines:new Text(text,1,0).render(width)});
}
writeFileSync(output,JSON.stringify({pin,hashes,terminalProfile:graphemeTerminalProfile,method:'Original TuiAltScreen.renderNow over original Text with persistent emulator state after every update; no provider/auth calls',cases,wraps},null,2));console.log(JSON.stringify({cases:cases.length,transitions:cases.reduce((n,c)=>n+c.steps.length,0),wraps:wraps.length}));
