import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {resolve} from 'node:path';
const root=process.env.PI_REFERENCE_ROOT || resolve(import.meta.dirname,'../../pi-harness-reference');
const path=root+'/packages/tui/src/terminal-image.ts';
const expected='edb88db602610de4737505609b09bf1aedc3881dde5d6d7c2345b7c7f2bacc57';
if(createHash('sha256').update(readFileSync(path)).digest('hex')!==expected) throw Error('Pi image source hash mismatch');
const pi=await import(path);
pi.setCapabilities({images:null,trueColor:true,hyperlinks:false});
const rows=[];
for(const [w,h] of [[1,1],[2,7],[640,480],[1920,1080],[99,310]]) for(const [mw,mh] of [[1,1],[13,7],[60,30],[78,39]]) for(const optimize of [false,true]){
 rows.push({w,h,mw,mh,optimize,expected:pi.calculateImageCellSize({widthPx:w,heightPx:h},mw,mh,{widthPx:9,heightPx:18},optimize)});
}
console.log(JSON.stringify({revision:'2c8d1feb147f6b3d97e855da803bfe7b19f3c403',source_sha256:expected,rows,fallback:[pi.imageFallback('image/png',{widthPx:2,heightPx:2}),pi.imageFallback('image/jpeg')]}));
