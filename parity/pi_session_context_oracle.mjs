// Test-only oracle: original Pi (MIT, copyright Mario Zechner), never a production runtime.
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {join} from 'node:path';
const root=process.env.PI_SOURCE_ROOT;
const pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403';
if(!root||execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim()!==pin) throw Error('Exact original Pi checkout required');
const hashes={
 'packages/coding-agent/src/core/session-manager.ts':'51398209d139707e18c7c2d33a8225813d7db1337800631be410b0aca412e597',
 'packages/coding-agent/src/core/messages.ts':'5397e3c96c9504266e4ee8b6e88d5098b3280ee7dbb0c687b74708c62a06c8d4'
};
for(const [path,hash] of Object.entries(hashes)){
 if(createHash('sha256').update(readFileSync(join(root,path))).digest('hex')!==hash||createHash('sha256').update(execFileSync('git',['-C',root,'show',`${pin}:${path}`])).digest('hex')!==hash) throw Error('Original Pi source hash mismatch');
}
globalThis.fetch=()=>{throw Error('Network forbidden in session context oracle')};
const {buildSessionContext,buildSessionProjection}=await import(root+'/packages/coding-agent/src/core/session-manager.ts');
const {convertToLlm}=await import(root+'/packages/coding-agent/src/core/messages.ts');
const stamp='2026-11-01T21:00:00.123Z';
const user=(text)=>({role:'user',content:[{type:'text',text}],timestamp:1793566800123});
const assistant=(text)=>({role:'assistant',content:[{type:'text',text}],api:'openai-responses',provider:'openai',model:'fixture',timestamp:1793566800123,usage:{input:2,output:3},stopReason:'stop'});
const msg=(id,parentId,message)=>({type:'message',id,parentId,timestamp:stamp,message});
const entry=(id,parentId,type,payload)=>({type,id,parentId,timestamp:stamp,...payload});
const base=[
 msg('system',null,{role:'system',content:'Original system',timestamp:1793566800123}),
 entry('thinking','system','thinking_level_change',{thinkingLevel:'high'}),
 entry('model','thinking','model_change',{provider:'openai',modelId:'before'}),
 msg('u1','model',user('U1')),
 msg('a1','u1',assistant('A1')),
 msg('u2','a1',user('U2')),
 msg('a2','u2',assistant('A2'))
];
const compact=[...base,entry('c1','a2','compaction',{summary:'Summary 1',tokensBefore:120,firstKeptEntryId:'u2',systemMessage:{role:'system',content:'System checkpoint',timestamp:1793566800123},details:{opaque:[1,true,null]}}),
 entry('edit1','c1','context_edit',{targetId:'u2',replacement:{content:'Edited U2'}}),
 entry('edit2','edit1','context_edit',{targetId:'a2',replacement:{content:'Edited A2'}}),
 entry('u3','edit2','message',{message:user('U3')})];
const rich=[...base,
 entry('state','a2','custom',{customType:'opaque.state',data:{secret:false}}),
 entry('visible','state','custom_message',{customType:'display',content:'Visible custom',display:true,details:{source:'fixture'}}),
 entry('hidden','visible','custom_message',{customType:'hidden',content:[{type:'text',text:'Hidden but in context'}],display:false}),
 msg('bash','hidden',{role:'bashExecution',command:'printf hi',output:'hi',exitCode:3,cancelled:false,truncated:true,fullOutputPath:'/tmp/fixture.txt',timestamp:1793566800123}),
 msg('bashhidden','bash',{role:'bashExecution',command:'ignored',output:'secret',cancelled:true,truncated:false,excludeFromContext:true,timestamp:1793566800123}),
 msg('images','bashhidden',{role:'user',content:[{type:'text',text:'See image'},{type:'image',data:'AQID',mimeType:'image/png'}],timestamp:1793566800123}),
 msg('tools','images',{...assistant(''),content:[{type:'thinking',thinking:'Reasoning',thinkingSignature:'opaque-signature'},{type:'toolCall',id:'call1',name:'read',arguments:{path:'fixture'}}]}),
 msg('result','tools',{role:'toolResult',toolCallId:'call1',toolName:'read',content:[{type:'text',text:'result'}],isError:false,timestamp:1793566800123}),
 entry('branch','result','branch_summary',{fromId:'a1',summary:'Other branch',details:{preserve:true}}),
 entry('empty-summary','branch','branch_summary',{fromId:'a1',summary:''})];
const cases=[
 {name:'empty',entries:[],leaf:null},
 {name:'plain',entries:base},
 {name:'root-selection',entries:base,leaf:null},
 {name:'earlier-branch',entries:[...base,entry('othermodel','a1','model_change',{provider:'anthropic',modelId:'other'})],leaf:'a1'},
 {name:'compaction-edits',entries:compact},
 {name:'nested-compaction',entries:[...compact,entry('c2','u3','compaction',{summary:'Summary 2',tokensBefore:180,firstKeptEntryId:'c1'}),msg('u4','c2',user('U4'))]},
 {name:'self-boundary',entries:[...compact,entry('c2','u3','compaction',{summary:'Everything summarized',tokensBefore:180,firstKeptEntryId:'c2'})]},
 {name:'kept-system-suppressed',entries:[...base,entry('c1','a2','compaction',{summary:'Checkpoint',tokensBefore:120,firstKeptEntryId:'system'}),msg('system2','c1',{role:'system',content:'Later system'})]},
 {name:'offbranch-boundary',entries:[...base,msg('off','a1',user('Other branch')),entry('c1','a2','compaction',{summary:'Checkpoint',tokensBefore:120,firstKeptEntryId:'off'})]},
 {name:'latest-edit-wins',entries:[...compact,entry('edit3','u3','context_edit',{targetId:'u2',replacement:null}),entry('edit4','edit3','context_edit',{targetId:'a2',replacement:{content:[{type:'text',text:'Final A2'}]}})]},
 {name:'discarded-edit-not-active',entries:[...base,entry('earlyedit','a2','context_edit',{targetId:'u2',replacement:null}),entry('c1','earlyedit','compaction',{summary:'Checkpoint',tokensBefore:120,firstKeptEntryId:'a2'})]},
 {name:'rich',entries:rich},
 {name:'custom-edit',entries:[...rich,entry('edit','empty-summary','context_edit',{targetId:'hidden',replacement:{content:'Now changed'}})]},
 {name:'null-content-repair',entries:[msg('s',null,{role:'system',content:null}),msg('u','s',{role:'user'}),msg('a','u',{role:'assistant',content:null,provider:'p',model:'m'}),msg('t','a',{role:'toolResult',content:null,toolCallId:'x',toolName:'x'}),entry('custom','t','custom_message',{customType:'old',display:false})]},
 {name:'bash-cancelled-empty',entries:[msg('bash',null,{role:'bashExecution',command:'false',output:'',exitCode:1,cancelled:true,truncated:true,fullOutputPath:'/tmp/fixture',timestamp:1793566800123})]},
 {name:'settings-before-discarded-prefix',entries:[...base,entry('low','a2','thinking_level_change',{thinkingLevel:'low'}),entry('changed','low','model_change',{provider:'anthropic',modelId:'later'}),entry('c','changed','compaction',{summary:'All',tokensBefore:300,firstKeptEntryId:'c'})]},
 {name:'empty-summary-compaction',entries:[...base,entry('c','a2','compaction',{summary:'',tokensBefore:0,firstKeptEntryId:'c'})]},
 {name:'pre-epoch-timestamp',entries:[{...entry('b',null,'branch_summary',{fromId:'root',summary:'Old'}),timestamp:'1969-12-31T23:59:59.999Z'}]},
 {name:'offbranch-context-edit',entries:[...base,entry('e','a2','context_edit',{targetId:'u1',replacement:null}),msg('alternative','a1',user('Alternative'))]},
 {name:'compaction-omitted-by-edit',entries:[...compact,entry('e','u3','context_edit',{targetId:'c1',replacement:null})]}
];
for(const fixture of cases){
 fixture.expected={context:buildSessionContext(fixture.entries,fixture.leaf),projection:buildSessionProjection(fixture.entries,fixture.leaf)};
 fixture.expected.llm=convertToLlm(fixture.expected.context.messages);
}
writeFileSync(process.argv[2],JSON.stringify({schemaVersion:1,pin,hashes,cases},null,2)+'\n');
