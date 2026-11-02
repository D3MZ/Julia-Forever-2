import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {join} from 'node:path';
const root=process.env.PI_SOURCE_ROOT;
if(!root) throw Error('Set PI_SOURCE_ROOT to the exact pinned original checkout');
const pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403';
if(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim()!==pin) throw Error('Original Pi revision mismatch');
const paths=['packages/coding-agent/src/core/session-manager.ts','packages/coding-agent/src/core/session-export.ts'];
const expectedHashes={
 'packages/coding-agent/src/core/session-manager.ts':'51398209d139707e18c7c2d33a8225813d7db1337800631be410b0aca412e597',
 'packages/coding-agent/src/core/session-export.ts':'8ec53e13bd4bc9097e4f7640e2fd2e58ffbbdcadce6df5efdf5cb5622f98d285'
};
const sourceHashes=Object.fromEntries(paths.map(p=>[p,createHash('sha256').update(readFileSync(join(root,p))).digest('hex')]));
for(const p of paths){if(sourceHashes[p]!==expectedHashes[p]) throw Error('Untrusted source hash');const original=execFileSync('git',['-C',root,'show',`${pin}:${p}`]);if(createHash('sha256').update(original).digest('hex')!==sourceHashes[p]) throw Error('Modified upstream source');}
globalThis.fetch=()=>{throw Error('Network forbidden in session oracle')};
const {SessionManager,migrateSessionEntries,assertValidSessionId}=await import(root+'/packages/coding-agent/src/core/session-manager.ts');
const {serializeSessionBranch}=await import(root+'/packages/coding-agent/src/core/session-export.ts');
const temp=mkdtempSync('/tmp/jf2-pi-timeline-');
const stamp='2026-11-01T20:00:00.000Z';
const header={type:'session',version:3,id:'11111111-1111-4111-8111-111111111111',timestamp:stamp,cwd:'/tmp'};
const user=(text)=>({role:'user',content:[{type:'text',text}],timestamp:1793563200000});
const assistant={role:'assistant',content:[{type:'text',text:'A1'},{type:'thinking',thinking:'opaque',thinkingSignature:'sig'}],api:'openai-responses',provider:'openai',model:'fixture',usage:{input:2,output:3},stopReason:'stop',timestamp:1793563200001};
const rows=[header,
 {type:'message',id:'u1',parentId:null,timestamp:stamp,message:user('U1')},
 {type:'message',id:'a1',parentId:'u1',timestamp:stamp,message:assistant,extra:{preserve:[1,'two',{v:true}]}},
 {type:'custom',id:'c1',parentId:'a1',timestamp:stamp,customType:'fixture.opaque',data:{nested:[null,true,'λ']}},
 {type:'message',id:'u2',parentId:'c1',timestamp:stamp,message:user('U2')},
 {type:'message',id:'a2',parentId:'u2',timestamp:stamp,message:{...assistant,content:[{type:'text',text:'A2'}]}},
 {type:'label',id:'l1',parentId:'a2',timestamp:stamp,targetId:'u1',label:'bookmark'},
 {type:'session_info',id:'n1',parentId:'l1',timestamp:stamp,name:'Example session'}
];
const source=join(temp,'source.jsonl');writeFileSync(source,rows.map(JSON.stringify).join('\n')+'\n');
let counter=0;const load=()=>{const path=join(temp,`case-${++counter}.jsonl`);writeFileSync(path,readFileSync(source));return SessionManager.open(path,temp);};
const base=load();
const snapshots={initial:{branch:base.getBranch().map(x=>x.id),name:base.getSessionName(),label:base.getLabel('u1')}};
base.branch('a1');
const childId=base.appendMessage(user('Alternative'));
snapshots.branch={retainedIds:base.getEntries().slice(0,rows.length-1).map(x=>x.id),branch:base.getBranch().map(x=>x.id===childId?'new':x.id),parent:base.getEntry(childId).parentId};
const fork=load();const forkSource=fork.getSessionFile();fork.createBranchedSession('c1');
snapshots.forkBefore={contents:fork.getBranch().filter(x=>x.type!=='label').map(x=>x.type==='message'?x.message:x),ids:fork.getBranch().filter(x=>x.type!=='label').map(x=>x.id),label:fork.getLabel('u1'),freshId:fork.getSessionId()!==header.id,parent:fork.getHeader().parentSession===forkSource};
const clone=load();clone.createBranchedSession('n1');
snapshots.clone={ids:clone.getBranch().filter(x=>x.type!=='label').map(x=>x.id),labels:clone.getBranch().filter(x=>x.type==='label').map(x=>({targetId:x.targetId,label:x.label})),name:clone.getSessionName(),freshId:clone.getSessionId()!==header.id};
const exp=load();const text=serializeSessionBranch(exp);const exportRows=text.trim().split('\n').map(JSON.parse);
snapshots.export={headerIdentity:{id:exportRows[0].id,cwd:exportRows[0].cwd,version:exportRows[0].version},entries:exportRows.slice(1)};
const named=load();named.appendSessionInfo('  First\r\nSecond  ');const normalized=named.getSessionName();named.appendSessionInfo('   ');snapshots.names={normalized,cleared:named.getSessionName()??null};
const v1=structuredClone(rows.slice(0,4));delete v1[0].version;v1[0].id='safe-custom.session_1';for(const row of v1.slice(1)){delete row.id;delete row.parentId;}v1.push({type:'compaction',timestamp:stamp,summary:'earlier',firstKeptEntryIndex:2,tokensBefore:2});migrateSessionEntries(v1);
const v1Ids=v1.slice(1).map(row=>row.id);snapshots.legacy={version:v1[0].version,id:v1[0].id,parents:v1.slice(1).map(row=>row.parentId===null?null:v1Ids.indexOf(row.parentId)+1),firstKeptIndex:v1Ids.indexOf(v1.at(-1).firstKeptEntryId)+1,extra:v1[2].extra};
assertValidSessionId('safe-custom.session_1');
const rich=load();
const bash={role:'bashExecution',command:'printf ok',output:'ok',exitCode:0,cancelled:false,truncated:false,timestamp:1793563200000,excludeFromContext:true};
const bashId=rich.appendMessage(bash);
const editId=rich.appendContextEdit('a1',{content:'Revised'});
const hideId=rich.appendContextEdit('u2',null);
const normalizeEntry=(entry)=>{const result=structuredClone(entry);delete result.id;delete result.parentId;delete result.timestamp;return result;};
const rejects=(fn)=>{try {fn();return false;} catch {return true;}};
snapshots.rich={bash:rich.getEntry(bashId).message,edit:normalizeEntry(rich.getEntry(editId)),hide:normalizeEntry(rich.getEntry(hideId)),rejectsBashEdit:rejects(()=>rich.appendContextEdit(bashId,{content:'not editable'})),rejectsBadContent:rejects(()=>rich.appendContextEdit('u1',{content:42}))};
rich.branch('a1');snapshots.rich.rejectsOffBranchEdit=rejects(()=>rich.appendContextEdit('u2',null));
const treeRows=[header,rows[1],{...rows[2],id:'late',parentId:'u1',timestamp:'2026-11-01T20:00:00.100Z'},{...rows[2],id:'early',parentId:'u1',timestamp:'2026-11-01T20:00:00Z'}];
const treeFile=join(temp,'tree.jsonl');writeFileSync(treeFile,treeRows.map(JSON.stringify).join('\n')+'\n');
snapshots.tree={initial:load().getTree(),fixture:treeRows,ordered:SessionManager.open(treeFile,temp).getTree()};
const result={schemaVersion:1,pin,sourceHashes,fixture:rows,snapshots};
writeFileSync(process.argv[2],JSON.stringify(result,null,2)+'\n');rmSync(temp,{recursive:true,force:true});
