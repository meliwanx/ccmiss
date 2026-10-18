#!/usr/bin/env node
'use strict';
// Optional cooperation with the already-running Clash core. Never creates a TUN,
// changes system DNS, restarts Clash, or deletes a connection.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),http=require('node:http'),net=require('node:net'),vm=require('node:vm'),crypto=require('node:crypto');
const {spawn,spawnSync}=require('node:child_process');
const legacy=require('./engine.js'),yaml=require('./js-yaml.cjs'),standalone=require('./standalone-engine.js');
const NODE_NAME='ccmiss SOCKS5',GROUP_NAME='ccmiss 账号出口',UPSTREAM_NAME='ccmiss 连接前置';
const START='// BEGIN CCMISS COEXIST OVERLAY',END='// END CCMISS COEXIST OVERLAY';
const SERVICE_DOMAINS=['anthropic.com','claude.ai','claude.com','claude.app','claudeusercontent.com','claudemcpcontent.com','cloudflare.com','cloudflare.net','cloudflareinsights.com','cloudflare-dns.com','stripe.com','stripe.network','stripecdn.com','link.com','stripe.dev','stripe.events','stripe.global'];
const CHECK_DOMAINS=['ip.net.coffee'];
const CHECK_IPS=['1.1.1.1/32'];
const RELAY_HOSTS=[];
const clone=x=>JSON.parse(JSON.stringify(x)),sha=x=>crypto.createHash('sha256').update(typeof x==='string'||Buffer.isBuffer(x)?x:JSON.stringify(x)).digest('hex');
const stable=x=>Array.isArray(x)?x.map(stable):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,stable(x[k])])):x;
const equal=(a,b)=>JSON.stringify(stable(a))===JSON.stringify(stable(b)),sleep=ms=>new Promise(r=>setTimeout(r,ms)),secrets=[];
function safeError(e){if(e&&(e.name==='SyntaxError'||e.name==='YAMLException'))return '本地配置格式不正确，请检查配置文件；原始内容未输出。';let s=String(e&&e.message||e||'未知错误');for(const p of secrets.filter(Boolean).sort((a,b)=>b.length-a.length))s=s.split(p).join('[已隐藏]');return s.replace(/(?:socks5h?|vless):\/\/[^\s"']+/gi,'proxy://[凭据已隐藏]').replace(/([a-z][a-z\d+.-]*:\/\/)[^\s/@]+:[^\s/@]+@/gi,'$1[凭据已隐藏]@').replace(/((?:proxy-)?authorization\s*:\s*)[^\r\n]+/gi,'$1[已隐藏]').replace(/("?(?:password|username|secret|uuid|token)"?\s*[:=]\s*)[^,\n}]+/gi,'$1[已隐藏]').slice(0,1800);}
function locations(options={}){const root=options.appDataDirectory||path.join(os.homedir(),'Library/Application Support/AccountProxySwitcher'),dataDirectory=options.dataDirectory||path.join(root,'coexist');return {...legacy.locations({...options,dataDirectory}),dataDirectory,core:options.core||path.join(__dirname,'mihomo'),settingsFile:options.settingsFile||path.join(root,'standalone/settings.json'),stateFile:path.join(dataDirectory,'state.json'),journalFile:path.join(dataDirectory,'transaction.json'),lockFile:path.join(dataDirectory,'engine.lock'),diagnosticFile:path.join(dataDirectory,'last-verification-diagnostic.json')};}
function readJSON(f,fallback=null){try{return JSON.parse(fs.readFileSync(f,'utf8'));}catch(e){if(e.code==='ENOENT')return fallback;throw e;}}
function privateDir(d){fs.mkdirSync(d,{recursive:true,mode:0o700});fs.chmodSync(d,0o700);}
function atomicWrite(f,s){fs.mkdirSync(path.dirname(f),{recursive:true,mode:0o700});const t=f+'.ccmiss-'+crypto.randomBytes(6).toString('hex');fs.writeFileSync(t,typeof s==='string'||Buffer.isBuffer(s)?s:JSON.stringify(s,null,2),{mode:0o600,flag:'wx'});fs.renameSync(t,f);fs.chmodSync(f,0o600);}
function fileHash(f){try{return sha(fs.readFileSync(f));}catch(e){if(e.code==='ENOENT')return null;throw e;}}
function hashes(files){return Object.fromEntries([...new Set(files)].map(f=>[f,fileHash(f)]));}
function assertHashes(expected){for(const[f,h]of Object.entries(expected))if(fileHash(f)!==h)throw new Error('Clash 配置在操作期间发生变化，已停止，未覆盖新修改。');}
// Keep byte ownership for scripts/DNS. A subscription refresh may regenerate the
// runtime YAML; only a provably intact ccmiss overlay can inherit new base data.
function runtimeSemanticHash(config){return sha(stable(config));}
function checkedBackup(directory){
 const manifest=readJSON(path.join(directory,'manifest.json'));
 if(!manifest||manifest.version!==1||!Array.isArray(manifest.files))throw new Error('恢复清单无效。');
 const entries=manifest.files.map(entry=>{
  if(typeof entry.name!=='string'||path.basename(entry.name)!==entry.name)throw new Error('恢复清单无效。');
  const data=entry.exists?fs.readFileSync(path.join(directory,entry.name)):null;
  if(entry.exists&&sha(data)!==entry.hash)throw new Error('恢复备份校验失败。');
  return {...entry,data};
 });
 return entries;
}
function priorOwnedRuntime(loc,ctx,state){
 const expected=state.managedHashes&&state.managedHashes[loc.runtimeFile];
 if(typeof expected!=='string'||!state.latestBackup)return null;
 try{
  const entry=checkedBackup(state.latestBackup).find(x=>x.path===loc.runtimeFile);
  if(!entry||!entry.exists)return null;
  // Parse only the JSON argument written by makeScript; never execute the
  // subscription script or its previous main function during migration.
  const source=fs.readFileSync(ctx.scriptFile,'utf8'),marker='return ('+transform.toString()+')(prior,',suffix=');\n}\n'+END+'\n';
  const overlay=source.slice(source.indexOf(START)),offset=overlay.indexOf(marker);
  if(!source.includes(START)||offset<0||!overlay.endsWith(suffix))return null;
  const settings=JSON.parse(overlay.slice(offset+marker.length,-suffix.length));
  const candidate=transform(yaml.load(entry.data.toString('utf8')),settings);
  // Old states gain no trust from a guessed reconstruction: its serialized
  // bytes must match exactly the successful apply's original recorded digest.
  if(sha(legacy.dumpYAML(candidate))!==expected)return null;
  return {candidate,settings};
 }catch{return null;}
}
function policyTarget(settings,key){const d=key.replace(/^[+*]\./,'');return settings.suffixes.some(s=>d===s||d.endsWith('.'+s))||settings.exact.includes(d);}
function managedProjection(config,settings){return {
 nodes:(config.proxies||[]).filter(p=>[NODE_NAME,UPSTREAM_NAME].includes(p.name)),
 groups:(config['proxy-groups']||[]).filter(p=>p.name===GROUP_NAME),
 rules:(config.rules||[]).filter(r=>String(r).includes(','+GROUP_NAME)||settings.rules.includes(String(r))),
 prefix:(config.rules||[]).slice(0,settings.rules.length),
 dns:Object.fromEntries(Object.entries(config.dns&&config.dns['nameserver-policy']||{}).filter(([k])=>policyTarget(settings,k)))
};}
function baselineWithoutOverlay(config,settings,original){
 const result=clone(config);
 result.proxies=(result.proxies||[]).filter(p=>![NODE_NAME,UPSTREAM_NAME].includes(p.name));
 result['proxy-groups']=(result['proxy-groups']||[]).filter(p=>p.name!==GROUP_NAME);
 result.rules=(result.rules||[]).filter(r=>!String(r).includes(','+GROUP_NAME)&&!settings.rules.includes(String(r)));
 const policy={...(result.dns&&result.dns['nameserver-policy']||{})};
 for(const k of Object.keys(policy))if(policyTarget(settings,k))delete policy[k];
 for(const[k,v]of Object.entries(original.dns&&original.dns['nameserver-policy']||{}))if(policyTarget(settings,k))policy[k]=clone(v);
 result.dns={...(result.dns||{}),'nameserver-policy':policy};
 if(!Object.keys(policy).length&&!(original.dns&&Object.hasOwn(original.dns,'nameserver-policy')))delete result.dns['nameserver-policy'];
 return result;
}
function assertOwnedHashes(loc,ctx,state){
 const expected=state.managedHashes||{},runtimeExpected=expected[loc.runtimeFile];
 if(typeof runtimeExpected!=='string')throw new Error('Clash 配置所有权记录不完整，未覆盖当前网络。');
 assertHashes(Object.fromEntries(Object.entries(expected).filter(([f])=>f!==loc.runtimeFile)));
 if(fileHash(loc.runtimeFile)===runtimeExpected)return {rebaseRequired:false};
 const current=yaml.load(fs.readFileSync(loc.runtimeFile,'utf8'));
 if(typeof state.runtimeSemanticHash==='string'&&runtimeSemanticHash(current)===state.runtimeSemanticHash)return {rebaseRequired:false};
 const owned=priorOwnedRuntime(loc,ctx,state);
 if(!owned||!equal(managedProjection(current,owned.settings),managedProjection(owned.candidate,owned.settings)))throw new Error('Clash 账号覆盖配置发生变化，已停止，未覆盖新修改。');
 if(equal(current,owned.candidate))return {rebaseRequired:false};
 const entries=checkedBackup(state.baselineBackup),entry=entries.find(x=>x.path===loc.runtimeFile);
 if(!entry||!entry.exists)throw new Error('缺少接管前备份，未改动当前网络。');
 const original=yaml.load(entry.data.toString('utf8'));
 return {rebaseRequired:true,entries,baselineRuntime:baselineWithoutOverlay(current,owned.settings,original)};
}
function scopedBaselineBackup(loc,plan){
 const directory=path.join(loc.dataDirectory,'backups',Date.now()+'-subscription-rebase-'+crypto.randomBytes(4).toString('hex'));privateDir(directory);
 const files=plan.entries.map(entry=>{
  const data=entry.path===loc.runtimeFile?Buffer.from(legacy.dumpYAML(plan.baselineRuntime)):entry.data;
  if(entry.exists)fs.writeFileSync(path.join(directory,entry.name),data,{mode:0o600});
  return {path:entry.path,exists:entry.exists,name:entry.name,hash:entry.exists?sha(data):null};
 });
 atomicWrite(path.join(directory,'manifest.json'),{version:1,files});return directory;
}
function api(loc,method,endpoint,body,socket=loc.socket){return new Promise((resolve,reject)=>{const data=body===undefined?null:JSON.stringify(body),r=http.request({socketPath:socket,path:endpoint,method,headers:data?{'Content-Type':'application/json','Content-Length':Buffer.byteLength(data)}:{}},reply=>{reply.setEncoding('utf8');let s='';reply.on('data',c=>{s+=c;if(s.length>16*1024*1024)r.destroy(new Error('Clash 返回内容过大。'));});reply.on('end',()=>{if(reply.statusCode>=400)return reject(new Error('Clash 控制接口 HTTP '+reply.statusCode));try{resolve(s?JSON.parse(s):{});}catch(e){reject(new Error('Clash 返回无效数据。'));}});});r.setTimeout(12000,()=>r.destroy(new Error('Clash 控制接口超时。')));r.on('error',reject);if(data)r.write(data);r.end();});}
const call=(loc,effects,method,endpoint,body)=>effects.api?effects.api(method,endpoint,body):api(loc,method,endpoint,body);
function context(loc,effects={}){return effects.context?effects.context():legacy.resolveContext(loc);}
function sourceFiles(loc,ctx){return [loc.profilesFile,loc.baseFile,loc.vergeFile,loc.dnsFile,loc.runtimeFile,ctx.rawFile,ctx.scriptFile,ctx.mergeFile,ctx.rulesFile,ctx.proxiesFile,ctx.groupsFile,ctx.globalMergeFile,ctx.globalScriptFile,loc.settingsFile];}
function ruleShape(reply){return (reply.rules||[]).map(r=>({type:r.type,payload:r.payload,proxy:r.proxy,...(r.extra&&r.extra.disabled!==undefined?{disabled:r.extra.disabled}:{})}));}
async function live(loc,effects={}){const [configs,rules,proxies]=await Promise.all(['/configs','/rules','/proxies'].map(p=>call(loc,effects,'GET',p)));const selections=Object.fromEntries(Object.entries(proxies.proxies||{}).filter(([name,p])=>p.type==='Selector'&&name!==GROUP_NAME).map(([name,p])=>[name,p.now]));return {configs,rules,proxies,selections,token:sha(stable({configs,rules:ruleShape(rules),selections})),rulesToken:sha(stable(ruleShape(rules)))};}
async function detect(loc=locations(),effects={}){try{context(loc,effects);await call(loc,effects,'GET','/version');return true;}catch{return false;}}
function targets(){return SERVICE_DOMAINS.concat(CHECK_DOMAINS).map(d=>({kind:'DOMAIN-SUFFIX',domain:d})).concat(RELAY_HOSTS.map(d=>({kind:'DOMAIN',domain:d})),CHECK_IPS.map(d=>({kind:'IP-CIDR',domain:d})));}
function overlayRules(){return targets().flatMap(({kind,domain})=>kind==='IP-CIDR'?['AND,((NETWORK,UDP),(DST-PORT,443),(IP-CIDR,'+domain+',no-resolve)),REJECT','AND,((NETWORK,TCP),(DST-PORT,443),(IP-CIDR,'+domain+',no-resolve)),'+GROUP_NAME]:['AND,((NETWORK,UDP),('+kind+','+domain+')),REJECT',...(kind==='DOMAIN'?[80,443].map(p=>'AND,((NETWORK,TCP),(DST-PORT,'+p+'),('+kind+','+domain+')),'+GROUP_NAME):['AND,((NETWORK,TCP),('+kind+','+domain+')),'+GROUP_NAME])]);}
function targetPolicy(key){const d=key.replace(/^[+*]\./,'');return SERVICE_DOMAINS.concat(CHECK_DOMAINS).some(s=>d===s||d.endsWith('.'+s))||RELAY_HOSTS.includes(d);}
function patchPolicy(policy={}){const result=clone(policy);for(const k of Object.keys(result))if(targetPolicy(k))delete result[k];for(const d of SERVICE_DOMAINS.concat(CHECK_DOMAINS))result['+.'+d]=['https://1.1.1.1/dns-query#'+GROUP_NAME];for(const d of RELAY_HOSTS)result[d]=['https://1.1.1.1/dns-query#'+GROUP_NAME];return result;}
// Self-contained, embedded verbatim in the existing subscription's script.
function transform(config,settings){const nodeName='ccmiss SOCKS5',groupName='ccmiss 账号出口',frontName='ccmiss 连接前置';
 config.proxies=(config.proxies||[]).filter(p=>![nodeName,frontName].includes(p.name)).concat(settings.nodes);
 config['proxy-groups']=(config['proxy-groups']||[]).filter(p=>p.name!==groupName).concat([{name:groupName,type:'select',proxies:[nodeName]}]);
 config.rules=settings.rules.concat((config.rules||[]).filter(r=>!String(r).includes(','+groupName)&&!settings.rules.includes(String(r))));
 const policy=Object.assign({},config.dns&&config.dns['nameserver-policy']||{});
 for(const key of Object.keys(policy)){const d=key.replace(/^[+*]\./,'');if(settings.suffixes.some(s=>d===s||d.endsWith('.'+s))||settings.exact.includes(d))delete policy[key];}
 for(const d of settings.suffixes)policy['+.'+d]=['https://1.1.1.1/dns-query#'+groupName];for(const d of settings.exact)policy[d]=['https://1.1.1.1/dns-query#'+groupName];
 config.dns=Object.assign({},config.dns,{'nameserver-policy':policy});return config;
}
function stripScript(source){if(!source.includes(START))return source;const i=source.indexOf(START);if(!source.slice(i).includes(END))throw new Error('ccmiss 脚本标记不完整，未修改。');return source.slice(0,i).replace(/function\s+ccmissCoexistPreviousMain\s*\(/,'function main(').trimEnd()+'\n';}
function makeScript(original,settings,profileName){const source=stripScript(original),matches=[...source.matchAll(/function\s+main\s*\(/g)];if(matches.length!==1||source.includes('function ccmissCoexistPreviousMain'))throw new Error('当前订阅脚本入口不受支持，未修改。');const wrapped=source.replace(/function\s+main\s*\(/,'function ccmissCoexistPreviousMain(');const out=wrapped.trimEnd()+'\n\n'+START+'\nfunction main(config, profileName) {\n const prior=ccmissCoexistPreviousMain(config,profileName);\n if(profileName!=='+JSON.stringify(profileName)+') return prior;\n return ('+transform.toString()+')(prior,'+JSON.stringify(settings)+');\n}\n'+END+'\n';new vm.Script(out);return out;}
function withoutOverlay(config){const c=clone(config);c.proxies=(c.proxies||[]).filter(p=>![NODE_NAME,UPSTREAM_NAME].includes(p.name));c['proxy-groups']=(c['proxy-groups']||[]).filter(g=>g.name!==GROUP_NAME);c.rules=(c.rules||[]).filter(r=>!String(r).includes(','+GROUP_NAME)&&!overlayRules().includes(String(r)));if(c.dns&&c.dns['nameserver-policy'])for(const k of Object.keys(c.dns['nameserver-policy']))if(targetPolicy(k))delete c.dns['nameserver-policy'][k];if(c.dns&&c.dns['nameserver-policy']&&Object.keys(c.dns['nameserver-policy']).length===0)delete c.dns['nameserver-policy'];return c;}
function assertScoped(before,after){if(!equal(withoutOverlay(before),withoutOverlay(after)))throw new Error('候选配置改变了非目标网络设置，已拒绝应用。');if(!equal(before.tun,after.tun)||!equal(before.sniffer,after.sniffer))throw new Error('不能改变 Clash 隧道或浏览器嗅探设置。');}
function makePrepared(loc,request,ctx,state){if(request.scope&&request.scope!=='servicesOnly')throw new Error('Clash 共存时只支持指定服务，其他网络继续按 Clash 原设置。');const profile=request.profile;if(!profile||!profile.id||!profile.name)throw new Error('请先选择账号。');const parsed=standalone.parseSOCKS(profile);secrets.push(profile.socksURL,parsed.username,parsed.password);const node={name:NODE_NAME,type:'socks5',server:parsed.host,port:parsed.port,udp:false};if(parsed.username)node.username=parsed.username;if(parsed.password)node.password=parsed.password;const settings=standalone.normalizeSettings(readJSON(loc.settingsFile,{})),nodes=[node];if(settings.upstreamProxy){node['dialer-proxy']=UPSTREAM_NAME;nodes.push({...settings.upstreamProxy,name:UPSTREAM_NAME});for(const k of ['uuid','username','password'])secrets.push(settings.upstreamProxy[k]);}
 if(!settings.upstreamProxy){const old=(ctx.runtime.proxies||[]).find(p=>p.name===legacy.NODE_NAME),front=old&&old['dialer-proxy'];if(front){if([NODE_NAME,GROUP_NAME,UPSTREAM_NAME,'DIRECT','REJECT',legacy.NODE_NAME,legacy.GROUP_NAME].includes(front)||!(ctx.runtime.proxies||[]).concat(ctx.runtime['proxy-groups']||[]).some(p=>p.name===front))throw new Error('Clash 原有连接前置不可用，未改为直连。');node['dialer-proxy']=front;const existing=(ctx.runtime.proxies||[]).find(p=>p.name===front);if(existing)for(const k of ['uuid','username','password'])secrets.push(existing[k]);}}
 const options={nodes,rules:overlayRules(),suffixes:SERVICE_DOMAINS.concat(CHECK_DOMAINS),exact:RELAY_HOSTS},candidate=transform(clone(ctx.runtime),options);assertScoped(ctx.runtime,candidate);
 if(!state.activeProfileID&&(ctx.runtime.proxies||[]).some(p=>[NODE_NAME,UPSTREAM_NAME].includes(p.name))||!state.activeProfileID&&(ctx.runtime['proxy-groups']||[]).some(g=>g.name===GROUP_NAME))throw new Error('发现未归属当前软件的同名出口，请先检查已有配置。');
 const original=fs.readFileSync(ctx.scriptFile,'utf8'),script=makeScript(original,options,ctx.current.name);const dns=clone(ctx.dns);dns.dns={...(dns.dns||{}),'nameserver-policy':patchPolicy(dns.dns&&dns.dns['nameserver-policy']||{})};
 const scoped=ctx.verge.profile_dns_settings&&ctx.verge.profile_dns_settings[ctx.current.uid],writeDNS=!!(scoped?scoped.enabled:ctx.verge.enable_dns_settings);
 if(writeDNS&&(ctx.metadata.items||[]).filter(i=>['remote','local'].includes(i.type)).length>1)throw new Error('多个订阅共用 DNS 覆盖，不能保证仅当前订阅生效；请先关闭当前订阅的 DNS 覆盖。');
 return {ctx,profile,parsed,candidate,script,dns,writeDNS,sourceHashes:hashes(sourceFiles(loc,ctx)),settingsHash:fileHash(loc.settingsFile)};}
function ipv6Safe(effects={}){const interfaces=effects.interfaces||os.networkInterfaces();return !Object.entries(interfaces).some(([name,addresses])=>! /^(utun|tun|tap|ppp|ipsec|lo\d|gif|stf|awdl|llw)/i.test(name)&&addresses.some(a=>!a.internal&&(a.family==='IPv6'||a.family===6)&&! /^(?:fe[89ab]|f[cd]|::)/i.test(a.address)));}
function assertReady(ctx,info,effects={}){if(!ipv6Safe(effects)||info.configs.ipv6!==false)throw new Error('无法确认公网 IPv6 受保护；请先在网络设置关闭公网 IPv6，再启用账号。软件不会自动改变系统 IPv6。');for(const k of ['mode','ipv6','mixed-port','socks-port','port','redir-port','allow-lan','bind-address','log-level','interface-name'])if(k in ctx.runtime&&k in info.configs&&!equal(ctx.runtime[k],info.configs[k]))throw new Error('Clash 内存设置与配置文件不一致，请先在 Clash 保存当前设置后重试。');for(const[k,v]of Object.entries(ctx.runtime.tun||{}))if(k in (info.configs.tun||{})&&!equal(typeof v==='string'?v.toLowerCase():v,typeof info.configs.tun[k]==='string'?info.configs.tun[k].toLowerCase():info.configs.tun[k]))throw new Error('Clash 当前隧道设置尚未保存，未修改网络。');if(info.configs.mode!=='rule'||!(info.configs.tun&&info.configs.tun.enable))throw new Error('请先让 Clash 使用规则模式并保持 TUN 开启。');if(!(ctx.runtime.dns&&ctx.runtime.dns.enable))throw new Error('Clash 的 DNS 未启用，无法只为指定服务配置 DNS。');if(!(ctx.runtime.profile&&ctx.runtime.profile['store-selected']===true))throw new Error('Clash 未保存节点选择，无法保证其他网络原样；请先开启 Clash 的保存节点选择。');}
function ownership(loc,ctx,state){if(!state.activeProfileID)return;if(state.currentProfileUID!==ctx.current.uid)throw new Error('Clash 当前订阅已变更，请切回原订阅后停用此账号。');return assertOwnedHashes(loc,ctx,state);}
async function setupStatus(loc=locations(),effects={}){let ctx,info,error='';try{ctx=context(loc,effects);info=await live(loc,effects);assertReady(ctx,info,effects);}catch(e){error=safeError(e);}const state=readJSON(loc.stateFile,{}),pending=!!readJSON(loc.journalFile);let owned=false;if(ctx&&state.activeProfileID){try{const ownershipInfo=ownership(loc,ctx,state);if(info&&state.runtimeRulesToken&&info.rulesToken!==state.runtimeRulesToken&&!(ownershipInfo&&ownershipInfo.rebaseRequired))throw new Error('Clash 内存规则已被其他程序修改，请先检查配置，未覆盖当前网络。');owned=true;}catch(e){error=safeError(e);}}
 const group=info&&info.proxies.proxies&&info.proxies.proxies[GROUP_NAME],networkReady=!!(owned&&!error&&!pending&&group&&group.now===NODE_NAME&&info.configs.mode==='rule'&&info.configs.tun&&info.configs.tun.enable);
 return {backend:'clashCoexist',available:!!info,clashTunEnabled:!!(info&&info.configs.tun&&info.configs.tun.enable),authorizationRequired:false,helperAvailable:!!info,ipv6Safe:ipv6Safe(effects)&&!!info&&info.configs.ipv6===false,hasNetworkConflict:false,conflicts:[],canInitialize:!!info&&!error&&!pending,networkReady,isManaged:!!state.activeProfileID,requiresInitialization:!networkReady,hasSavedConfiguration:!!state.activeProfileID,proxyMode:state.activeProfileID||pending?'profile':'system',systemProxyConfirmed:!state.activeProfileID&&!pending,managedRelayHosts:RELAY_HOSTS,scopeLabel:'指定服务 · 与 Clash 共存',checks:[{id:'clashCoexist',title:'与 Clash 共存',ready:!!info&&!error,detail:error||'沿用当前 Clash 隧道，只切换指定服务，保留其他网络。'},{id:'coexistRecovery',title:'未完成的切换',ready:!pending,detail:pending?'上一次切换未完成，请重试跟随系统恢复。':'没有待恢复的操作。'}],message:error|| (pending?'请先恢复未完成操作。':networkReady?'指定服务正在使用所选账号；其他网络沿用 Clash。':'Clash 可共存，无需退出或重复网络授权。'),upstreamConfigured:!!standalone.normalizeSettings(readJSON(loc.settingsFile,{})).upstreamProxy,upstreamSummary:standalone.normalizeSettings(readJSON(loc.settingsFile,{})).upstreamProxy?'使用软件共用连接前置':ctx&&(ctx.runtime.proxies||[]).find(p=>p.name===legacy.NODE_NAME&&p['dialer-proxy'])?'沿用 Clash 原有连接前置':'直接连接 SOCKS5'};}
async function status(loc=locations(),effects={}){const s=await setupStatus(loc,effects),state=readJSON(loc.stateFile,{});return {...s,isRunning:s.networkReady,tunEnabled:s.clashTunEnabled,mode:'rule',needsReapply:!!state.activeProfileID&&!s.networkReady,pendingSettings:!!state.activeProfileID&&state.settingsHash!==fileHash(loc.settingsFile),activeProfileID:s.networkReady?state.activeProfileID:null,scope:'servicesOnly',ip:s.networkReady?state.ip:null,backupPath:state.latestBackup||null};}
function lock(loc){privateDir(loc.dataDirectory);try{fs.writeFileSync(loc.lockFile,JSON.stringify({pid:process.pid}),{flag:'wx',mode:0o600});}catch(e){if(e.code!=='EEXIST')throw e;const prior=readJSON(loc.lockFile,{});let running=false;try{process.kill(prior.pid,0);running=true;}catch{}if(running)throw new Error('另一个账号切换正在执行，请稍后重试。');fs.rmSync(loc.lockFile);return lock(loc);}return ()=>fs.rmSync(loc.lockFile,{force:true});}
function backup(loc,files,kind){const d=path.join(loc.dataDirectory,'backups',Date.now()+'-'+kind+'-'+crypto.randomBytes(4).toString('hex'));privateDir(d);const entries=[...new Set(files)].map((f,i)=>{const exists=fs.existsSync(f),name=i+'-'+path.basename(f);if(exists)fs.writeFileSync(path.join(d,name),fs.readFileSync(f),{mode:0o600});return {path:f,exists,name,hash:fileHash(f)};});atomicWrite(path.join(d,'manifest.json'),{version:1,files:entries});return d;}
function restoreFiles(d){const m=readJSON(path.join(d,'manifest.json'));if(!m||m.version!==1)throw new Error('恢复清单无效。');for(const x of m.files)if(x.exists&&fileHash(path.join(d,x.name))!==x.hash)throw new Error('恢复备份校验失败。');for(const x of m.files)if(x.exists)atomicWrite(x.path,fs.readFileSync(path.join(d,x.name)));else fs.rmSync(x.path,{force:true});}
async function reload(loc,configuration,effects){await call(loc,effects,'PUT','/configs?force=false',{payload:legacy.dumpYAML(configuration)});}
function assertLivePreserved(before,after){if(!equal(before.configs,after.configs)||!equal(before.selections,after.selections))throw new Error('Clash 隧道、监听或其他节点选择发生变化，切换未确认成功。');}
function physicalInterface(){const r=spawnSync('/sbin/route',['-n','get','default'],{encoding:'utf8',timeout:3000}),n=spawnSync('/usr/sbin/scutil',['--nwi'],{encoding:'utf8',timeout:3000});return legacy.selectPreflightInterface({routeOutput:r.stdout||'',nwiOutput:n.stdout||''});}
function port(){return new Promise((resolve,reject)=>{const s=net.createServer();s.on('error',reject);s.listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>resolve(p));});});}
async function isolatedPreflight(loc,prepared,effects={}){if(effects.preflight)return effects.preflight(prepared);privateDir(loc.dataDirectory);const dir=fs.mkdtempSync(path.join(loc.dataDirectory,'check-')),socket=path.join(dir,'core.sock'),p=await port(),physical=physicalInterface();const c=clone(prepared.candidate);c.tun={enable:false};c.dns={...c.dns,listen:'127.0.0.1:0'};c['interface-name']=physical;c['mixed-port']=p;c['external-controller']='';c['external-controller-unix']=socket;c.secret='';c['log-level']='silent';c['allow-lan']=false;c['bind-address']='127.0.0.1';for(const k of ['listeners','tunnels','socks-port','port','redir-port','tproxy-port'])delete c[k];c.profile={...(c.profile||{}),'store-selected':false,'store-fake-ip':false};for(const g of c['proxy-groups']||[])if(['url-test','fallback','load-balance'].includes(g.type)){g.lazy=true;g.interval=86400;}for(const node of c.proxies||[])node['interface-name']=physical;
 for(const name of ['geoip.dat','geosite.dat','Country.mmdb','ASN.mmdb'])if(fs.existsSync(path.join(loc.configDirectory,name)))fs.symlinkSync(path.join(loc.configDirectory,name),path.join(dir,name));
 const file=path.join(dir,'candidate.yaml');fs.writeFileSync(file,legacy.dumpYAML(c),{mode:0o600});let child;try{child=spawn(loc.core,['-d',dir,'-f',file],{stdio:'ignore'});let spawnError;child.on('error',e=>spawnError=e);let ready=false;for(let i=0;i<60;i++){if(spawnError||child.exitCode!==null)throw new Error('隔离代理预检无法启动。');try{await api(loc,'GET','/version',undefined,socket);ready=true;break;}catch{await sleep(100);}}if(!ready)throw new Error('隔离代理预检超时。');const result=await verifyEndpoints(loc,{...effects,api:(m,e,b)=>api(loc,m,e,b,socket)},{profileID:prepared.profile.id,expectedHost:prepared.parsed.host,port:p,stage:'preflight'});if(!result.success)throw verificationError(result);const baseline=clone(c);baseline.proxies=clone(prepared.ctx.runtime.proxies||[]);baseline['proxy-groups']=clone(prepared.ctx.runtime['proxy-groups']||[]);baseline.rules=clone(prepared.ctx.runtime.rules||[]);baseline.dns={...clone(prepared.ctx.runtime.dns||{}),listen:'127.0.0.1:0'};for(const node of baseline.proxies)node['interface-name']=physical;for(const g of baseline['proxy-groups'])if(['url-test','fallback','load-balance'].includes(g.type)){g.lazy=true;g.interval=86400;}await api(loc,'PUT','/configs?force=false',{payload:legacy.dumpYAML(baseline)},socket);result.baselineRulesToken=sha(stable(ruleShape(await api(loc,'GET','/rules',undefined,socket))));if(result.baselineRulesToken!==prepared.before.rulesToken)throw new Error('Clash 内存规则与持久配置不一致，未覆盖当前网络。');return result;}finally{if(child&&child.exitCode===null){child.kill('SIGTERM');await Promise.race([new Promise(r=>child.once('exit',r)),sleep(1500)]);if(child.exitCode===null)child.kill('SIGKILL');}fs.rmSync(dir,{recursive:true,force:true});}}
async function isolatedRuleToken(loc,configuration,effects={}){
 if(effects.ruleToken)return effects.ruleToken(configuration);
 privateDir(loc.dataDirectory);const dir=fs.mkdtempSync(path.join(loc.dataDirectory,'rules-')),socket=path.join(dir,'core.sock'),physical=physicalInterface(),c=clone(configuration);let child;
 c.tun={enable:false};c.dns={...(c.dns||{}),listen:'127.0.0.1:0'};c['mixed-port']=0;c['interface-name']=physical;c['external-controller']='';c['external-controller-unix']=socket;c.secret='';c['log-level']='silent';c['allow-lan']=false;c['bind-address']='127.0.0.1';c.profile={...(c.profile||{}),'store-selected':false,'store-fake-ip':false};
 for(const k of ['listeners','tunnels','socks-port','port','redir-port','tproxy-port'])delete c[k];
 for(const g of c['proxy-groups']||[])if(['url-test','fallback','load-balance'].includes(g.type)){g.lazy=true;g.interval=86400;}
 for(const node of c.proxies||[])node['interface-name']=physical;
 for(const name of ['geoip.dat','geosite.dat','Country.mmdb','ASN.mmdb'])if(fs.existsSync(path.join(loc.configDirectory,name)))fs.symlinkSync(path.join(loc.configDirectory,name),path.join(dir,name));
 const file=path.join(dir,'candidate.yaml');fs.writeFileSync(file,legacy.dumpYAML(c),{mode:0o600});
 try{
  child=spawn(loc.core,['-d',dir,'-f',file],{stdio:'ignore'});let spawnError;child.on('error',e=>spawnError=e);
  for(let n=0;n<60;n++){
   if(spawnError||child.exitCode!==null)throw new Error('隔离规则校验无法启动。');
   try{const result=await api(loc,'GET','/rules',undefined,socket);return sha(stable(ruleShape(result)));}catch{}
   await sleep(100);
  }
  throw new Error('隔离规则校验超时。');
 }finally{
  if(child&&child.exitCode===null){child.kill('SIGTERM');await Promise.race([new Promise(r=>child.once('exit',r)),sleep(1500)]);if(child.exitCode===null)child.kill('SIGKILL');}
  fs.rmSync(dir,{recursive:true,force:true});
 }
}
const TRANSIENT_CURL_CODES=new Set([5,6,7,18,28,35,52,55,56,92]);
const CERTIFICATE_CURL_CODES=new Set([51,58,60,77,83,90,91]);
function classifyTransport(status,code,signal,spawnError,outputLimited=false){
 if(outputLimited)return {errorKind:'responseTooLarge',error:'检查响应超过大小限制。',retryable:false};
 if(spawnError)return {errorKind:'process',error:'无法启动网络检查：'+safeError(spawnError),retryable:false};
 if(signal)return {errorKind:'signal',error:'网络检查被信号 '+signal+' 中断。',retryable:false};
 if(CERTIFICATE_CURL_CODES.has(code))return {errorKind:'tlsCertificate',error:'TLS 证书验证未通过（curl '+code+'）。',retryable:false};
 if(code===28)return {errorKind:'timeout',error:'连接或响应超时（curl 28）。',retryable:true};
 if(code===5||code===6)return {errorKind:'dns',error:'DNS 解析失败（curl '+code+'）。',retryable:true};
 if(code===7)return {errorKind:'connect',error:'无法建立代理或目标连接（curl 7）。',retryable:true};
 if(code===35)return {errorKind:'tlsHandshake',error:'TLS 握手中断（curl 35）。',retryable:true};
 if(code!==0&&code!==null)return {errorKind:'transport',error:'连接传输失败（curl '+code+'）。',retryable:TRANSIENT_CURL_CODES.has(code)};
 if(!status)return {errorKind:'transport',error:'尚未收到 HTTP 响应。',retryable:true};
 return {errorKind:null,error:null,retryable:false};
}
function curl(url,p,options={}){return new Promise(resolve=>{
 const maxSeconds=Math.max(0.001,Math.min(18,Number(options.maxTimeMs||18000)/1000));
 const child=(options.spawn||spawn)('/usr/bin/curl',['--silent','--show-error','--http1.1','--connect-timeout',String(Math.min(7,maxSeconds)),'--max-time',String(maxSeconds),'--max-filesize','1048576','--proxy','http://127.0.0.1:'+p,'--noproxy','','--write-out','\nCCMISS_STATUS:%{http_code}\n',url],{stdio:['ignore','pipe','pipe'],env:{PATH:'/usr/bin:/bin:/usr/sbin:/sbin'}});
 let stdout='',stderr='',spawnError=null,outputLimited=false;
 child.stdout.setEncoding('utf8');child.stderr.setEncoding('utf8');
 child.stdout.on('data',chunk=>{if(!outputLimited)stdout+=chunk;if(stdout.length>1200000){outputLimited=true;stdout=stdout.slice(0,1200000);child.kill('SIGTERM');}});
 child.stderr.on('data',chunk=>{if(stderr.length<8192)stderr+=chunk.slice(0,8192-stderr.length);});
 child.on('error',error=>{spawnError=error;});
 // exit may precede the final stdout/stderr data; close drains both streams first.
 child.once('close',(code,signal)=>{const match=/\nCCMISS_STATUS:(\d{3})\s*$/.exec(stdout),ip=/^ip=([^\r\n]+)$/m.exec(stdout),status=match?Number(match[1]):0,curlExitCode=Number.isInteger(code)?code:null,classification=classifyTransport(status,curlExitCode,signal,spawnError,outputLimited);resolve({status,ip:ip?ip[1].trim():null,curlExitCode,signal:signal||null,...classification,stderr:stderr?safeError(stderr):''});});
 });}
function normalizeCurlResult(raw){const result=raw||{},status=Number(result.status)||0,curlExitCode=Number.isInteger(result.curlExitCode)?result.curlExitCode:status?0:null,signal=result.signal||null,classification=classifyTransport(status,curlExitCode,signal,null);return {status,ip:typeof result.ip==='string'?result.ip.trim():null,curlExitCode,signal,...classification,...(result.errorKind?{errorKind:String(result.errorKind),error:safeError(result.error||classification.error),retryable:result.retryable===true}:{}),stderr:result.stderr?safeError(result.stderr):''};}
function verificationError(result){const error=new Error(result.details||'网络检查未通过，未返回完整检查结果。');error.verification=result;return error;}
function diagnosticResult(result){if(!result)return null;return {success:result.success===true,ip:result.ip||null,expectedIP:result.expectedIP||null,details:safeError(result.details||'网络检查未返回原因。'),endpoints:(result.endpoints||[]).slice(0,12).map(endpoint=>({service:safeError(endpoint.service),host:(()=>{try{return new URL(endpoint.url).hostname;}catch{return null;}})(),status:endpoint.status||0,routeVerified:endpoint.routeVerified===true,ip:endpoint.ip||null,curlExitCode:endpoint.curlExitCode??null,signal:endpoint.signal||null,errorKind:endpoint.errorKind||null,error:endpoint.error?safeError(endpoint.error):null,attemptCount:endpoint.attemptCount||(endpoint.attempts||[]).length,attempts:(endpoint.attempts||[]).slice(0,3).map(attempt=>({attempt:attempt.attempt,status:attempt.status||0,ip:attempt.ip||null,curlExitCode:attempt.curlExitCode??null,signal:attempt.signal||null,errorKind:attempt.errorKind||null,error:attempt.error?safeError(attempt.error):null,stderr:attempt.stderr?safeError(attempt.stderr):''}))}))};}
function saveDiagnostic(loc,phase,result,{error=null,restoration=null}={}){try{atomicWrite(loc.diagnosticFile||path.join(loc.dataDirectory,'last-verification-diagnostic.json'),{version:1,checkedAt:new Date().toISOString(),phase,...diagnosticResult(result),success:!error&&result?.success===true,error:error?safeError(error):null,restoration:restoration?{confirmed:restoration.confirmed===true,message:safeError(restoration.message||'')}:null});return true;}catch{return false;}}
async function verifyEndpoints(loc,effects,{profileID,expectedHost,expectedIP=null,port:proxyPort,stage='verify'}={}){
 const now=effects.now||Date.now,deadline=now()+30000;
 if(stage==='postApply')await (effects.sleep||sleep)(250);
 const info=await live(loc,effects),group=info.proxies.proxies&&info.proxies.proxies[GROUP_NAME],selected=!!group&&group.now===NODE_NAME&&equal(group.all,[NODE_NAME]);
 const p=proxyPort||info.configs['mixed-port'];if(!p)throw new Error('Clash 本地代理端口不可用。');
 const probes=[['Cloudflare','https://www.cloudflare.com/cdn-cgi/trace','trace'],['Claude','https://claude.ai/cdn-cgi/trace','trace'],['Anthropic','https://api.anthropic.com/cdn-cgi/trace','trace'],['Stripe','https://api.stripe.com/','stripe'],...RELAY_HOSTS.map(h=>['业务接口 '+h,'https://'+h+'/','relay']),['Cloudflare 检测探针','https://1.1.1.1/cdn-cgi/trace','trace'],['检测网站','https://ip.net.coffee/cdn-cgi/trace','trace']];
 const normalize=value=>[...String(value).matchAll(/\(([^()]+)\)/g)].map(m=>{const [kind,...values]=m[1].replace(/\s+/g,'').split(','),k=kind.toUpperCase().replace(/^DOMAINSUFFIX$/,'DOMAIN-SUFFIX').replace(/^DSTPORT$/,'DST-PORT').replace(/^IPCIDR$/,'IP-CIDR');return '('+k+','+(k==='NETWORK'?values.join(',').toUpperCase():k==='IP-CIDR'?values.filter(v=>v!=='no-resolve').join(','):values.join(','))+')';}).join('&&');
 const endpoints=probes.map(([service,url,kind])=>{const host=new URL(url).hostname,literal=net.isIP(host),ruleKind=literal?'IP-CIDR':RELAY_HOSTS.includes(host)?'DOMAIN':'DOMAIN-SUFFIX',domain=literal?host+'/32':RELAY_HOSTS.includes(host)?host:SERVICE_DOMAINS.concat(CHECK_DOMAINS).find(d=>host===d||host.endsWith('.'+d)),terms=['(NETWORK,TCP)',...(ruleKind==='DOMAIN'||literal?['(DST-PORT,443)']:[]),'('+ruleKind+','+domain+')'],expected=terms.join('&&');const routeVerified=selected&&(info.rules.rules||[]).some(r=>r.type.toUpperCase()==='AND'&&normalize(r.payload)===expected&&r.proxy===GROUP_NAME);return {service,url,kind,status:0,ip:null,curlExitCode:null,signal:null,routeVerified,attempts:[],attemptCount:0,errorKind:routeVerified?null:'route',error:routeVerified?null:'指定服务路由未生效。'};});
 // A routing failure is a configuration error, never a reason to retry the network.
 if(endpoints.every(endpoint=>endpoint.routeVerified))await Promise.all(endpoints.map(async endpoint=>{
  for(let attempt=1;attempt<=3;attempt++){
   const remaining=deadline-now();if(remaining<=0){Object.assign(endpoint,{errorKind:'verificationDeadline',error:'本轮网络检查已达到 30 秒上限。',retryable:false});break;}
   let reply;try{reply=normalizeCurlResult(await (effects.curl||curl)(endpoint.url,p,{maxTimeMs:Math.min(18000,remaining)}));}catch(error){reply={status:0,ip:null,curlExitCode:null,signal:null,errorKind:'process',error:safeError(error),retryable:false,stderr:''};}
   endpoint.attempts.push({attempt,...reply});Object.assign(endpoint,reply,{attemptCount:attempt});
   if(reply.status!==0||!reply.retryable||attempt===3)break;
   const delay=attempt===1?200:500;if(deadline-now()<=delay)break;await (effects.sleep||sleep)(delay);
  }
 }));else for(const endpoint of endpoints)if(endpoint.routeVerified)Object.assign(endpoint,{errorKind:'notChecked',error:'其他指定服务路由未生效，尚未发起网络检查。'});
 const trace=endpoints.filter(endpoint=>endpoint.kind==='trace'),ips=[...new Set(trace.map(endpoint=>endpoint.ip).filter(ip=>net.isIP(ip)))],reasons=[];
 for(const endpoint of endpoints){
  if(!endpoint.routeVerified){reasons.push(endpoint.service+'：指定服务路由未生效');continue;}
  if(endpoint.errorKind){reasons.push(endpoint.service+'：'+(endpoint.error||'网络传输失败')+'（检查 '+endpoint.attemptCount+' 次）');continue;}
  const accepted=endpoint.kind==='stripe'?[200,404].includes(endpoint.status):endpoint.status===200;
  if(!accepted){endpoint.errorKind=endpoint.status===401||endpoint.status===403?'accessDenied':'httpStatus';endpoint.error=endpoint.status===401||endpoint.status===403?'服务拒绝访问，请检查访问策略或白名单。':'HTTP 状态不符合检查要求。';reasons.push(endpoint.service+'：HTTP '+endpoint.status+'，'+endpoint.error);continue;}
  if(endpoint.kind==='trace'&&!net.isIP(endpoint.ip||'')){endpoint.errorKind='missingTraceIP';endpoint.error='trace 响应缺少有效出口 IP。';reasons.push(endpoint.service+'：'+endpoint.error);}
 }
 if(trace.every(endpoint=>endpoint.status===200&&net.isIP(endpoint.ip||'')&&!endpoint.errorKind)){
  if(ips.length!==1){reasons.push('指定服务和检测探针的出口 IP 不一致：'+trace.map(endpoint=>endpoint.service+'='+endpoint.ip).join('，'));for(const endpoint of trace)Object.assign(endpoint,{errorKind:'ipMismatch',error:'指定服务出口 IP 不一致。'});}
  else if(expectedIP&&ips[0]!==expectedIP){reasons.push('实际出口 IP '+ips[0]+' 与预检出口 '+expectedIP+' 不一致');for(const endpoint of trace)Object.assign(endpoint,{errorKind:'unexpectedIP',error:'实际出口与预检出口不一致。'});}
 }
 const success=reasons.length===0,details=success?'Claude、Cloudflare、Anthropic 和浏览器检测探针出口一致；Stripe 和两个接口使用同一专用路由。已有连接保持原出口，新连接使用所选账号。':'新代理检查未通过：'+(reasons.join('；')||'未收到完整检查结果。');
 return {success,backend:'clashCoexist',rulesToken:info.rulesToken,ip:ips.length===1?ips[0]:null,expectedIP:expectedIP||ips[0]||expectedHost||'',expectedHost,activeProfileID:profileID,scope:'servicesOnly',managedRelayHosts:RELAY_HOSTS,scopeLabel:'指定服务 · 与 Clash 共存',checkedAt:new Date().toISOString(),stage,endpoints,details};
}
async function prepare(loc,request,effects={}){const ctx=context(loc,effects),state=readJSON(loc.stateFile,{}),before=await live(loc,effects);assertReady(ctx,before,effects);const owned=ownership(loc,ctx,state);if(state.runtimeRulesToken&&state.runtimeRulesToken!==before.rulesToken&&!(owned&&owned.rebaseRequired))throw new Error('Clash 内存规则已被其他程序修改，未覆盖当前网络。');return {...makePrepared(loc,request,ctx,state),before,state,ownership:owned};}
async function preview(loc,request,effects={}){const p=await prepare(loc,request,effects);(effects.validate||legacy.validateCore)(loc,p.candidate);return {success:true,backend:'clashCoexist',scope:'servicesOnly',host:p.parsed.host,port:p.parsed.port,ruleCount:p.candidate.rules.length,details:'指定服务配置已校验，其他 Clash 设置保持原样；尚未应用。'};}
async function checkedPreflight(loc,prepared,effects={}){let result;try{result=await isolatedPreflight(loc,prepared,effects);if(!result.success||!result.ip)throw verificationError({...result,success:false,details:result.details||'新代理未返回完整出口检查。'});if(result.baselineRulesToken!==prepared.before.rulesToken)throw verificationError({...result,success:false,details:'Clash 内存规则与持久配置不一致。'});saveDiagnostic(loc,'preflight',result);return result;}catch(error){saveDiagnostic(loc,'preflight',error.verification||result,{error,restoration:{confirmed:true,message:'隔离预检失败，尚未应用；当前账号和网络保持原样。'}});throw new Error('隔离预检失败，尚未应用：'+safeError(error));}}
async function preflight(loc,request,effects={}){const p=await prepare(loc,request,effects);(effects.validate||legacy.validateCore)(loc,p.candidate);return checkedPreflight(loc,p,effects);}
function assertTransactionHashes(j){for(const[f,expected]of Object.entries(j.originalHashes||{})){const current=fileHash(f);if(current!==expected&&current!==(j.desiredHashes||{})[f])throw new Error('事务文件已被其他程序修改，未覆盖新修改。');}}
async function recover(loc,effects={}){const j=readJSON(loc.journalFile);if(!j)return;const ctx=context(loc,effects);if(ctx.current.uid!==j.currentProfileUID)throw new Error('未完成操作所属订阅已改变，未覆盖当前网络。');assertTransactionHashes(j);const now=await live(loc,effects);
 const unchanged=now.token===j.beforeToken,candidateConfirmed=j.afterToken?now.token===j.afterToken:!!j.candidateRulesToken&&now.rulesToken===j.candidateRulesToken&&equal(now.configs,j.previousLiveConfigs)&&equal(now.selections,j.previousSelections);
 if(!unchanged&&!candidateConfirmed)throw new Error('未完成操作的运行配置已变化；已保留备份，未覆盖当前网络。');restoreFiles(j.backupPath);if(!unchanged||j.afterToken||(j.reloadAttempted&&j.candidateRulesToken===now.rulesToken)){await reload(loc,j.previousConfiguration,effects);const restored=await live(loc,effects);if(restored.token!==j.beforeToken)throw new Error('恢复尚未确认，请保留备份并重试。');}fs.rmSync(loc.journalFile,{force:true});}
async function apply(loc,request,effects={}){const unlock=lock(loc);try{if(readJSON(loc.journalFile))throw new Error('上次切换未完成，请先点击跟随系统恢复。');const p=await prepare(loc,request,effects);(effects.validate||legacy.validateCore)(loc,p.candidate);const checked=await checkedPreflight(loc,p,effects);if(!checked.success||!checked.ip)throw new Error('新代理预检未通过，尚未改变网络。');if(checked.baselineRulesToken!==p.before.rulesToken)throw new Error('Clash 内存规则与持久配置不一致，尚未修改网络。');assertHashes(p.sourceHashes);const now=await live(loc,effects);if(now.token!==p.before.token)throw new Error('Clash 运行配置在预检期间发生变化，未应用。');const rebasing=p.ownership&&p.ownership.rebaseRequired,baselineRulesToken=rebasing?await isolatedRuleToken(loc,p.ownership.baselineRuntime,effects):p.state.baselineRulesToken,baselineBackup=rebasing?scopedBaselineBackup(loc,p.ownership):p.state.baselineBackup;assertHashes(p.sourceHashes);if((await live(loc,effects)).token!==p.before.token)throw new Error('Clash 运行配置在预检期间发生变化，未应用。');const files=[p.ctx.scriptFile,...(p.writeDNS?[loc.dnsFile]:[]),loc.runtimeFile,loc.stateFile],backupPath=backup(loc,files,'switch');const j={version:1,backupPath,currentProfileUID:p.ctx.current.uid,beforeToken:p.before.token,afterToken:null,previousConfiguration:p.ctx.runtime,previousLiveConfigs:p.before.configs,previousSelections:p.before.selections,candidateRulesToken:checked.rulesToken||null,originalHashes:hashes(files.filter(f=>f!==loc.stateFile)),desiredHashes:{[p.ctx.scriptFile]:sha(p.script),...(p.writeDNS?{[loc.dnsFile]:sha(legacy.dumpYAML(p.dns))}:{}),[loc.runtimeFile]:sha(legacy.dumpYAML(p.candidate))},writtenHashes:{}};atomicWrite(loc.journalFile,j);
 let verification=null,phase='postApply';try{atomicWrite(p.ctx.scriptFile,p.script);if(p.writeDNS)atomicWrite(loc.dnsFile,legacy.dumpYAML(p.dns));atomicWrite(loc.runtimeFile,legacy.dumpYAML(p.candidate));j.writtenHashes=hashes(files.filter(f=>f!==loc.stateFile));j.reloadAttempted=true;atomicWrite(loc.journalFile,j);await reload(loc,p.candidate,effects);const after=await live(loc,effects);j.afterToken=after.token;atomicWrite(loc.journalFile,j);assertLivePreserved(p.before,after);const result=verification=await (effects.verify||verifyEndpoints)(loc,effects,{profileID:p.profile.id,expectedHost:p.parsed.host,expectedIP:checked.ip,stage:'postApply'});if(!result.success)throw verificationError(result);if((await live(loc,effects)).token!==after.token)throw new Error('验证期间 Clash 运行配置已变化，未确认启用。');assertHashes(j.writtenHashes);const state={version:1,backend:'clashCoexist',activeProfileID:p.profile.id,name:p.profile.name,ip:result.ip,host:p.parsed.host,port:p.parsed.port,scope:'servicesOnly',currentProfileUID:p.ctx.current.uid,scriptPath:p.ctx.scriptFile,baselineBackup:baselineBackup||backupPath,baselineRulesToken:baselineRulesToken||p.before.rulesToken,runtimeRulesToken:after.rulesToken,latestBackup:backupPath,managedHashes:hashes(files.filter(f=>f!==loc.stateFile)),runtimeSemanticHash:runtimeSemanticHash(p.candidate),settingsHash:p.settingsHash,appliedAt:new Date().toISOString()};saveDiagnostic(loc,phase,result);atomicWrite(loc.stateFile,state);fs.rmSync(loc.journalFile,{force:true});return {...result,networkReady:true,backupPath,backend:'clashCoexist'};}catch(e){let restoration='',restored=false;try{await recover(loc,effects);restored=true;restoration=' 已恢复切换前配置'+(p.state.ip?'（'+p.state.ip+'）':'')+'。';}catch(r){restoration=' 自动恢复未完成：'+safeError(r)+'；备份已保留。';}saveDiagnostic(loc,phase,e.verification||verification,{error:e,restoration:{confirmed:restored,message:restoration.trim()}});throw new Error((verification?'切换后验证失败：':'切换应用失败：')+safeError(e)+restoration);}
 }finally{unlock();}}
async function verify(loc,request={},effects={}){const s=readJSON(loc.stateFile,{}),ctx=context(loc,effects);if(!s.activeProfileID)throw new Error('尚未启用账号。');ownership(loc,ctx,s);return verifyEndpoints(loc,effects,{profileID:s.activeProfileID,expectedHost:s.host,expectedIP:s.ip});}
async function useSystemProxy(loc,effects={}){const unlock=lock(loc);try{
 await recover(loc,effects);const state=readJSON(loc.stateFile,{});
 if(!state.activeProfileID)return {success:true,backend:'clashCoexist',proxyMode:'system',systemProxyConfirmed:true,details:'继续使用 Clash 原有网络。'};
 const ctx=context(loc,effects),owned=ownership(loc,ctx,state),before=await live(loc,effects);assertReady(ctx,before,effects);
 if(state.runtimeRulesToken&&before.rulesToken!==state.runtimeRulesToken&&!(owned&&owned.rebaseRequired))throw new Error('Clash 内存规则已被其他程序修改，未覆盖当前网络。');
 const sources=hashes(sourceFiles(loc,ctx)),rebasing=owned&&owned.rebaseRequired;
 if(rebasing&&await isolatedRuleToken(loc,ctx.runtime,effects)!==before.rulesToken)throw new Error('Clash 内存规则与持久配置不一致，未撤回账号覆盖。');
 const candidateRulesToken=rebasing?await isolatedRuleToken(loc,owned.baselineRuntime,effects):state.baselineRulesToken||null;
 const baselinePath=rebasing?scopedBaselineBackup(loc,owned):state.baselineBackup,baseline=readJSON(path.join(baselinePath,'manifest.json'));
 if(!baseline)throw new Error('缺少接管前备份，未改动当前网络。');
 assertHashes(sources);if((await live(loc,effects)).token!==before.token)throw new Error('Clash 运行配置在恢复准备期间发生变化，未改动当前网络。');
 const backupPath=backup(loc,baseline.files.map(x=>x.path),'before-stop'),runtimeEntry=baseline.files.find(x=>x.path===loc.runtimeFile),config=yaml.load(fs.readFileSync(path.join(baselinePath,runtimeEntry.name),'utf8'));
 const j={version:1,currentProfileUID:ctx.current.uid,backupPath,beforeToken:before.token,afterToken:null,previousConfiguration:ctx.runtime,previousLiveConfigs:before.configs,previousSelections:before.selections,candidateRulesToken,originalHashes:hashes(baseline.files.filter(x=>x.path!==loc.stateFile).map(x=>x.path)),desiredHashes:Object.fromEntries(baseline.files.filter(x=>x.path!==loc.stateFile).map(x=>[x.path,x.hash])),writtenHashes:{}};
 atomicWrite(loc.journalFile,j);try{
  restoreFiles(baselinePath);j.writtenHashes=hashes(baseline.files.filter(x=>x.path!==loc.stateFile).map(x=>x.path));j.reloadAttempted=true;atomicWrite(loc.journalFile,j);
  await reload(loc,config,effects);const after=await live(loc,effects);j.afterToken=after.token;atomicWrite(loc.journalFile,j);assertLivePreserved(before,after);
  if(candidateRulesToken&&after.rulesToken!==candidateRulesToken)throw new Error('撤回后的规则校验未通过。');
  fs.rmSync(loc.stateFile,{force:true});fs.rmSync(loc.journalFile,{force:true});return {success:true,backend:'clashCoexist',proxyMode:'system',systemProxyConfirmed:true,details:'已撤回 ccmiss 指定服务配置，保留最新订阅、Clash 和已有连接。'};
 }catch(e){try{await recover(loc,effects);}catch(r){throw new Error(safeError(e)+' 恢复未完成：'+safeError(r));}throw new Error(safeError(e)+' 已回到停用前配置。');}
}finally{unlock();}}
async function dispatch(request,options={}){const loc=options.loc||locations(),effects=options.effects||{};switch(request.operation){case'status':return status(loc,effects);case'setupStatus':return setupStatus(loc,effects);case'preview':return preview(loc,request,effects);case'preflight':return preflight(loc,request,effects);case'apply':case'initialize':return apply(loc,request,effects);case'verify':return verify(loc,request,effects);case'useSystemProxy':case'restore':return useSystemProxy(loc,effects);default:throw new Error('未知共存网络操作。');}}
module.exports={locations,detect,setupStatus,status,apply,verify,useSystemProxy,preview,preflight,dispatch,api,live,makePrepared,transform,patchPolicy,withoutOverlay,assertScoped,makeScript,stripScript,overlayRules,verifyEndpoints,curl,saveDiagnostic,recover,hashes,sha,runtimeSemanticHash,ruleShape,ipv6Safe,GROUP_NAME,NODE_NAME,UPSTREAM_NAME,SERVICE_DOMAINS,CHECK_DOMAINS,CHECK_IPS,RELAY_HOSTS};
if(require.main===module)(async()=>{process.stdin.setEncoding('utf8');let input='';for await(const c of process.stdin){input+=c;if(input.length>1024*1024)throw new Error('输入过大。');}process.stdout.write(JSON.stringify({ok:true,result:await dispatch(JSON.parse(input))})+'\n');})().catch(e=>{process.stdout.write(JSON.stringify({ok:false,error:safeError(e)})+'\n');process.exitCode=1;});
