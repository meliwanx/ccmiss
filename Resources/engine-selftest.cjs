'use strict';
// Pure utility fixtures: no user files, controller sockets, network probes, or cores.
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const engine=require('./engine.js');
const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'ccmiss-legacy-utilities-'));
fs.chmodSync(temporary,0o700);
try {
  const interfaces={en7:[{address:'192.0.2.7',family:'IPv4',internal:false}],utun9:[{address:'198.18.0.1',family:'IPv4',internal:false}],lo0:[{address:'127.0.0.1',family:'IPv4',internal:true}]};
  assert.equal(engine.selectPreflightInterface({routeOutput:' interface: en7\n',interfaces}),'en7');
  assert.equal(engine.selectPreflightInterface({routeOutput:' interface: utun9\n',nwiOutput:'IPv4 network interface information\n en7 : flags : 0x5 (IPv4,DNS)\n',interfaces}),'en7');
  assert.equal(engine.selectPreflightInterface({routeOutput:' interface: utun9\n',configuredInterface:'en7',interfaces}),'en7');
  assert.throws(()=>engine.selectPreflightInterface({routeOutput:' interface: utun9\n',interfaces:{utun9:interfaces.utun9,lo0:interfaces.lo0}}));

  const write=(name,value)=>{const file=path.join(temporary,name);fs.writeFileSync(file,typeof value==='string'?value:engine.dumpYAML(value),{mode:0o600});return file;};
  const base={mode:'rule',ipv6:false,tun:{enable:true,'auto-route':true},'mixed-port':17977};
  const runtime={...base,dns:{enable:true,nameserver:['https://resolver.example/dns-query'],'proxy-server-nameserver':['https://resolver.example/dns-query'],'nameserver-policy':{'+.corp.example':['10.44.0.53'],'service.example':['https://resolver.example/dns-query']}},proxies:[],'proxy-groups':[],rules:['MATCH,DIRECT']};
  const rawFile=write('subscription.yaml',runtime),emptyFile=write('empty.yaml',{});
  const rulesFile=write('rules.yaml',{prepend:['DOMAIN,service.example,DIRECT','PROCESS-NAME,ExampleTool,DIRECT'],append:[],delete:[]});
  const scriptFile=write('script.js','function main(config) { return config; }\n');
  const ctx={rawFile,rulesFile,proxiesFile:emptyFile,groupsFile:emptyFile,mergeFile:emptyFile,globalMergeFile:emptyFile,scriptFile,globalScriptFile:scriptFile,base,verge:{enable_tun_mode:true},runtime,dns:{dns:runtime.dns},current:{name:'Fixture subscription'}};
  const loc=engine.locations({configDirectory:temporary,dataDirectory:path.join(temporary,'app'),socket:path.join(temporary,'unused.sock'),core:path.join(temporary,'unused-core')});
  const before=Object.fromEntries([rawFile,emptyFile,rulesFile,scriptFile].map(file=>[file,engine.sha(fs.readFileSync(file))]));
  const examples=[{socksURL:'socks5://demo:demo@203.0.113.10:1080'},{socksURL:'socks5://user%40example:p%3A%40%2F%25@198.51.100.7:20001'}];
  assert.deepEqual(engine.MANAGED_RELAY_HOSTS,[]);
  assert.deepEqual(engine.COMPANY_DOMAINS,[]);
  assert.deepEqual(engine.MANAGEMENT_DIRECT_RULES,[]);
  assert.deepEqual(engine.GENERIC_ROUTING_CONTEXT.privateDNSDefaults,{});
  for(const scope of ['fullPublic','servicesOnly']) {
    const context=engine.GENERIC_ROUTING_CONTEXT,dnsConfig=engine.makeDNS(ctx,scope,context),direct=engine.customDirectRules(ctx,context);
    assert.deepEqual(dnsConfig.dns['nameserver-policy']['+.corp.example'],['10.44.0.53']);
    assert.deepEqual(dnsConfig.dns['proxy-server-nameserver'],runtime.dns['proxy-server-nameserver']);
    assert(dnsConfig.dns.nameserver.every(value=>value.endsWith('#'+engine.GROUP_NAME)));
    const settings={scope,node:engine.parseSOCKS(examples[0]),connectionMode:'direct',dialerProxy:null,allowLegacyUSFallback:false,serviceDomains:context.serviceDomains,companyDomains:context.companyDomains,privateRanges:engine.PRIVATE_RANGES,customDirectRules:direct,managedRelayHosts:context.managedRelayHosts,managementDirectRules:context.managementDirectRules,dns:dnsConfig.dns};
    const script=engine.makeScript(fs.readFileSync(scriptFile,'utf8'),settings);
    const candidate=engine.buildCandidate(loc,ctx,script,dnsConfig);
    assert.equal(candidate.proxies.filter(p=>p.name===engine.NODE_NAME).length,1);
    assert.deepEqual(candidate['proxy-groups'].find(g=>g.name===engine.GROUP_NAME).proxies,[engine.NODE_NAME]);
    assert.equal(candidate.proxies.find(p=>p.name===engine.NODE_NAME).udp,false);
    for(const rule of direct)assert(candidate.rules.includes(rule));
    if(scope==='fullPublic') {
      assert.equal(candidate.rules.at(-1),'MATCH,'+engine.GROUP_NAME);
      assert.equal(candidate.rules.at(-2),'NETWORK,UDP,REJECT');
      for(const rule of direct)assert(candidate.rules.indexOf(rule)<candidate.rules.indexOf('NETWORK,UDP,REJECT'));
    } else for(const domain of context.serviceDomains)assert(candidate.rules.includes('DOMAIN-SUFFIX,'+domain+','+engine.GROUP_NAME));
    const next=engine.makeScript(script,{...settings,node:engine.parseSOCKS(examples[1])});
    assert.equal(next.split('// BEGIN ACCOUNT PROXY SWITCHER MANAGED').length-1,1);
    const changed=engine.buildCandidate(loc,ctx,next,dnsConfig),node=changed.proxies.find(p=>p.name===engine.NODE_NAME);
    assert.equal(node.server,'198.51.100.7');assert.equal(node.username,'user@example');assert.equal(node.password,'p:@/%');
    assert.equal(changed.proxies.filter(p=>p.name===engine.NODE_NAME).length,1);
  }
  for(const socksURL of ['https://example.com:1080','socks5://example.com','socks5://example.com:1080/path'])assert.throws(()=>engine.parseSOCKS({socksURL}));
  const file=write('restore.txt','before'),snapshot=engine.backup(loc,[file],'offline-test');
  fs.writeFileSync(file,'after');engine.restoreSnapshot(snapshot);assert.equal(fs.readFileSync(file,'utf8'),'before');
  for(const[file,hash]of Object.entries(before))assert.equal(engine.sha(fs.readFileSync(file)),hash,'Fixture source was modified');
  assert(!/api\(loc,\s*['"]DELETE['"],\s*['"]\/connections/.test(fs.readFileSync(path.join(__dirname,'engine.js'),'utf8')));
  console.log('PASS: legacy utility fixtures cover interfaces, both routing scopes, credential escaping, replacement idempotency, DNS exceptions and backup restore; no user environment accessed.');
} finally {fs.rmSync(temporary,{recursive:true,force:true});}
