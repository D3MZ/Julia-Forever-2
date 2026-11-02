// Source-only xterm normalization for offline actual Buffer assertions.
import {readFileSync,writeFileSync} from 'node:fs';import{pathToFileURL}from'node:url';import{createRequire}from'node:module';import{createHash}from'node:crypto';import{resolve,join}from'node:path';
const [root,input,output,onlyScene,unicodeMode]=process.argv.slice(2),require=createRequire(join(resolve(root),'package.json')),{Terminal}=require('@xterm/headless');
const bytes=readFileSync(input),source=JSON.parse(bytes),sha=x=>createHash('sha256').update(x).digest('hex');const cells=[],map=new Map(),snapshots=[];
let unicodeProvider;
if(unicodeMode==='pi-visible-width'){
 const pinned=source.reference?.sourceHashes; if(!pinned)throw Error('Pinned original source hashes required');
 for(const [file,digest]of Object.entries(pinned))if(sha(readFileSync(join(root,file)))!==digest)throw Error('Source hash mismatch: '+file);
 const {visibleWidth}=await import(pathToFileURL(join(resolve(root),'packages/tui/src/utils.ts')).href);
 // Public xterm Unicode provider interface. Width values come only from pinned original Pi.
 // Combining-property encoding follows xterm's MIT UnicodeService public provider protocol.
 unicodeProvider={version:'pinned-pi-visible-width',wcwidth:cp=>visibleWidth(String.fromCodePoint(cp)),charProperties(cp,preceding){let width=this.wcwidth(cp),join=width===0&&preceding!==0;const old=(preceding>>1)&3;if(join){if(old===0)join=false;else if(old>width)width=old;}return((width&3)<<1)|(join?1:0);}};
}
for(const frame of source.snapshots){if(onlyScene==='scene'&&!frame.id.endsWith('.scene'))continue;const lines=frame.terminalAnsiLines??frame.ansiLines;const terminal=new Terminal({cols:frame.width,rows:Math.max(2,lines.length+1),allowProposedApi:true,disableStdin:true});if(unicodeProvider){terminal.unicode.register(unicodeProvider);terminal.unicode.activeVersion=unicodeProvider.version;}await new Promise(done=>terminal.write(lines.join('\r\n'),done));const rows=[];
 for(let y=0;y<lines.length;y++){const row=[];for(let x=0;x<frame.width;x++){const c=terminal.buffer.active.getLine(y).getCell(x),v=[c.getChars()||' ',c.getWidth(),c.getFgColorMode(),c.getFgColor(),c.getBgColorMode(),c.getBgColor(),!!c.isBold(),!!c.isDim(),!!c.isItalic(),!!c.isUnderline(),!!c.isInverse(),!!c.isStrikethrough(),!!c.isInvisible()],key=JSON.stringify(v);if(!map.has(key)){map.set(key,cells.length+1);cells.push(v);}const id=map.get(key);if(row.length&&row.at(-1)[0]===id)row.at(-1)[1]++;else row.push([id,1]);}rows.push(row);}terminal.dispose();snapshots.push({id:frame.id,width:frame.width,rows});}
writeFileSync(output,JSON.stringify({schemaVersion:1,sourceSha256:sha(bytes),reference:source.reference,normalizer:'@xterm/headless actual cells; source original ANSI only',unicodeProvider:unicodeProvider?.version??'xterm-default-6',normalizerSha256:sha(readFileSync(new URL(import.meta.url))),cellFormat:['text','columns','fgMode','fg','bgMode','bg','bold','dim','italic','underline','inverse','strikethrough','invisible'],cells,snapshots})+'\n');console.log(JSON.stringify({frames:snapshots.length,cells:cells.length,sha256:sha(readFileSync(output))}));
