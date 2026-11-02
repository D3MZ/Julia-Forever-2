// Test-only export adapter for Pi's unchanged private parser. All inputs are synthetic.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {stripTypeScriptTypes} from 'node:module';
import {runInNewContext} from 'node:vm';
const [rootArg,provenanceArg,outputArg]=process.argv.slice(2),root=resolve(rootArg);
const pin='2c8d1feb147f6b3d97e855da803bfe7b19f3c403',sha=data=>createHash('sha256').update(data).digest('hex');
const provenance=JSON.parse(readFileSync(provenanceArg));
assert.equal(execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),pin);
assert.equal(provenance.reference.commit,pin);
const path='packages/ai/src/auth/oauth/openai-chatgpt.ts',source=readFileSync(join(root,path),'utf8');
assert.equal(sha(source),provenance.reference.sourceHashes[path],path);
const constants=source.slice(source.indexOf('const CALLBACK_PORT ='),source.indexOf('const DIRECT_TOKEN_SCOPE ='));
const helpers=source.slice(source.indexOf('function authorizationResultFromCallback('),source.indexOf('function sendHtml('));
assert.ok(constants.includes('const REDIRECT_URI ='));assert.ok(helpers.includes('function authorizationResultFromManualInput('));
const parser=runInNewContext(stripTypeScriptTypes(constants+'\n'+helpers+'\nauthorizationResultFromManualInput;'),{URL});
const state='synthetic-state-only',redirect='http://127.0.0.1:1455/auth/callback';
const valid=redirect+'?code=synthetic-code-only&state='+state+'&client_id=synthetic-client-only';
const cases=[
 ['valid',valid],['trimmed',' \n'+valid+'\t '],['encoded',redirect+'?code=synthetic%2Bcode&state='+state+'&client_id=synthetic%2Dclient'],
 ['missing-code',redirect+'?state='+state+'&client_id=synthetic-client'],['empty-code',valid.replace('synthetic-code-only','')],
 ['missing-state',redirect+'?code=synthetic-code&client_id=synthetic-client'],['wrong-state',valid.replace(state,'wrong-synthetic-state')],
 ['missing-client',redirect+'?code=synthetic-code&state='+state],['empty-client',valid.replace('synthetic-client-only','%20')],
 ['denied',redirect+'?error=access_denied&state='+state],['denied-without-state',redirect+'?error=access_denied'],
 ['wrong-host',valid.replace('127.0.0.1','localhost')],['wrong-port',valid.replace('1455','1456')],['wrong-path',valid.replace('/auth/callback','/callback')],
 ['wrong-scheme',valid.replace('http:','https:')],['malformed','not a url'],['relative','/auth/callback?code=synthetic'],
 ['duplicate-code',valid+'&code=second-synthetic-code'],['duplicate-state',valid+'&state=second-synthetic-state'],
 ['duplicate-client',valid+'&client_id=second-synthetic-client'],['fragment',valid+'#synthetic-fragment'],
 ['userinfo',valid.replace('http://','http://synthetic:synthetic@')],
 ['path-normalization',valid.replace('/auth/callback','/unused/../auth/callback')],
 ['embedded-control',valid.replace('synthetic-code-only','synthetic\ncode')],
 ['oversized-code',valid.replace('synthetic-code-only','x'.repeat(8193))]
].map(([id,input])=>{let result;try{result={ok:true,...parser(input,state)};}catch(error){result={ok:false,reason:error.message};}return{id,input,expectedState:state,redirect,result};});
writeFileSync(outputArg,JSON.stringify({pin,sourceHashes:{[path]:sha(source)},runnerSha256:sha(readFileSync(fileURLToPath(import.meta.url))),helperSha256:sha(helpers),method:'Original private parser sliced unchanged from hash-checked Pi source and exported only inside a no-network VM; synthetic values only. Stricter native security rejections are intentional differences, not a reason to weaken validation.',cases}));
console.log(JSON.stringify({cases:cases.length,accepted:cases.filter(c=>c.result.ok).length,rejected:cases.filter(c=>!c.result.ok).length}));
