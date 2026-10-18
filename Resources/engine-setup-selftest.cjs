'use strict';
// Fresh-user initialization fixtures use temporary files, a private fake controller,
// deterministic OS effects, and injected validation/network results only.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const http=require('node:http');
const vm=require('node:vm');
const yaml=require('./js-yaml.cjs');
const root=fs.mkdtempSync('/tmp/account-proxy-setup-');fs.chmodSync(root,0o700);
// Load the engine with deterministic OS/process effects. No host routes, network
// interfaces, user configuration, or external binary are consulted by this test.
const fixtureModule={exports:{}};
const fixtureRequire=id=>id==='node:os'?{...require(id),homedir:()=>root,networkInterfaces:()=>({en7:[{address:'192.0.2.7',family:'IPv4',internal:false}]})}:id==='node:child_process'?{
  ...require(id),spawnSync(binary,args){
    if(binary==='/sbin/route')return args.includes('-inet6')?{status:1,stdout:'',stderr:''}:{status:0,stdout:' interface: en7\n',stderr:''};
    if(binary==='/usr/sbin/scutil')return {status:0,stdout:'IPv4 network interface information\n en7 : flags : 0x5 (IPv4,DNS)\n',stderr:''};
    if(args[0]==='-t')return {status:0,stdout:'fixture configuration accepted',stderr:''};
    throw new Error('Unexpected subprocess in fixture: '+binary);
  },spawn(){throw new Error('Unexpected process launch in pure fixture');}
}:require(id);
vm.runInThisContext('(function(require,module,exports,__dirname){'+fs.readFileSync(path.join(__dirname,'engine.js'),'utf8').replace(/^#![^\n]*\n/,'')+'\n})',{filename:'engine-fixture.js'})(fixtureRequire,fixtureModule,fixtureModule.exports,__dirname);
const engine=fixtureModule.exports;
const profile={id:'fresh-user-account',name:'First SOCKS account',accountDescription:'Fixture only',socksURL:'socks5://demo:demo@203.0.113.70:1080'};
const clone=value=>JSON.parse(JSON.stringify(value));
const write=(file,value)=>fs.writeFileSync(file,typeof value==='string'?value:engine.dumpYAML(value),{mode:0o600});

function apiRules(rules){return rules.map(rule=>{
  const parts=rule.split(','),policy=parts.at(-1)==='no-resolve'?parts.at(-2):parts.at(-1);
  const types={'DOMAIN-SUFFIX':'DomainSuffix','DOMAIN':'Domain','MATCH':'Match','NETWORK':'Network','AND':'AND'};
  return {type:types[parts[0]]||parts[0],payload:parts[0]==='AND'?rule:parts[1],proxy:policy};
});}

async function fixture(name,{dnsEnabled=false,multiple=false,multichain=false}={}){
  const directory=path.join(root,name),configDirectory=path.join(directory,'clash'),dataDirectory=path.join(directory,'app');
  fs.mkdirSync(path.join(configDirectory,'profiles'),{recursive:true,mode:0o700});fs.mkdirSync(dataDirectory,{mode:0o700});
  const loc=engine.locations({configDirectory,dataDirectory,socket:path.join(directory,'controller.sock'),core:__filename});
  const base={mode:'rule',ipv6:false,'mixed-port':17977,'external-controller':'','external-controller-unix':'/tmp/fixture-original.sock',
    tun:{enable:false,'auto-route':true,'auto-detect-interface':true,stack:'gvisor','dns-hijack':['any:53']}};
  const raw={proxies:[{name:'Fixture Front',type:'socks5',server:'127.0.0.1',port:9,udp:false}],
    'proxy-groups':[],rules:['DOMAIN-SUFFIX,cn,DIRECT','MATCH,DIRECT']};
  const runtime={...clone(base),...clone(raw),tun:{...base.tun,enable:true},dns:{enable:true,'enhanced-mode':'fake-ip',
    nameserver:['https://dns.alidns.com/dns-query'],'default-nameserver':['223.5.5.5'],
    'proxy-server-nameserver':['https://dns.alidns.com/dns-query'],'nameserver-policy':{'+.corp.example':['10.44.0.53']}}};
  const items=[{uid:'Merge',type:'merge',file:'Merge.yaml'},{uid:'Script',type:'script',file:'Script.js'},
    {uid:'UserRules',type:'rules',file:'user-rules.yaml'},{uid:'UserMerge',type:'merge',file:'user-merge.yaml'},
    {uid:'fixture',type:'remote',name:'Fixture Subscription',file:'subscription.yaml',option:{rules:'UserRules',merge:'UserMerge'}}];
  if(multiple)items.push({uid:'other',type:'local',name:'Other Subscription',file:'other.yaml'});
  if(multichain)items.at(-1).option.script=['Script','SecondScript'];
  write(loc.profilesFile,{current:'fixture',items});write(loc.baseFile,base);
  write(loc.vergeFile,{enable_tun_mode:true,enable_dns_settings:dnsEnabled,profile_dns_settings:{fixture:{enabled:dnsEnabled}}});
  write(loc.runtimeFile,runtime);write(loc.dnsFile,{dns:{nameserver:['https://dns.alidns.com/dns-query']}});
  write(path.join(configDirectory,'profiles/Merge.yaml'),{profile:{'store-selected':true}});
  write(path.join(configDirectory,'profiles/Script.js'),'function main(config, profileName) { config.fixtureMainRuns=(config.fixtureMainRuns||0)+1; return config; }\n');
  write(path.join(configDirectory,'profiles/user-rules.yaml'),{prepend:['DOMAIN,service.internal.example,DIRECT','PROCESS-NAME,MyRemoteTool,DIRECT'],append:[],delete:[]});
  write(path.join(configDirectory,'profiles/user-merge.yaml'),{dns:{'nameserver-policy':{'+.corp.example':['10.44.0.53']}}});
  write(path.join(configDirectory,'profiles/subscription.yaml'),raw);
  let loaded=clone(runtime),reloadCount=0,deleteCount=0;
  const server=http.createServer((request,response)=>{
    let body='';request.on('data',chunk=>body+=chunk);request.on('end',()=>{
      const send=(value,status=200)=>{response.writeHead(status,{'Content-Type':'application/json'});response.end(JSON.stringify(value));};
      if(request.method==='GET'&&request.url==='/configs')return send(loaded);
      if(request.method==='GET'&&request.url==='/rules')return send({rules:apiRules(loaded.rules||[])});
      if(request.method==='GET'&&request.url.startsWith('/proxies/')){
        const group=(loaded['proxy-groups']||[]).find(item=>item.name===decodeURIComponent(request.url.slice(9)));
        return group?send({now:group.proxies[0],all:group.proxies}):send({message:'not found'},404);
      }
      if(request.method==='PUT'&&request.url==='/configs?force=false'){
        loaded=yaml.load(JSON.parse(body).payload);reloadCount++;response.writeHead(204);return response.end();
      }
      if(request.method==='DELETE')deleteCount++;
      send({message:'unexpected fixture request'},500);
    });
  });
  await new Promise(resolve=>server.listen(loc.socket,resolve));
  return {loc,server,get loaded(){return loaded;},get reloadCount(){return reloadCount;},get deleteCount(){return deleteCount;},
    close:()=>new Promise(resolve=>server.close(resolve))};
}

function effects({failVerify=false}={}){
  let preflights=0,verifications=0;
  return {get preflights(){return preflights;},get verifications(){return verifications;},
    preflight:async(loc,prepared)=>{preflights++;assert.deepEqual(prepared.routingContext.managedRelayHosts,[]);return {success:true,ip:'203.0.113.99'};},
    verify:async(loc,options)=>{verifications++;assert.deepEqual(options.relayHosts,[]);return {success:!failVerify,ip:'203.0.113.99',expectedIP:'203.0.113.99',
      scope:options.scope,activeProfileID:options.activeProfileID,checkedAt:new Date().toISOString(),endpoints:[],details:failVerify?'Fixture verification failure':'Fixture network verified'};}
  };
}

async function main(){
  const first=await fixture('direct');
  try{
    const initial=await engine.setupStatus(first.loc);
    assert(initial.canInitialize&&!initial.networkReady&&!initial.isManaged);assert.equal(initial.suggestedDialer,'DIRECT');
    assert(initial.dialerOptions.some(option=>option.id==='Fixture Front'));
    const ctx=engine.resolveContext(first.loc),metadataBefore=fs.readFileSync(first.loc.profilesFile,'utf8'),dnsBefore=fs.readFileSync(first.loc.dnsFile,'utf8');
    const prepared=engine.prepare(first.loc,profile,'servicesOnly',{initialize:true,dialerProxy:'DIRECT'});
    engine.validateCore(first.loc,prepared.candidate);
    assert.equal(prepared.candidate.fixtureMainRuns,1,'Candidate must not run the shared global script twice');
    assert.equal(prepared.candidate.proxies.find(node=>node.name===engine.NODE_NAME)['dialer-proxy'],undefined);
    assert.equal(prepared.writeDNS,false);assert.equal(prepared.routingContext.legacy,false);
    assert(prepared.candidate.rules.includes('PROCESS-NAME,MyRemoteTool,DIRECT'));
    assert.deepEqual(prepared.candidate.dns['nameserver-policy']['+.corp.example'],['10.44.0.53']);
    assert.deepEqual(prepared.routingContext.companyDomains,[]);assert.deepEqual(prepared.routingContext.managedRelayHosts,[]);assert.deepEqual(prepared.routingContext.privateDNSDefaults,{});
    const other=new vm.Script(prepared.script+';main(config,"Other Subscription");').runInNewContext({config:{proxies:[],rules:[]}});
    assert(!other.proxies.some(node=>node.name===engine.NODE_NAME),'Other subscriptions must not inherit the managed node');
    const fx=effects();const applied=await engine.initialize(first.loc,{profile,scope:'servicesOnly',dialerProxy:'DIRECT'},fx);
    assert(applied.success&&applied.networkReady&&applied.initialized);assert.equal(first.reloadCount,1);assert.equal(first.deleteCount,0);
    assert.equal(fs.readFileSync(first.loc.profilesFile,'utf8'),metadataBefore);assert.equal(fs.readFileSync(first.loc.dnsFile,'utf8'),dnsBefore);
    assert((await engine.setupStatus(first.loc)).networkReady);
    const twice=await engine.initialize(first.loc,{profile,scope:'servicesOnly'},fx);assert.equal(twice.initialized,false);assert.equal(fx.preflights,1);assert.equal(first.reloadCount,1);
    const baseline=JSON.parse(fs.readFileSync(path.join(applied.backupPath,'manifest.json')));
    assert(!baseline.files.some(entry=>entry.path===first.loc.dnsFile));
    write(first.loc.dnsFile,{dns:{nameserver:['https://external-change.example/dns-query']}});
    const externalDNS=fs.readFileSync(first.loc.dnsFile,'utf8');await engine.restore(first.loc);
    assert.equal(fs.readFileSync(first.loc.dnsFile,'utf8'),externalDNS,'Restoring script-managed DNS must preserve external shared DNS edits');
    assert.equal(first.deleteCount,0);
  }finally{await first.close();}
  const chained=await fixture('chained',{dnsEnabled:true});
  try{
    const prepared=engine.prepare(chained.loc,profile,'fullPublic',{initialize:true,dialerProxy:'Fixture Front'});
    engine.validateCore(chained.loc,prepared.candidate);assert.equal(prepared.candidate.proxies.find(node=>node.name===engine.NODE_NAME)['dialer-proxy'],'Fixture Front');
    assert(prepared.writeDNS);assert(!prepared.candidate.rules.includes('DOMAIN-SUFFIX,cn,DIRECT'));
    await engine.initialize(chained.loc,{profile,scope:'fullPublic',dialerProxy:'Fixture Front'},effects());
    assert((await engine.setupStatus(chained.loc)).networkReady);
  }finally{await chained.close();}
  const failed=await fixture('failed');
  try{
    const ctx=engine.resolveContext(failed.loc),files=[ctx.scriptFile,failed.loc.runtimeFile,failed.loc.dnsFile,failed.loc.profilesFile];
    const before=Object.fromEntries(files.map(file=>[file,engine.sha(fs.readFileSync(file))]));
    await assert.rejects(engine.initialize(failed.loc,{profile,scope:'servicesOnly',dialerProxy:'DIRECT'},effects({failVerify:true})),/已自动恢复/);
    for(const[file,hash]of Object.entries(before))assert.equal(engine.sha(fs.readFileSync(file)),hash);
    assert(!fs.existsSync(failed.loc.stateFile));assert(!fs.existsSync(failed.loc.journalFile));assert.equal(failed.deleteCount,0);
  }finally{await failed.close();}
  const multi=await fixture('multi',{dnsEnabled:true,multiple:true});
  try{const setup=await engine.setupStatus(multi.loc);assert(!setup.canInitialize);assert(setup.checks.some(check=>check.id==='dnsScope'&&!check.ready));}
  finally{await multi.close();}
  const chain=await fixture('multi-chain',{multichain:true});
  try{assert(!(await engine.setupStatus(chain.loc)).canInitialize);}finally{await chain.close();}
  console.log('PASS: 首次初始化（无组/节点、无专用脚本绑定、DNS覆盖关闭）、直连/前置、通用/旧环境隔离、幂等、失败回滚、共享DNS外部变更保护、多订阅与多段链边界；纯临时配置与注入检查结果，不读取用户配置。');
}
main().catch(error=>{console.error(error.stack);process.exitCode=1;}).finally(()=>fs.rmSync(root,{recursive:true,force:true}));
