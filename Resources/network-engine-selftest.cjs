#!/usr/bin/env node
'use strict';

// Post-implementation ownership regressions. Every state file and backend is a
// synthetic fixture; these checks never contact a real helper or Clash core.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const engine = require('./network-engine.js');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ccmiss-mux-selftest-'));
let passed = 0;

function fixture(name, {clash = true, helper = {running:false,tunEnabled:false,dnsRestorationPending:false}} = {}) {
  const directory = path.join(root, name);
  fs.mkdirSync(directory, {recursive:true, mode:0o700});
  const own = {stateFile:path.join(directory,'own-state.json'), journalFile:path.join(directory,'own-journal.json'), configFile:path.join(directory,'own-config.json')};
  const shared = {stateFile:path.join(directory,'shared-state.json'), journalFile:path.join(directory,'shared-journal.json')};
  const calls = [];
  const mark = (operation, request) => { calls.push({operation,request}); return {operation,request}; };
  const independent = {locations:()=>own, dispatch:async request=>mark('standalone.dispatch', request)};
  const common = {locations:()=>shared, detect:async()=>{calls.push({operation:'detect'});return clash;}};
  for (const method of ['status','setupStatus','apply','preview','preflight','verify','useSystemProxy']) {
    common[method] = async (loc, request) => { assert.equal(loc,shared);return mark('coexist.'+method,request); };
  }
  const options = {standalone:independent,coexist:common,standaloneLocations:own,coexistLocations:shared,
    helperStatus:async()=>{calls.push({operation:'helper.status'});if(helper instanceof Error)throw helper;return helper;}};
  return {own,shared,calls,options,write:(file,value)=>fs.writeFileSync(file,JSON.stringify(value),{mode:0o600})};
}
function error(code) { return Object.assign(new Error('synthetic helper failure'),{code}); }
async function test(name, callback) { await callback(); passed++; }

(async()=>{
  await test('idle helper cooperates with Clash',async()=>{
    const f=fixture('idle');assert.equal((await engine.selectBackend(f.options)).kind,'clashCoexist');
  });
  await test('no Clash and no installed helper selects independent setup',async()=>{
    const f=fixture('absent',{clash:false,helper:error('ENOENT')});assert.equal((await engine.selectBackend(f.options)).kind,'standalone');
  });
  for(const code of ['ECONNREFUSED','ETIMEDOUT','owner_mismatch'])await test('unknown helper '+code+' blocks changes',async()=>{
    const f=fixture('unknown-'+code,{helper:error(code)});await assert.rejects(engine.dispatch({operation:'apply',profile:{}},f.options),/无法确认/);assert(!f.calls.some(x=>x.operation==='coexist.apply'));
  });
  await test('local independent session never migrates automatically',async()=>{
    const f=fixture('own-active',{helper:error('ETIMEDOUT')});f.write(f.own.stateFile,{activeProfileID:'own',generation:'one'});
    assert.equal((await engine.selectBackend(f.options)).kind,'standalone');assert.equal(f.calls.length,0);
  });
  await test('orphan independent configuration retains independent ownership',async()=>{
    const f=fixture('own-orphan');f.write(f.own.configFile,{fixture:true});assert.equal((await engine.selectBackend(f.options)).kind,'standalone');
  });
  await test('old helper generation with a matching confirmed stop is inactive',async()=>{
    const f=fixture('old-stopped',{helper:{running:false,tunEnabled:false,dnsRestorationPending:false,generation:'old',ownerUID:process.getuid()}});
    f.write(f.own.stateFile,{proxyMode:'system',generation:null,stoppedAt:'fixture',systemProxyConfirmedAt:'fixture',stoppedGeneration:'old'});f.write(f.own.configFile,{fixture:true});
    assert.equal((await engine.selectBackend(f.options)).kind,'clashCoexist');
  });
  await test('old generation without a confirmed stop remains owned',async()=>{
    const f=fixture('old-unproven',{helper:{running:false,generation:'old',ownerUID:process.getuid()}});assert.equal((await engine.selectBackend(f.options)).kind,'standalone');
  });
  await test('unmatched generation cannot borrow another stop confirmation',async()=>{
    const f=fixture('old-mismatch',{helper:{running:false,generation:'new',ownerUID:process.getuid()}});
    f.write(f.own.stateFile,{proxyMode:'system',systemProxyConfirmedAt:'fixture',stoppedGeneration:'old'});assert.equal((await engine.selectBackend(f.options)).kind,'standalone');
  });
  for(const field of ['running','tunEnabled','dnsRestorationPending','desiredActive','resumePending'])await test('helper '+field+' retains independent ownership',async()=>{
    const f=fixture('helper-'+field,{helper:{[field]:true}});assert.equal((await engine.selectBackend(f.options)).kind,'standalone');
  });
  await test('two pending local owners require recovery',async()=>{
    const f=fixture('dual');f.write(f.own.stateFile,{activeProfileID:'own'});f.write(f.shared.stateFile,{activeProfileID:'shared'});await assert.rejects(engine.selectBackend(f.options),/两种网络模式/);
  });
  await test('existing coexist status stays on that backend during outages',async()=>{
    const f=fixture('coexist-status',{clash:false,helper:error('ETIMEDOUT')});f.write(f.shared.stateFile,{activeProfileID:'shared'});
    const r=await engine.dispatch({operation:'status'},f.options);assert.equal(r.operation,'coexist.status');assert(!f.calls.some(x=>x.operation==='helper.status'||x.operation==='standalone.dispatch'));
  });
  await test('coexist journal keeps recovery on the same backend',async()=>{
    const f=fixture('coexist-journal',{clash:false});f.write(f.shared.journalFile,{backupPath:'synthetic'});
    assert.equal((await engine.selectBackend({...f.options,operation:'setupStatus'})).kind,'clashCoexist');
  });
  await test('coexist mutation cannot overlook an active foreign helper',async()=>{
    const f=fixture('coexist-foreign',{helper:{running:true,tunEnabled:true,generation:'foreign',ownerUID:9999}});f.write(f.shared.stateFile,{activeProfileID:'shared'});
    await assert.rejects(engine.dispatch({operation:'apply',profile:{}},f.options),/仍在运行|等待恢复/);assert(!f.calls.some(x=>x.operation==='coexist.apply'));
  });
  await test('coexist mutation cannot overlook an unreadable helper',async()=>{
    const f=fixture('coexist-unknown',{helper:error('owner_mismatch')});f.write(f.shared.stateFile,{activeProfileID:'shared'});
    await assert.rejects(engine.dispatch({operation:'useSystemProxy'},f.options),/无法确认/);assert(!f.calls.some(x=>x.operation==='coexist.useSystemProxy'));
  });
  await test('coexist apply forces specified services',async()=>{
    const f=fixture('coexist-apply');const r=await engine.dispatch({operation:'apply',profile:{id:'fixture'}},f.options);
    assert.equal(r.operation,'coexist.apply');assert.equal(r.request.scope,'servicesOnly');assert(!f.calls.some(x=>x.operation==='standalone.dispatch'));
  });
  await test('coexist rejects a full public takeover',async()=>{
    const f=fixture('coexist-full');await assert.rejects(engine.dispatch({operation:'apply',scope:'fullPublic'},f.options),/仅支持指定服务/);assert(!f.calls.some(x=>x.operation==='coexist.apply'));
  });
  await test('release dispatch never stops the independent engine',async()=>{
    const f=fixture('coexist-release');f.write(f.shared.stateFile,{activeProfileID:'shared'});const r=await engine.dispatch({operation:'useSystemProxy'},f.options);
    assert.equal(r.operation,'coexist.useSystemProxy');assert(!f.calls.some(x=>x.operation==='standalone.dispatch'));
  });
  await test('saving upstream does not select or apply a network backend',async()=>{
    const f=fixture('save-upstream',{helper:error('ETIMEDOUT')});const r=await engine.dispatch({operation:'configureUpstream',url:'socks5://fixture:placeholder@192.0.2.8:20001'},f.options);
    assert.equal(r.operation,'standalone.dispatch');assert.deepEqual(f.calls.map(x=>x.operation),['standalone.dispatch']);
  });
  await test('invalid state yields a fixed error without state contents',async()=>{
    const f=fixture('bad-state');fs.writeFileSync(f.own.stateFile,'{"password":"fixture-secret",');await assert.rejects(engine.selectBackend(f.options),e=>!e.message.includes('fixture-secret')&&/状态文件/.test(e.message));
  });
  await test('known proxy credentials are removed from errors',async()=>{
    const uri='socks5://fixture-user:fixture-password@192.0.2.7:20001',uuid='11111111-2222-4333-8444-555555555555';
    const request={profile:{socksURL:uri},url:'vless://'+uuid+'@192.0.2.8:443?security=reality',password:'fixture-field'};
    const result=engine.safeError(new Error(uri+' fixture-user fixture-password '+uuid+' fixture-field password:unregistered-value'),request);
    for(const secret of [uri,'fixture-user','fixture-password',uuid,'fixture-field','unregistered-value'])assert(!result.includes(secret));
  });
  await test('malformed CLI JSON cannot echo credential fragments',async()=>{
    const child=spawnSync(process.execPath,[path.join(__dirname,'network-engine.js')],{input:'{"operation":"apply","profile":{"socksURL":"socks5://fixture:cli-secret@192.0.2.8:20001"},',encoding:'utf8',timeout:5000});
    assert.equal(child.status,1);const reply=JSON.parse(child.stdout);assert.equal(reply.ok,false);assert.equal(reply.error,'请求 JSON 格式错误。');assert(!child.stdout.includes('cli-secret'));assert.equal(child.stderr,'');
  });
  console.log('PASS: '+passed+' network backend ownership and secret-error checks; isolated fixtures only, no real network/helper/settings access.');
})().catch(e=>{console.error(e.stack);process.exitCode=1;}).finally(()=>fs.rmSync(root,{recursive:true,force:true}));
