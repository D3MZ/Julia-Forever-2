// Exact normalized cell comparison of retained original ANSI and candidate ANSI.
import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
const dir=dirname(fileURLToPath(import.meta.url));
const require=createRequire(join(process.env.PI_REFERENCE ?? join(dir,"pi-harness-reference"),"package.json"));
const {Terminal}=require("@xterm/headless");
const [reference,candidate,output]=process.argv.slice(2);
const rb=readFileSync(reference),cb=readFileSync(candidate),r=JSON.parse(rb),c=JSON.parse(cb);
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const style=cell=>({fg:{mode:cell.getFgColorMode(),value:cell.getFgColor()},bg:{mode:cell.getBgColorMode(),value:cell.getBgColor()},bold:!!cell.isBold(),dim:!!cell.isDim(),italic:!!cell.isItalic(),underline:!!cell.isUnderline(),inverse:!!cell.isInverse(),strikethrough:!!cell.isStrikethrough(),invisible:!!cell.isInvisible()});
async function normalize(frame){const lines=frame.terminalAnsiLines??frame.ansiLines;const t=new Terminal({cols:frame.width,rows:Math.max(2,lines.length+1),allowProposedApi:true,disableStdin:true});await new Promise(done=>t.write(lines.join('\r\n'),done));const rows=lines.map((_,y)=>Array.from({length:frame.width},(_,x)=>{const cell=t.buffer.active.getLine(y).getCell(x);return {text:cell.getChars()||' ',columns:cell.getWidth(),style:style(cell)}}));t.dispose();return rows}
const result={schemaVersion:1,referenceSha256:hash(rb),candidateSha256:hash(cb),method:'actual @xterm/headless per-cell text,width,fg/bg,color mode,flags; unmodified retained reference terminal ANSI vs native candidate ANSI',checked:0,matching:0,differing:0,textDifferentCells:0,widthDifferentCells:0,styleDifferentCells:0,missingFrames:[],failures:[]};
for(const reference of r.snapshots){const candidate=c.snapshots.find(frame=>frame.id===reference.id&&frame.width===reference.width);if(!candidate){result.missingFrames.push({id:reference.id,width:reference.width});continue}const rr=await normalize(reference),cc=await normalize(candidate),diffs=[];result.checked++;for(let y=0;y<Math.max(rr.length,cc.length);y++){for(let x=0;x<reference.width;x++){const a=rr[y]?.[x],b=cc[y]?.[x];if(JSON.stringify(a)!==JSON.stringify(b)){const text=a?.text!==b?.text,columns=a?.columns!==b?.columns,styles=JSON.stringify(a?.style)!==JSON.stringify(b?.style);result.textDifferentCells+=Number(text);result.widthDifferentCells+=Number(columns);result.styleDifferentCells+=Number(styles);diffs.push({x,y,textDifferent:text,widthDifferent:columns,styleDifferent:styles,reference:a,candidate:b})}}}if(diffs.length){result.differing++;result.failures.push({id:reference.id,width:reference.width,referenceRows:rr.length,candidateRows:cc.length,differentCells:diffs.length,differences:diffs})}else result.matching++}
writeFileSync(output,JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({...result,failures:result.failures.map(({differences,...frame})=>frame)}));
