#!/usr/bin/env node
'use strict';

// No credentials are accepted in argv, printed to stderr, or persisted in metadata.
// Clash itself necessarily stores the active SOCKS credentials in its private config.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const vm = require('node:vm');
const crypto = require('node:crypto');
const {spawn, spawnSync} = require('node:child_process');
const yaml = require('./js-yaml.cjs');

const NODE_NAME = 'Account Proxy Active';
const GROUP_NAME = 'Claude 专用出口';
const START_MARKER = '// BEGIN ACCOUNT PROXY SWITCHER MANAGED';
const END_MARKER = '// END ACCOUNT PROXY SWITCHER MANAGED';
// Public defaults contain service domains only. Local enterprise rules remain
// in the user's private runtime configuration and are never shipped as presets.
const MANAGED_RELAY_HOSTS = [];
const MANAGEMENT_DIRECT_RULES = [];
const SERVICE_DOMAINS = [
  'anthropic.com', 'claude.ai', 'claude.com', 'claude.app',
  'claudeusercontent.com', 'claudemcpcontent.com', 'cloudflare.com',
  'cloudflare.net', 'cloudflareinsights.com', 'cloudflare-dns.com',
  'dnstest.dev', 'one.one.one.one', 'stripe.com', 'stripe.network',
  'stripecdn.com', 'link.com', 'stripe.dev', 'stripe.events',
  'stripe.global', 'hcaptcha.com'
];
const COMPANY_DOMAINS = [];
const GENERIC_ROUTING_CONTEXT={version:1,legacy:false,serviceDomains:SERVICE_DOMAINS,
  managedRelayHosts:[],companyDomains:[],managementDirectRules:[],privateDNSDefaults:{}};
// Retain the migration shape without embedding any installation's private data.
const LEGACY_ROUTING_CONTEXT={...GENERIC_ROUTING_CONTEXT,legacy:true};
const PRIVATE_RANGES = ['0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10',
  '127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16'];
const CONTROL_KEYS = ['external-controller', 'external-controller-unix',
  'external-controller-cors', 'secret', 'mixed-port', 'socks-port', 'port',
  'redir-port', 'mode', 'allow-lan', 'log-level', 'ipv6', 'unified-delay'];
const clone = value => JSON.parse(JSON.stringify(value));
const isObject = value => value && typeof value === 'object' && !Array.isArray(value);
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let secretValues = [];
function scopeLabel(scope,relayHosts=[]) {
  return scope==='fullPublic'?'全部公网（保留直连例外）':relayHosts.length===2?'指定服务（含两个业务中转）':
    relayHosts.length?'指定服务（含业务中转）':'指定服务';
}

function safeError(error) {
  let message = String(error && error.message || error || '未知错误');
  for (const secret of secretValues.filter(Boolean).sort((a,b) => b.length-a.length)) {
    message = message.split(secret).join('[已隐藏]');
  }
  return message.replace(/socks5h?:\/\/[^\s"']+/gi, 'socks5://[凭据已隐藏]')
    .replace(/("?(?:password|username|secret)"?\s*[:=]\s*)[^,\n}]+/gi, '$1[已隐藏]')
    .slice(0, 1800);
}

function privateDir(directory) {
  fs.mkdirSync(directory, {recursive:true, mode:0o700});
  fs.chmodSync(directory, 0o700);
}

function atomicWrite(filename, contents) {
  privateDir(path.dirname(filename));
  const temporary = filename + '.account-proxy-' + crypto.randomBytes(5).toString('hex');
  fs.writeFileSync(temporary, contents, {mode:0o600, flag:'wx'});
  const fd = fs.openSync(temporary, 'r');
  fs.fsyncSync(fd); fs.closeSync(fd);
  fs.renameSync(temporary, filename);
  fs.chmodSync(filename, 0o600);
}

function readJSON(filename, fallback = null) {
  try { return JSON.parse(fs.readFileSync(filename, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
}

function readYAML(filename) {
  const value = yaml.load(fs.readFileSync(filename, 'utf8')) || {};
  if (!isObject(value)) throw new Error('Clash 配置格式不正确：' + path.basename(filename));
  return value;
}

function dumpYAML(value) { return yaml.dump(value, {lineWidth:-1, noRefs:true, sortKeys:false}); }

function locations(options = {}) {
  const home = os.homedir();
  const configDirectory = options.configDirectory || path.join(home,
    'Library/Application Support/io.github.clash-verge-rev.clash-verge-rev');
  const dataDirectory = options.dataDirectory || path.join(home,
    'Library/Application Support/AccountProxySwitcher');
  const uid = typeof process.getuid === 'function' ? process.getuid() : 501;
  return {
    configDirectory, dataDirectory,
    profilesFile: path.join(configDirectory, 'profiles.yaml'),
    baseFile: path.join(configDirectory, 'config.yaml'),
    vergeFile: path.join(configDirectory, 'verge.yaml'),
    dnsFile: path.join(configDirectory, 'dns_config.yaml'),
    runtimeFile: path.join(configDirectory, 'clash-verge.yaml'),
    stateFile: path.join(dataDirectory, 'engine-state.json'),
    journalFile: path.join(dataDirectory, 'transaction.json'),
    lockFile: path.join(dataDirectory, 'engine.lock'),
    socket: options.socket || `/var/run/clash-verge-service/users/${uid}/verge-mihomo.sock`,
    core: options.core || '/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo'
  };
}

function parseSOCKS(profile) {
  if (!profile || typeof profile.socksURL !== 'string') throw new Error('请先填写 SOCKS5 地址。');
  let url;
  try { url = new URL(profile.socksURL.trim()); }
  catch { throw new Error('SOCKS5 地址格式不正确。'); }
  if (!['socks5:', 'socks5h:'].includes(url.protocol)) throw new Error('只支持 socks5:// 或 socks5h:// 地址。');
  if (!url.hostname || !url.port || !/^\d+$/.test(url.port)) throw new Error('地址必须包含主机和端口。');
  const port = Number(url.port);
  if (port < 1 || port > 65535) throw new Error('端口必须在 1–65535 之间。');
  if (url.pathname && url.pathname !== '/' || url.search || url.hash) throw new Error('SOCKS5 地址不能包含路径、查询参数或片段。');
  let username, password;
  try { username = decodeURIComponent(url.username); password = decodeURIComponent(url.password); }
  catch { throw new Error('用户名或密码包含无效的 URL 转义。'); }
  if (/[\x00-\x1f\x7f]/.test(username + password + url.hostname)) throw new Error('地址中不能包含控制字符。');
  secretValues.push(profile.socksURL, username, password);
  return {host:url.hostname.replace(/^\[|\]$/g,''), port, username, password};
}

function ipv6RouteExists() {
  // DNS AAAA suppression alone is insufficient if a physical IPv6 default route exists.
  const probe=spawnSync('/sbin/route',['-n','get','-inet6','default'],{encoding:'utf8',timeout:2500});
  return probe.status===0 && /^\s*interface:\s*\S+/m.test(probe.stdout || '');
}

function resolveContext(loc) {
  for (const file of [loc.profilesFile, loc.baseFile, loc.vergeFile, loc.runtimeFile]) {
    if (!fs.existsSync(file)) throw new Error('未找到 Clash Verge 配置。请安装并启动 Clash Verge Rev。');
  }
  const metadata = readYAML(loc.profilesFile);
  const current = (metadata.items || []).find(item => item.uid === metadata.current);
  if (!current || !current.file || !['remote','local'].includes(current.type)) {
    throw new Error('当前 Clash 主配置不可用。请先选择一个可用订阅。');
  }
  const profileDirectory = path.join(loc.configDirectory, 'profiles');
  const resolveItem = (uid, fallback, extension) => {
    const id = Array.isArray(uid) ? uid[0] : uid;
    const item = (metadata.items || []).find(item => item.uid === (id || fallback));
    const filename = path.join(profileDirectory, item && item.file || `${fallback}.${extension}`);
    if (!filename.startsWith(profileDirectory + path.sep)) throw new Error('配置文件路径越界。');
    return filename;
  };
  const option = current.option || {};
  for (const key of ['merge','script','rules','proxies','groups']) {
    if (Array.isArray(option[key]) && option[key].length > 1) {
      throw new Error('当前订阅使用多段增强链；请先在 Clash 中合并为单段后再切换。');
    }
  }
  const scriptFile = resolveItem(option.script, 'Script', 'js');
  return {metadata, current, profileDirectory, scriptFile,
    rawFile: path.join(profileDirectory, current.file),
    mergeFile: resolveItem(option.merge, 'Merge', 'yaml'),
    rulesFile: resolveItem(option.rules, 'Rules', 'yaml'),
    proxiesFile: resolveItem(option.proxies, 'Proxies', 'yaml'),
    groupsFile: resolveItem(option.groups, 'Groups', 'yaml'),
    globalMergeFile: resolveItem('Merge', 'Merge', 'yaml'),
    globalScriptFile: resolveItem('Script', 'Script', 'js'),
    base: readYAML(loc.baseFile), verge: readYAML(loc.vergeFile),
    dns: fs.existsSync(loc.dnsFile) ? readYAML(loc.dnsFile) : {},
    runtime: readYAML(loc.runtimeFile)};
}

function deepMerge(target, overlay) {
  if (!isObject(target) || !isObject(overlay)) return clone(overlay);
  for (const [key, value] of Object.entries(overlay)) {
    target[key] = isObject(value) && isObject(target[key]) ? deepMerge(target[key], value) : clone(value);
  }
  return target;
}

// Mirrors v2.5.8 enhance/merge.rs: DNS merges one level and hosts replaces.
function mergeProfile(config, overlay) {
  for (const [rawKey, value] of Object.entries(overlay || {})) {
    const key = rawKey.toLowerCase();
    if (key === 'dns' && isObject(config[key]) && isObject(value)) config[key] = {...config[key], ...clone(value)};
    else if (key === 'hosts') config[key] = clone(value);
    else config[key] = key in config ? deepMerge(config[key], value) : clone(value);
  }
  return config;
}

function sequence(config, file, field) {
  if (!fs.existsSync(file)) return config;
  const seq = readYAML(file);
  const deleted = new Set(seq.delete || []);
  config[field] = (seq.prepend || []).concat((config[field] || []).filter(value =>
    !deleted.has(typeof value === 'string' ? value : value.name)), seq.append || []);
  if (field === 'proxies') {
    const added = (seq.prepend || []).concat(seq.append || []).map(value => value.name).filter(Boolean);
    let firstSelector = true;
    for (const group of config['proxy-groups'] || []) {
      if (Array.isArray(group.proxies)) group.proxies = group.proxies.filter(value => !deleted.has(value));
      if (firstSelector && added.length && ['select','selector'].includes(String(group.type).toLowerCase())) {
        group.proxies = [...new Set(added.concat(group.proxies || []))]; firstSelector = false;
      }
    }
  }
  return config;
}

function evaluateScript(source, config, profileName) {
  const context = vm.createContext({config:clone(config), profileName:String(profileName || ''),
    console:{log(){},warn(){},error(){},info(){},debug(){}}});
  const program = new vm.Script(source + '\n; if(typeof main!=="function") throw new Error("缺少 main 函数"); main(config, profileName);');
  const result = program.runInContext(context, {timeout:2500});
  if (!isObject(result)) throw new Error('Clash 增强脚本没有返回配置对象。');
  return clone(result);
}

function currentNode(runtime) {
  const nodes = runtime.proxies || [];
  const group = (runtime['proxy-groups'] || []).find(value => value.name === GROUP_NAME);
  const preferred = group && (group.proxies || []).map(name => nodes.find(value => value.name === name)).find(Boolean);
  return preferred || nodes.find(value => value.name === NODE_NAME) || nodes.find(value => /^Claude ISP /.test(value.name || ''));
}

function privateResolver(value) {
  const text = String(value).replace(/^(?:tls|udp|tcp):\/\//,'').split(/[:#]/)[0];
  if (text === '::1' || text.startsWith('fc') || text.startsWith('fd')) return true;
  const match = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(text);
  if (!match) return false;
  const a = Number(match[1]), b = Number(match[2]);
  return a === 10 || a === 127 || a === 192 && b === 168 || a === 172 && b >=16 && b<=31 || a === 169 && b ===254;
}

function customDirectRules(ctx,routingContext=LEGACY_ROUTING_CONTEXT) {
  const sequence=fs.existsSync(ctx.rulesFile)?readYAML(ctx.rulesFile):{};
  const additions=[];
  for(const file of [...new Set([ctx.mergeFile,ctx.globalMergeFile])]){
    if(fs.existsSync(file)){
      const merge=readYAML(file);
      for(const field of ['rules','prepend-rules','append-rules'])if(Array.isArray(merge[field]))additions.push(...merge[field]);
    }
  }
  // These are the user's explicit rules only. Do not import the subscription's CN bypass list.
  return [...new Set((sequence.prepend||[]).concat(sequence.append||[],additions)
    .filter(rule=>typeof rule==='string'&&/,DIRECT(?:,no-resolve)?$/.test(rule))
    .filter(rule=>{
      const parts=rule.split(',');
      return !(parts[0]==='DOMAIN'&&routingContext.managedRelayHosts.includes(parts[1]));
    }))];
}

function policyMatchesDirectDomain(key,rules) {
  const policyDomain=String(key).replace(/^[+*]\./,'');
  return rules.some(rule=>{
    const parts=rule.split(','),domain=parts[1];
    if(parts[0]==='DOMAIN')return policyDomain===domain;
    if(parts[0]==='DOMAIN-SUFFIX')return policyDomain===domain||policyDomain.endsWith('.'+domain);
    if(parts[0]==='DOMAIN-KEYWORD')return policyDomain.includes(domain);
    return false;
  });
}

function makeDNS(ctx, scope,routingContext=LEGACY_ROUTING_CONTEXT) {
  const dns = clone(ctx.runtime.dns || ctx.dns.dns || {});
  const mergeDNS = fs.existsSync(ctx.mergeFile) ? readYAML(ctx.mergeFile).dns || {} : {};
  const mergedPolicy = {...mergeDNS['nameserver-policy'], ...(dns['nameserver-policy'] || {})};
  const explicitDirect=customDirectRules(ctx,routingContext);
  const privatePolicies = {};
  for (const [key, value] of Object.entries(mergedPolicy)) {
    const values = Array.isArray(value) ? value : [value];
    if (values.length && values.every(privateResolver)) privatePolicies[key] = clone(value);
  }
  // Legacy defaults are retained only for existing installations; new users get no company domains.
  for(const[key,value]of Object.entries(routingContext.privateDNSDefaults||{})){
    if(!privatePolicies[key])privatePolicies[key]=clone(value);
  }
  const policy = scope === 'fullPublic' ? privatePolicies : {...clone(dns['nameserver-policy'] || {}), ...privatePolicies};
  // Business relays and other explicit DIRECT domains retain their original resolver path.
  // Matching merge policies recover exceptions shadowed by the GUI's previous DNS override.
  for(const [key,value]of Object.entries(mergedPolicy)){
    if(policyMatchesDirectDomain(key,explicitDirect))policy[key]=clone(value);
  }
  // Remove inherited exact policies before adding suffix policies. Exact relay DNS entries
  // would otherwise keep domestic resolvers even though the traffic now uses the selected ISP.
  for(const key of Object.keys(policy)){
    const domain=key.replace(/^[+*]\./,'');
    if(routingContext.serviceDomains.some(suffix=>domain===suffix||domain.endsWith('.'+suffix)))delete policy[key];
  }
  for (const domain of routingContext.serviceDomains) policy['+.' + domain] = ['https://1.1.1.1/dns-query#' + GROUP_NAME];
  for (const domain of ['http-intake.logs.us5.datadoghq.com','browser-intake-us5-datadoghq.com']) {
    policy[domain] = ['https://1.1.1.1/dns-query#' + GROUP_NAME];
  }
  dns.enable = true; dns.ipv6 = false;
  dns.nameserver = ['https://1.1.1.1/dns-query#' + GROUP_NAME];
  dns.fallback = ['https://1.0.0.1/dns-query#' + GROUP_NAME];
  dns['nameserver-policy'] = policy;
  dns['direct-nameserver'] = [];
  dns['direct-nameserver-follow-policy'] = true;
  dns['proxy-server-nameserver'] = clone(Array.isArray(dns['proxy-server-nameserver'])&&dns['proxy-server-nameserver'].length?dns['proxy-server-nameserver']:['https://1.1.1.1/dns-query']);
  dns['default-nameserver'] = clone(Array.isArray(dns['default-nameserver'])&&dns['default-nameserver'].length?dns['default-nameserver']:['1.1.1.1','8.8.8.8']);
  dns['respect-rules'] = false; dns['prefer-h3'] = false;
  dns['enhanced-mode'] = 'fake-ip';
  dns['fake-ip-filter'] = [...new Set((dns['fake-ip-filter'] || []).concat(routingContext.companyDomains.map(domain=>'+.'+domain),['*.lan','*.local','*.arpa']))];
  return {...clone(ctx.dns), dns};
}

// Self-contained: the exact same function runs in Clash Verge's script sandbox.
function managedTransform(config, settings) {
  var nodeName = 'Account Proxy Active', groupName = 'Claude 专用出口';
  var nodes = Array.isArray(config.proxies) ? config.proxies : [];
  var groups = Array.isArray(config['proxy-groups']) ? config['proxy-groups'] : [];
  var available = nodes.map(function(p){return p.name;}).concat(groups.map(function(g){return g.name;}));
  var directTransport=settings.connectionMode==='direct';
  var dialer = available.indexOf(settings.dialerProxy) >= 0 ? settings.dialerProxy :
    settings.allowLegacyUSFallback?nodes.map(function(p){return p.name;}).find(function(name){return /^🇺🇸 美国/.test(name) && !/备用|最快/.test(name);}):null;
  if (!directTransport&&(!dialer || dialer === groupName || dialer === nodeName || dialer === 'DIRECT' || dialer === 'REJECT')) {
    throw new Error('专用 SOCKS5 的前置代理节点不可用，已拒绝直连回退。');
  }
  var node = {name:nodeName,type:'socks5',server:settings.node.host,port:settings.node.port,udp:false};
  if(!directTransport)node['dialer-proxy']=dialer;
  if(settings.node.username)node.username=settings.node.username;
  if(settings.node.password)node.password=settings.node.password;
  var oldNames = nodes.filter(function(p){return p.name===nodeName || /^Claude ISP /.test(p.name || '');}).map(function(p){return p.name;});
  config.proxies = nodes.filter(function(p){return oldNames.indexOf(p.name)<0;}).concat([node]);
  config['proxy-groups'] = groups.filter(function(g){return g.name!==groupName;}).map(function(g){
    if(Array.isArray(g.proxies))g.proxies=g.proxies.map(function(n){return oldNames.indexOf(n)>=0?nodeName:n;}).filter(function(n,i,a){return a.indexOf(n)===i;});
    return g;
  }).concat([{name:groupName,type:'select',proxies:[nodeName]}]);
  var domains=settings.serviceDomains;
  var managedRule=function(rule){
    return String(rule).indexOf(','+groupName)>=0 || String(rule).indexOf(','+nodeName)>=0;
  };
  var directRules=Array.isArray(settings.customDirectRules)?settings.customDirectRules:[];
  var relayHosts=settings.managedRelayHosts||[];
  var previous=(Array.isArray(config.rules)?config.rules:[]).filter(function(rule){
    var parts=String(rule).split(',');
    var oldRelayDirect=parts[0]==='DOMAIN'&&relayHosts.indexOf(parts[1])>=0&&parts[2]==='DIRECT';
    return !managedRule(rule)&&!oldRelayDirect&&directRules.indexOf(rule)<0;
  });
  var local=settings.privateRanges.map(function(ip){return 'IP-CIDR,'+ip+',DIRECT,no-resolve';})
    .concat(['IP-CIDR6,::1/128,DIRECT,no-resolve','IP-CIDR6,fc00::/7,DIRECT,no-resolve','IP-CIDR6,fe80::/10,DIRECT,no-resolve',
      'DOMAIN-SUFFIX,local,DIRECT','DOMAIN-SUFFIX,lan,DIRECT','DOMAIN,localhost,DIRECT'])
    .concat(settings.companyDomains.map(function(domain){return 'DOMAIN-SUFFIX,'+domain+',DIRECT';}));
  var managementDirect=Array.isArray(settings.managementDirectRules)?settings.managementDirectRules:[];
  var preserved=local.concat(managementDirect,directRules).filter(function(rule,i,all){return all.indexOf(rule)===i;});
  if(settings.scope==='fullPublic'){
    config.rules=preserved.concat(['NETWORK,UDP,REJECT','MATCH,'+groupName]);
  }else{
    var serviceRules=domains.map(function(d){return 'AND,((NETWORK,UDP),(DOMAIN-SUFFIX,'+d+')),REJECT';})
      .concat(domains.map(function(d){return 'DOMAIN-SUFFIX,'+d+','+groupName;}));
    ['http-intake.logs.us5.datadoghq.com','browser-intake-us5-datadoghq.com'].forEach(function(d){
      serviceRules.push('AND,((NETWORK,UDP),(DOMAIN,'+d+')),REJECT','DOMAIN,'+d+','+groupName);
    });
    ['1.1.1.1/32','1.0.0.1/32','160.79.104.0/23'].forEach(function(ip){
      serviceRules.push('AND,((NETWORK,UDP),(IP-CIDR,'+ip+',no-resolve)),REJECT','IP-CIDR,'+ip+','+groupName+',no-resolve');
    });
    serviceRules.push('AND,((NETWORK,UDP),(IP-CIDR6,2607:6bc0::/48,no-resolve)),REJECT','IP-CIDR6,2607:6bc0::/48,'+groupName+',no-resolve');
    config.rules=preserved.concat(serviceRules,previous);
  }
  config.dns=settings.dns;
  config.sniffer={enable:true,'force-dns-mapping':true,'parse-pure-ip':true,'override-destination':false,
    sniff:{HTTP:{ports:[80,'8080-8880']},TLS:{ports:[443,8443]},QUIC:{ports:[443,8443]}}};
  return config;
}

function makeScript(original, settings) {
  let source = original;
  if (source.includes(START_MARKER)) {
    source = source.slice(0, source.indexOf(START_MARKER)).replace(/function\s+accountProxyPreviousMain\s*\(/, 'function main(').trimEnd() + '\n';
  }
  if (!/function\s+main\s*\(/.test(source)) throw new Error('当前增强脚本的 main 入口无法识别，未更改配置。');
  // Update the known legacy injection rather than leaving an old credential in active code.
  source = source.replace(/const node\s*=\s*\{[^\n;]+\};/, originalNode => {
    if(!/["']name["']\s*:\s*["'](?:Claude ISP |Account Proxy Active)/.test(originalNode))return originalNode;
    return 'const node = ' + JSON.stringify({name:NODE_NAME,type:'socks5',server:settings.node.host,port:settings.node.port,
      username:settings.node.username,password:settings.node.password,udp:false,'dialer-proxy':settings.dialerProxy}) + ';';
  });
  source = source.replace(/function\s+main\s*\(/, 'function accountProxyPreviousMain(');
  return source.trimEnd() + '\n\n' + START_MARKER + '\n' +
    'function main(config, profileName) {\n' +
    '  var prior = accountProxyPreviousMain(config, profileName);\n' +
    (settings.profileNameGuard!==undefined?'  if (profileName !== '+JSON.stringify(settings.profileNameGuard)+') return prior;\n':'')+
    '  return (' + managedTransform.toString() + ')(prior, ' + JSON.stringify(settings) + ');\n}\n' + END_MARKER + '\n';
}

function buildCandidate(loc, ctx, scriptText, dnsConfig) {
  let config = readYAML(ctx.rawFile);
  config = sequence(config, ctx.rulesFile, 'rules');
  config = sequence(config, ctx.proxiesFile, 'proxies');
  config = sequence(config, ctx.groupsFile, 'proxy-groups');
  for (const [key,value] of Object.entries(ctx.base)) {
    if (key === 'tun') config.tun = {...(config.tun || {}), ...clone(value)};
    else config[key] = clone(value);
  }
  if (!ctx.verge.verge_socks_enabled) delete config['socks-port'];
  if (!ctx.verge.verge_http_enabled) delete config.port;
  if (!ctx.verge.verge_redir_enabled) delete config['redir-port'];
  if (!ctx.verge.enable_external_controller) config['external-controller'] = '';
  config.tun = {...(config.tun || {}), enable:ctx.verge.enable_tun_mode === true};
  config.dns = {...(config.dns || {}), ...clone(dnsConfig.dns || {})};
  if ('hosts' in dnsConfig) config.hosts = clone(dnsConfig.hosts);
  const authoritative = {};
  for (const key of CONTROL_KEYS) if (key in config) authoritative[key] = clone(config[key]);
  const tun = clone(config.tun);
  const dns = clone(dnsConfig.dns);
  if (fs.existsSync(ctx.globalMergeFile)) config = mergeProfile(config, readYAML(ctx.globalMergeFile));
  if (fs.existsSync(ctx.globalScriptFile) && ctx.globalScriptFile !== ctx.scriptFile) {
    config = evaluateScript(fs.readFileSync(ctx.globalScriptFile,'utf8'), config, ctx.current.name);
  }
  if (fs.existsSync(ctx.mergeFile) && ctx.mergeFile !== ctx.globalMergeFile) config = mergeProfile(config, readYAML(ctx.mergeFile));
  config = evaluateScript(scriptText, config, ctx.current.name);
  for (const key of CONTROL_KEYS) { if (key in authoritative) config[key]=authoritative[key]; else delete config[key]; }
  config.tun = {...(config.tun || {}), ...tun};
  config.dns = {...(config.dns || {}), ...dns};
  if ('hosts' in dnsConfig) config.hosts = clone(dnsConfig.hosts);
  config.mode = 'rule';
  config.ipv6 = false;
  // The service overrides this endpoint at launch. Preserve the GUI's configured endpoint.
  config['external-controller-unix'] = ctx.runtime['external-controller-unix'] || ctx.base['external-controller-unix'];
  assertCandidate(config);
  return config;
}

function assertCandidate(config) {
  const node = (config.proxies || []).filter(proxy => proxy.name === NODE_NAME);
  const group = (config['proxy-groups'] || []).filter(proxy => proxy.name === GROUP_NAME);
  if (node.length !== 1 || group.length !== 1 || group[0].proxies.length !== 1 || group[0].proxies[0] !== NODE_NAME) {
    throw new Error('专用出口配置未保持单一节点，拒绝应用。');
  }
  if (node[0].udp !== false || node[0]['dialer-proxy']&&['DIRECT',GROUP_NAME,NODE_NAME].includes(node[0]['dialer-proxy'])) {
    throw new Error('前置代理或 UDP 防回退配置无效。');
  }
  if (!(config.tun && config.tun.enable && config.tun['auto-route'])) throw new Error('请先在 Clash Verge 开启 TUN 和自动路由。');
  if (config.ipv6 !== false || config.mode !== 'rule') throw new Error('规则模式或 IPv6 设置无效。');
}

function routingContextFor(loc,ctx) {
  const state=readJSON(loc.stateFile,{});
  if(state.routingContext&&Array.isArray(state.routingContext.serviceDomains))return clone(state.routingContext);
  return clone(state.activeProfileID||state.baselineBackup||currentNode(ctx.runtime)?LEGACY_ROUTING_CONTEXT:GENERIC_ROUTING_CONTEXT);
}

function scriptSource(ctx) {
  return fs.existsSync(ctx.scriptFile)?fs.readFileSync(ctx.scriptFile,'utf8'):'function main(config, profileName) { return config; }\n';
}

function assertScriptPlacement(ctx) {
  const option=ctx.current.option||{};
  const configuredScript=Array.isArray(option.script)?option.script[0]:option.script;
  if(configuredScript&&!(ctx.metadata.items||[]).some(item=>item.uid===configuredScript&&item.type==='script')){
    throw new Error('当前订阅绑定的 Script 增强项不存在，请先在 Clash 中修复绑定。');
  }
  const usesFallback=!option.script||(Array.isArray(option.script)&&!option.script.length)||ctx.scriptFile===ctx.globalScriptFile;
  if(usesFallback){
    if(!(ctx.metadata.items||[]).some(item=>item.uid==='Script'))throw new Error('Clash 缺少默认全局 Script 增强项，请先修复 Clash 配置。');
    if(!ctx.current.name||(ctx.metadata.items||[]).filter(item=>['remote','local'].includes(item.type)&&item.name===ctx.current.name).length!==1){
      throw new Error('当前订阅名称为空或重复；请在 Clash 中使用唯一名称后初始化，避免影响其他订阅。');
    }
  }
  if(!/function\s+(?:main|accountProxyPreviousMain)\s*\(/.test(scriptSource(ctx)))throw new Error('当前 Script 入口形式不受支持，未修改配置。');
  return usesFallback;
}

function dnsOverrideEnabled(ctx) {
  const scoped=ctx.verge.profile_dns_settings&&ctx.verge.profile_dns_settings[ctx.current.uid];
  return !!(scoped?scoped.enabled:ctx.verge.enable_dns_settings);
}

function prepare(loc, profile, scope,options={}) {
  if (!['fullPublic','servicesOnly'].includes(scope)) throw new Error('请选择完整公网或三家服务模式。');
  if (!profile.id || !profile.name || String(profile.name).length > 150) throw new Error('配置缺少名称或标识。');
  const parsed = parseSOCKS(profile);
  if(ipv6RouteExists())throw new Error('检测到 IPv6 默认路由。当前专用代理仅支持 IPv4；请先在 macOS 网络设置关闭公网 IPv6，避免其他地址绕过所选出口。');
  const ctx = resolveContext(loc);
  if (ctx.base.mode !== 'rule' || ctx.base.ipv6 !== false || ctx.verge.enable_tun_mode !== true) {
    throw new Error('请先在 Clash Verge 开启 TUN、切换规则模式并关闭 IPv6，再应用账号配置。');
  }
  const usesFallback=assertScriptPlacement(ctx);
  const routingContext=options.routingContext||routingContextFor(loc,ctx);
  if(!routingContext.legacy&&dnsOverrideEnabled(ctx)&&(ctx.metadata.items||[]).filter(item=>['remote','local'].includes(item.type)).length>1){
    throw new Error('多个主订阅共用 DNS 覆盖文件。请先在 Clash 中关闭当前订阅的 DNS 覆盖，再初始化；软件将用脚本管理 DNS，避免影响其他订阅。');
  }
  const state=readJSON(loc.stateFile,{});
  const oldNode = currentNode(ctx.runtime);
  if(!oldNode&&!options.initialize)throw new Error('尚未初始化网络环境，请先运行“一键初始化”。');
  let dialerProxy=Object.prototype.hasOwnProperty.call(options,'dialerProxy')?options.dialerProxy:
    oldNode?oldNode['dialer-proxy']||null:state.dialerProxy||null;
  if(dialerProxy==='DIRECT'||dialerProxy==='')dialerProxy=null;
  const names=(ctx.runtime.proxies||[]).concat(ctx.runtime['proxy-groups']||[]).map(item=>item.name);
  if(dialerProxy&&(!names.includes(dialerProxy)||[GROUP_NAME,NODE_NAME,'REJECT'].includes(dialerProxy)))throw new Error('所选前置代理不存在或不可用，请重新选择。');
  const dnsConfig = makeDNS(ctx, scope,routingContext);
  const settings = {scope,node:parsed,dialerProxy,connectionMode:dialerProxy?'chained':'direct',
    allowLegacyUSFallback:routingContext.legacy,serviceDomains:routingContext.serviceDomains,
    companyDomains:routingContext.companyDomains,privateRanges:PRIVATE_RANGES,customDirectRules:customDirectRules(ctx,routingContext),
    managedRelayHosts:routingContext.managedRelayHosts,managementDirectRules:routingContext.managementDirectRules,dns:dnsConfig.dns};
  if(usesFallback)settings.profileNameGuard=ctx.current.name;
  const originalScript = scriptSource(ctx);
  const script = makeScript(originalScript, settings);
  const candidate = buildCandidate(loc,ctx,script,dnsConfig);
  const writeDNS=routingContext.legacy||dnsOverrideEnabled(ctx);
  return {ctx,parsed,script,dnsConfig,candidate,scope,dialerProxy,profile,routingContext,writeDNS,
    sourceHashes:sourceHashes(loc,ctx)};
}

function sourceHashes(loc,ctx) {
  const files = [loc.profilesFile,loc.baseFile,loc.vergeFile,loc.dnsFile,loc.runtimeFile,
    ctx.rawFile,ctx.scriptFile,ctx.mergeFile,ctx.rulesFile,ctx.proxiesFile,ctx.groupsFile,
    ctx.globalMergeFile,ctx.globalScriptFile];
  return Object.fromEntries([...new Set(files)].map(filename => [filename,
    fs.existsSync(filename) ? sha(fs.readFileSync(filename)) : null]));
}

function checkSourceUnchanged(expected) {
  for (const [filename,hash] of Object.entries(expected)) {
    const current = fs.existsSync(filename) ? sha(fs.readFileSync(filename)) : null;
    if(current !== hash)throw new Error('Clash 配置在预检期间发生变化。请重试，避免覆盖订阅更新。');
  }
}

function scratchDirectory(loc) {
  privateDir(loc.dataDirectory);
  const directory=fs.mkdtempSync(path.join(loc.dataDirectory,'check-'));
  fs.chmodSync(directory,0o700);
  for (const name of ['geoip.dat','geosite.dat','Country.mmdb','ASN.mmdb']) {
    const from=path.join(loc.configDirectory,name);
    if(fs.existsSync(from))fs.symlinkSync(from,path.join(directory,name));
  }
  return directory;
}

function validateCore(loc, candidate) {
  if (!fs.existsSync(loc.core)) throw new Error('未找到 Clash Verge 的 Mihomo 内核。');
  const directory=scratchDirectory(loc);
  try {
    const filename=path.join(directory,'candidate.yaml');
    fs.writeFileSync(filename,dumpYAML(candidate),{mode:0o600});
    const result=spawnSync(loc.core,['-t','-d',directory,'-f',filename],{encoding:'utf8',timeout:20000,maxBuffer:1024*1024});
    if(result.error || result.status!==0)throw new Error('Mihomo 配置校验失败：'+safeError((result.stderr || result.stdout || result.error || '').slice(-1000)));
  } finally { fs.rmSync(directory,{recursive:true,force:true}); }
}

function api(loc, method, endpoint, body, socket=loc.socket) {
  return new Promise((resolve,reject)=>{
    const data=body===undefined?null:JSON.stringify(body);
    const request=http.request({socketPath:socket,path:endpoint,method,
      headers:data?{'Content-Type':'application/json','Content-Length':Buffer.byteLength(data)}:{}},response=>{
      let chunks='';response.setEncoding('utf8');
      response.on('data',part=>{chunks+=part;if(chunks.length>8*1024*1024)request.destroy(new Error('控制接口响应过大。'));});
      response.on('end',()=>{
        if(response.statusCode>=400){
          let detail='';try{detail=JSON.parse(chunks).message||'';}catch{}
          return reject(new Error('Clash 控制接口失败（'+response.statusCode+'）：'+safeError(detail)));
        }
        try {resolve(chunks?JSON.parse(chunks):{});}catch{reject(new Error('Clash 控制接口返回无效数据。'));}
      });
    });
    request.setTimeout(8000,()=>request.destroy(new Error('Clash 控制接口超时。')));
    request.on('error',reject);if(data)request.write(data);request.end();
  });
}

async function status(loc) {
  const state=readJSON(loc.stateFile,{});
  let routingContext=state.routingContext||(state.activeProfileID||state.baselineBackup?LEGACY_ROUTING_CONTEXT:null);
  if(!routingContext){try{routingContext=routingContextFor(loc,resolveContext(loc));}catch{routingContext=GENERIC_ROUTING_CONTEXT;}}
  const relayHosts=routingContext.managedRelayHosts||[];
  let config;
  try {config=await api(loc,'GET','/configs');}
  catch {return {isRunning:false,tunEnabled:false,mode:'unknown',message:'Clash Verge 未运行或服务接口不可用。',
    activeProfileID:state.activeProfileID || null,scope:state.scope || null,ip:state.ip || null,backupPath:state.baselineBackup || null,
    managedRelayHosts:relayHosts,scopeLabel:scopeLabel(state.scope,relayHosts)};}
  const ipv6Safe=!ipv6RouteExists();
  let drift=false;
  if(state.activeProfileID){
    try{
      const ctx=resolveContext(loc),node=currentNode(ctx.runtime);
      drift=ctx.current.uid!==state.currentProfileUID || !node || node.name!==NODE_NAME ||
        node.server!==state.host || Number(node.port)!==Number(state.port);
      for(const [filename,hash]of Object.entries(state.managedHashes||{})){
        if(!fs.existsSync(filename)||sha(fs.readFileSync(filename))!==hash)drift=true;
      }
      const group=await api(loc,'GET','/proxies/'+encodeURIComponent(GROUP_NAME));
      if(group.now!==NODE_NAME||!Array.isArray(group.all)||group.all.length!==1)drift=true;
    }catch{drift=true;}
  }
  const message=!ipv6Safe?'检测到 IPv6 默认路由，请先关闭公网 IPv6。':
    !(config.tun&&config.tun.enable)?'Clash Verge 正在运行，但 TUN 未启用。':
    config.mode!=='rule'?'Clash 当前没有使用规则模式，请重新应用账号配置。':
    drift?'Clash 配置已在软件外发生变化，请重新应用所需账号。':'Clash Verge TUN 正在运行。';
  return {isRunning:true,tunEnabled:!!(config.tun&&config.tun.enable),mode:config.mode || 'unknown',ipv6Safe,
    message,needsReapply:drift,
    activeProfileID:drift?null:state.activeProfileID || null,scope:state.scope || null,ip:drift?null:state.ip || null,
    managedRelayHosts:relayHosts,scopeLabel:scopeLabel(state.scope,relayHosts),
    backupPath:state.baselineBackup || null,currentProfileName:state.name || null};
}

async function setupStatus(loc) {
  const checks=[];
  const add=(id,title,ready,detail)=>checks.push({id,title,ready:!!ready,detail});
  let running=null,ctx=null,contextError='',scriptError='',physical='';
  try{running=await api(loc,'GET','/configs');}catch{}
  add('clash','Clash Verge 与内核运行',!!running&&fs.existsSync(loc.core),running?'本机 Clash 控制接口可访问。':'请安装并启动 Clash Verge Rev。');
  try{ctx=resolveContext(loc);}catch(error){contextError=safeError(error);}
  add('subscription','有效的当前订阅',!!ctx,ctx?'当前订阅：'+ctx.current.name:contextError||'请先导入并启用有效订阅。');
  add('tun','TUN 与自动路由',running&&running.tun&&running.tun.enable&&running.tun['auto-route']&&ctx&&ctx.verge.enable_tun_mode===true,'需要在 Clash Verge 中开启 TUN 与自动路由；初始化不会安装或重启服务。');
  add('ruleMode','规则模式',running&&running.mode==='rule'&&ctx&&ctx.base.mode==='rule','请在 Clash Verge 选择规则模式。');
  add('ipv6','IPv4 出口保护',ctx&&ctx.base.ipv6===false&&!ipv6RouteExists(),'若有公网 IPv6 默认路由，需先手动关闭公网 IPv6；初始化不会更改 macOS 全网 IPv6。');
  if(ctx){try{physical=preflightInterface(ctx.runtime);}catch(error){scriptError=safeError(error);}}
  add('interface','可用的物理 IPv4 网卡',!!physical,physical?'预检会绑定 '+physical+'，受管目标仍经所选 SOCKS5。':scriptError||'未找到可用物理 IPv4 网卡。');
  if(ctx){try{assertScriptPlacement(ctx);scriptError='';}catch(error){scriptError=safeError(error);}}
  add('enhancement','可安全更新的增强脚本',!!ctx&&!scriptError,scriptError||'无需预先绑定专用 Script；默认全局 Script 将仅对当前唯一名称的订阅生效。');
  const state=readJSON(loc.stateFile,{}),node=ctx&&currentNode(ctx.runtime);
  const marker=ctx&&scriptSource(ctx).includes(START_MARKER);
  const isManaged=!!(marker||state.activeProfileID);
  const routingContext=ctx?routingContextFor(loc,ctx):clone(GENERIC_ROUTING_CONTEXT);
  const sharedDNSUnsafe=ctx&&!routingContext.legacy&&dnsOverrideEnabled(ctx)&&
    (ctx.metadata.items||[]).filter(item=>['remote','local'].includes(item.type)).length>1;
  add('dnsScope','DNS 覆盖范围',!!ctx&&!sharedDNSUnsafe,sharedDNSUnsafe?
    '多个主订阅共用 DNS 文件。请先关闭当前订阅的 DNS 覆盖，初始化将用脚本管理 DNS，保留其他订阅设置。':
    '支持 DNS 覆盖关闭；软件可通过当前订阅脚本持久管理 DNS。');
  const canInitialize=checks.every(check=>check.ready);
  const policy=ctx&&ctx.runtime.dns&&ctx.runtime.dns['nameserver-policy']||{};
  const protectedDNS=!!(ctx&&ctx.runtime.dns&&ctx.runtime.dns.enable&&
    (ctx.runtime.dns.nameserver||[]).length&&(ctx.runtime.dns.nameserver||[]).every(value=>String(value).endsWith('#'+GROUP_NAME))&&
    (ctx.runtime.dns.fallback||[]).length&&(ctx.runtime.dns.fallback||[]).every(value=>String(value).endsWith('#'+GROUP_NAME))&&
    routingContext.serviceDomains.every(domain=>(policy['+.'+domain]||[]).length&&
      (Array.isArray(policy['+.'+domain])?policy['+.'+domain]:[policy['+.'+domain]]).every(value=>String(value).endsWith('#'+GROUP_NAME)))&&
    Object.entries(policy).every(([key,value])=>{
      const domain=key.replace(/^[+*]\./,'');
      return !routingContext.serviceDomains.some(suffix=>domain===suffix||domain.endsWith('.'+suffix))||
        (Array.isArray(value)?value:[value]).every(resolver=>String(resolver).endsWith('#'+GROUP_NAME));
    }));
  let runtimeManaged=!!(node&&node.name===NODE_NAME&&node.udp===false);
  if(runtimeManaged){try{const group=await api(loc,'GET','/proxies/'+encodeURIComponent(GROUP_NAME));runtimeManaged=group.now===NODE_NAME&&Array.isArray(group.all)&&group.all.length===1;}catch{runtimeManaged=false;}}
  let routeProtection=false;
  if(runtimeManaged){try{
    const actual=(await api(loc,'GET','/rules')).rules||[];
    routeProtection=state.scope==='fullPublic'?
      actual.some(rule=>rule.type==='Match'&&rule.proxy===GROUP_NAME)&&actual.some(rule=>String(rule.type).toUpperCase()==='NETWORK'&&String(rule.payload).toLowerCase()==='udp'&&rule.proxy==='REJECT'):
      routingContext.serviceDomains.every(domain=>actual.some(rule=>rule.type==='DomainSuffix'&&rule.payload===domain&&rule.proxy===GROUP_NAME)&&
        actual.some(rule=>String(rule.type).toUpperCase()==='AND'&&
          (String(rule.payload).toLowerCase().includes('domainsuffix,'+domain)||String(rule.payload).toLowerCase().includes('domain-suffix,'+domain))&&
          String(rule.payload).toLowerCase().includes('network,udp')&&rule.proxy==='REJECT'));
  }catch{}}
  let unchanged=!!(state.activeProfileID&&Object.keys(state.managedHashes||{}).length>0&&ctx&&ctx.current.uid===state.currentProfileUID&&node&&node.server===state.host&&Number(node.port)===Number(state.port));
  for(const[filename,hash]of Object.entries(state.managedHashes||{}))if(!fs.existsSync(filename)||sha(fs.readFileSync(filename))!==hash)unchanged=false;
  add('managedScript','持久的账号路由脚本',marker,marker?'已找到软件托管脚本。':'初始化将备份原脚本并写入账号路由。');
  add('dnsProtection','受管 DNS 与回退保护',protectedDNS,protectedDNS?'受管 DNS 和回退均使用专用出口。':'初始化将生成受管 DoH、回退与局域网 DNS 例外。');
  add('activeRuntime','当前运行的专用节点',runtimeManaged,runtimeManaged?'运行配置使用唯一受管 SOCKS5 节点。':'初始化将创建专用节点及规则。');
  add('routeProtection','受管路由与 UDP 保护',routeProtection,routeProtection?'实际内核已加载受管路由与 UDP 防回退规则。':'初始化将安装受管路由和 UDP 防回退规则。');
  add('configurationMatch','配置一致性',unchanged,unchanged?'持久脚本、DNS 与当前账号状态一致。':'尚未接管，或配置已由其他软件更改。');
  const networkReady=canInitialize&&marker&&protectedDNS&&runtimeManaged&&routeProtection&&unchanged;
  const dialerOptions=[{id:'DIRECT',name:'直接连接 SOCKS5（无需前置代理）'}];
  if(ctx)for(const proxy of ctx.runtime.proxies||[]){
    if(proxy.name&&!/^Claude ISP /.test(proxy.name)&&proxy.name!==NODE_NAME&&!['direct','reject','dns','pass'].includes(String(proxy.type).toLowerCase()))dialerOptions.push({id:proxy.name,name:proxy.name});
  }
  const suggestedDialer=node&&node['dialer-proxy']||state.dialerProxy||'DIRECT';
  return {networkReady,canInitialize,isManaged,requiresInitialization:!networkReady,checks,dialerOptions,suggestedDialer,
    managedRelayHosts:routingContext.managedRelayHosts,scopeLabel:scopeLabel(state.scope,routingContext.managedRelayHosts),
    currentProfileUID:ctx&&ctx.current.uid||null,currentProfileName:ctx&&ctx.current.name||null,
    message:networkReady?'网络环境已经初始化，无需重复应用。':!canInitialize?'请先完成上方依赖检查，再一键初始化。':
      isManaged?'已检测到托管配置，但需要修复或重新应用。':'添加 SOCKS5 后即可一键初始化；现有自定义直连与内网规则会保留。'};
}

function availablePort() {
  return new Promise((resolve,reject)=>{
    const server=net.createServer();server.on('error',reject);
    server.listen(0,'127.0.0.1',()=>{const port=server.address().port;server.close(()=>resolve(port));});
  });
}

function selectPreflightInterface({routeOutput='',nwiOutput='',interfaces=os.networkInterfaces(),configuredInterface=''}) {
  const usable=name=>typeof name==='string'&&/^[A-Za-z][A-Za-z0-9_.:-]{0,31}$/.test(name)&&
    !/^(?:utun|tun|tap|ppp|ipsec|lo\d|gif|stf|awdl|llw)/i.test(name)&&
    Array.isArray(interfaces[name])&&interfaces[name].some(address=>
      !address.internal&&(address.family==='IPv4'||address.family===4)&&!address.address.startsWith('169.254.'));
  const route=/^\s*interface:\s*(\S+)/m.exec(routeOutput);
  const nwiIPv4=nwiOutput.split('IPv6 network interface information')[0];
  const nwiNames=[...nwiIPv4.matchAll(/^\s*(\S+)\s*:\s*flags\s*:[^\n]*IPv4/gm)].map(match=>match[1]);
  const selected=[route&&route[1],configuredInterface,...nwiNames].find(usable);
  if(!selected)throw new Error('无法确定预检使用的物理 IPv4 网卡，已停止预检，未改变当前网络。');
  return selected;
}

function preflightInterface(config) {
  const route=spawnSync('/sbin/route',['-n','get','default'],{encoding:'utf8',timeout:3000});
  const nwi=spawnSync('/usr/sbin/scutil',['--nwi'],{encoding:'utf8',timeout:3000});
  return selectPreflightInterface({routeOutput:route.stdout||'',nwiOutput:nwi.stdout||'',
    configuredInterface:config['interface-name']||''});
}

async function isolatedPreflightAttempt(loc, prepared) {
  const config=clone(prepared.candidate);
  const physicalInterface=preflightInterface(config);
  const directory=scratchDirectory(loc), socket=path.join(directory,'core.sock');
  const port=await availablePort();
  // A non-TUN child lacks the running core's interface finder. Bind its underlying transport
  // to the actual physical uplink so the live TUN cannot wrap this test in another proxy.
  // Target routes still use the sole SOCKS5 node and its mandatory dialer-proxy; no DIRECT fallback.
  config['interface-name']=physicalInterface;
  const front=(config.proxies||[]).find(proxy=>proxy.name===prepared.dialerProxy);
  if(front)front['interface-name']=physicalInterface;
  // Unused subscription groups must not launch a burst of background latency probes.
  for(const group of config['proxy-groups']||[]){
    if(['url-test','fallback','load-balance'].includes(group.type)){group.lazy=true;group.interval=86400;}
  }
  config.tun.enable=false;config['mixed-port']=port;config['allow-lan']=false;
  config['bind-address']='127.0.0.1';config['external-controller']='';
  config['external-controller-unix']=socket;config.secret='';
  config.dns.listen='127.0.0.1:0';config['log-level']='silent';
  delete config['socks-port'];delete config.port;delete config['redir-port'];delete config['tproxy-port'];
  config.profile={...(config.profile||{}),'store-selected':false,'store-fake-ip':false};
  const filename=path.join(directory,'candidate.yaml');
  fs.writeFileSync(filename,dumpYAML(config),{mode:0o600});
  const child=spawn(loc.core,['-d',directory,'-f',filename],{stdio:['ignore','ignore','ignore']});
  let launchError;child.on('error',error=>launchError=error);
  try {
    let ready=false;
    for(let i=0;i<40;i++){
      if(launchError || child.exitCode!==null)throw new Error('隔离代理预检内核无法启动。');
      try{await api(loc,'GET','/version',undefined,socket);ready=true;break;}catch{await sleep(125);}
    }
    if(!ready)throw new Error('隔离代理预检启动超时。');
    const result=await verifyEndpoints(loc,{socket,port,scope:prepared.scope,expectedHost:prepared.parsed.host,
      activeProfileID:prepared.profile.id,relayHosts:prepared.routingContext.managedRelayHosts});
    return {...result,preflightInterface:physicalInterface};
  }finally{
    if(child.exitCode===null){child.kill('SIGTERM');await Promise.race([new Promise(resolve=>child.once('exit',resolve)),sleep(1500)]);if(child.exitCode===null)child.kill('SIGKILL');}
    fs.rmSync(directory,{recursive:true,force:true});
  }
}

async function isolatedPreflight(loc, prepared, requireSuccess=true) {
  let result;
  for(let attempt=1;attempt<=2;attempt++){
    try{
      result={...await isolatedPreflightAttempt(loc,prepared),preflightAttempts:attempt};
    }catch(error){
      const transient=['ECONNRESET','ETIMEDOUT','EPIPE','ECONNREFUSED','EHOSTUNREACH','ENETUNREACH'].includes(error.code);
      if(attempt===1&&transient){await sleep(400);continue;}
      throw error;
    }
    const allNetworkFailed=!result.success&&result.endpoints.length>0&&result.endpoints.every(endpoint=>endpoint.status===0);
    if(attempt===1&&allNetworkFailed){await sleep(400);continue;}
    break;
  }
  if(!result.success&&requireSuccess)throw new Error('新代理预检失败，未改变当前网络。'+result.details);
  return result;
}

function runCurl(url, port, noProxy=false) {
  return new Promise(resolve=>{
    const args=['--silent','--show-error','--http1.1','--connect-timeout','7','--max-time','15',
      '--max-filesize','1048576','--write-out','\nACCOUNT_PROXY_HTTP:%{http_code}\n'];
    if(noProxy)args.push('--noproxy','*');else args.push('--proxy',`http://127.0.0.1:${port}`,'--noproxy','');
    args.push(url);
    const child=spawn('/usr/bin/curl',args,{stdio:['ignore','pipe','pipe'],env:{PATH:'/usr/bin:/bin:/usr/sbin:/sbin',HOME:os.homedir()}});
    let output='',error='';child.stdout.setEncoding('utf8');child.stderr.setEncoding('utf8');
    child.stdout.on('data',chunk=>{output+=chunk;if(output.length>1200000)child.kill('SIGTERM');});
    child.stderr.on('data',chunk=>{error+=chunk;});
    child.on('error',()=>resolve({status:0,ip:null,error:'无法启动网络检查。'}));
    child.on('exit',code=>{
      const match=/ACCOUNT_PROXY_HTTP:(\d+)/.exec(output);
      const ip=/^ip=([^\r\n]+)$/m.exec(output) || /"ip"\s*:\s*"([^"]+)"/.exec(output) || /^(\d{1,3}(?:\.\d{1,3}){3})\s*$/m.exec(output);
      resolve({status:match?Number(match[1]):0,ip:ip?ip[1].trim():null,error:code===0?null:safeError(error).slice(0,180)});
    });
  });
}

async function verifyEndpoints(loc,{socket=loc.socket,port,scope,expectedHost,activeProfileID,expectedIP=null,checkTUN=false,nodeName=NODE_NAME,relayHosts=MANAGED_RELAY_HOSTS}) {
  const configured=await api(loc,'GET','/configs',undefined,socket);
  const proxyInfo=await api(loc,'GET','/proxies/'+encodeURIComponent(GROUP_NAME),undefined,socket);
  const singleRoute=proxyInfo.now===nodeName && Array.isArray(proxyInfo.all) && proxyInfo.all.length===1;
  const rules=await api(loc,'GET','/rules',undefined,socket);
  const rulesArray=rules.rules || [];
  const hasPublicCatchall=rulesArray.some(rule=>rule.type==='Match'&&rule.proxy===GROUP_NAME);
  const urls=[
    ['Cloudflare','https://www.cloudflare.com/cdn-cgi/trace'],
    ['Claude','https://claude.ai/cdn-cgi/trace'],
    ['Anthropic','https://api.anthropic.com/cdn-cgi/trace'],
    ['Stripe','https://api.stripe.com/']
  ];
  for(const host of relayHosts)urls.push(['业务中转 '+host,'https://'+host+'/']);
  if(scope==='fullPublic')urls.push(['公网兜底','https://api.ipify.org?format=json']);
  const observations=[];
  let collecting=true;
  const collector=(async()=>{while(collecting){
    try{const live=await api(loc,'GET','/connections',undefined,socket);for(const connection of live.connections||[]){
      if(connection.metadata&&connection.metadata.host)observations.push({host:connection.metadata.host,chains:connection.chains||[]});
    }}catch{}await sleep(70);
  }})();
  let endpoints;
  try{endpoints=await Promise.all(urls.map(async([service,url])=>({service,url,...await runCurl(url,port||configured['mixed-port'])})));}
  finally{collecting=false;await collector;}
  for(const endpoint of endpoints){
    const hostname=new URL(endpoint.url).hostname;
    const observation=observations.find(value=>value.host===hostname&&value.chains.includes(nodeName));
    endpoint.routeObserved=!!observation;
    const ruleCovered=scope==='fullPublic'?hasPublicCatchall:rulesArray.some(rule=>rule.proxy===GROUP_NAME&&
      (rule.type==='DomainSuffix'&& (hostname===rule.payload||hostname.endsWith('.'+rule.payload)) || rule.type==='Domain'&&hostname===rule.payload));
    endpoint.routeVerified=singleRoute&&ruleCovered;
  }
  const trace=endpoints.filter(endpoint=>['Cloudflare','Claude','Anthropic'].includes(endpoint.service));
  const ips=[...new Set(trace.map(endpoint=>endpoint.ip).filter(Boolean))];
  let success=trace.every(endpoint=>endpoint.status===200&&endpoint.ip)&&ips.length===1&&endpoints.every(endpoint=>endpoint.status>0&&endpoint.routeVerified);
  if(!endpoints.filter(endpoint=>endpoint.service.startsWith('业务中转 ')).every(endpoint=>endpoint.status===200))success=false;
  if(scope==='fullPublic'&&!endpoints.filter(endpoint=>endpoint.service==='公网兜底').every(endpoint=>endpoint.status===200&&endpoint.ip===ips[0]))success=false;
  if(expectedIP&&ips[0]!==expectedIP)success=false;
  if(checkTUN&&(!(configured.tun&&configured.tun.enable&&configured.mode==='rule')||ipv6RouteExists()))success=false;
  // A second unproxied curl verifies the operating system's TUN route, not just the local listener.
  if(checkTUN&&success){
    const tunProbe=await runCurl('https://www.cloudflare.com/cdn-cgi/trace',port||configured['mixed-port'],true);
    endpoints.push({service:'macOS TUN',url:'https://www.cloudflare.com/cdn-cgi/trace',...tunProbe,
      routeObserved:false,routeVerified:tunProbe.ip===ips[0]});
    if(tunProbe.status!==200||tunProbe.ip!==ips[0])success=false;
  }
  const ip=ips.length===1?ips[0]:null;
  const hostMatches=net.isIP(expectedHost||'')?ip===expectedHost:null;
  return {success,ip,expectedIP:expectedIP || ip || expectedHost || '',expectedHost,hostMatches,activeProfileID,scope,
    managedRelayHosts:relayHosts,scopeLabel:scopeLabel(scope,relayHosts),
    checkedAt:new Date().toISOString(),endpoints,
    details:success?'Cloudflare、Claude、Anthropic 返回同一出口；Stripe 已确认同一专用路由。'+
      (relayHosts.length?' '+relayHosts.length+' 个业务中转根路径均为 HTTP 200，使用同一专用路由。':'')+
      (hostMatches===false?' 供应商主机与公网出口不同，已以三处实测一致的出口为准。':''):
      '出口验证未通过：'+endpoints.filter(endpoint=>!endpoint.routeVerified||!endpoint.status||
        endpoint.service.startsWith('业务中转 ')&&endpoint.status!==200||
        ['Cloudflare','Claude','Anthropic','公网兜底'].includes(endpoint.service)&&(endpoint.status!==200||!endpoint.ip))
        .map(endpoint=>endpoint.service+' HTTP '+endpoint.status).join('；')+
      '。请检查代理可用性、前置节点、TUN'+(relayHosts.length?'及业务中转的 IP 白名单':'')+'。'};
}

function backup(loc, files, kind) {
  const directory=path.join(loc.dataDirectory,'backups',new Date().toISOString().replace(/[:.]/g,'-')+'-'+kind+'-'+crypto.randomBytes(3).toString('hex'));
  privateDir(directory);
  const manifest={version:1,createdAt:new Date().toISOString(),files:[]};
  let count=0;
  for(const filename of [...new Set(files)]){
    const exists=fs.existsSync(filename),storage=`${count++}-${path.basename(filename)}`;
    manifest.files.push({path:filename,storage,exists,sha256:exists?sha(fs.readFileSync(filename)):null});
    if(exists)fs.writeFileSync(path.join(directory,storage),fs.readFileSync(filename),{mode:0o600});
  }
  atomicWrite(path.join(directory,'manifest.json'),JSON.stringify(manifest,null,2));
  return directory;
}

function restoreSnapshot(directory,excludedPaths=[]) {
  const manifest=readJSON(path.join(directory,'manifest.json'));
  if(!manifest||manifest.version!==1||!Array.isArray(manifest.files))throw new Error('恢复备份清单损坏。');
  // Validate every file before touching any current file.
  for(const entry of manifest.files){
    if(entry.exists&&sha(fs.readFileSync(path.join(directory,entry.storage)))!==entry.sha256)throw new Error('恢复备份校验失败。');
  }
  for(const entry of manifest.files){
    if(excludedPaths.includes(entry.path))continue;
    if(entry.exists)atomicWrite(entry.path,fs.readFileSync(path.join(directory,entry.storage)));
    else fs.rmSync(entry.path,{force:true});
  }
}

async function reload(loc) {
  // The privileged service deliberately limits filesystem paths to its own runtime.
  // Loading a YAML payload uses the documented API without weakening SAFE_PATHS.
  // Preserve unchanged listeners and TUN. Existing requests may finish on their original exit;
  // new connections use the newly selected account. Never delete the user's live connections.
  await api(loc,'PUT','/configs?force=false',{payload:fs.readFileSync(loc.runtimeFile,'utf8')});
  const status=await api(loc,'GET','/configs');
  if(!(status.tun&&status.tun.enable&&status.mode==='rule'))throw new Error('重载后 TUN 或规则模式异常。');
}

function lock(loc) {
  privateDir(loc.dataDirectory);
  try {fs.writeFileSync(loc.lockFile,JSON.stringify({pid:process.pid,createdAt:new Date().toISOString()}),{mode:0o600,flag:'wx'});}
  catch(error){
    if(error.code!=='EEXIST')throw error;
    const prior=readJSON(loc.lockFile,{});let running=false;
    try{if(prior.pid){process.kill(prior.pid,0);running=true;}}catch{}
    if(running)throw new Error('另一个账号切换正在执行，请稍后重试。');
    fs.rmSync(loc.lockFile,{force:true});
    fs.writeFileSync(loc.lockFile,JSON.stringify({pid:process.pid}),{mode:0o600,flag:'wx'});
  }
  return ()=>fs.rmSync(loc.lockFile,{force:true});
}

async function recoverInterrupted(loc) {
  const journal=readJSON(loc.journalFile);
  if(!journal)return;
  if(!journal.backupPath)throw new Error('上次切换未完成且缺少备份，请检查交接目录。');
  restoreSnapshot(journal.backupPath);
  await reload(loc);
  fs.rmSync(loc.journalFile,{force:true});
}

async function apply(loc,profile,scope,options={}) {
  const unlock=lock(loc);
  try{
    await recoverInterrupted(loc);
    const prepared=prepare(loc,profile,scope,options);
    const running=await status(loc);
    if(!running.isRunning||!running.tunEnabled)throw new Error('Clash Verge 服务和 TUN 必须正在运行。');
    validateCore(loc,prepared.candidate);
    // Optional function effects are used only by in-process fixture tests; JSON requests cannot supply functions.
    const preflight=await (options.effects&&options.effects.preflight||isolatedPreflight)(loc,prepared);
    checkSourceUnchanged(prepared.sourceHashes);
    const previousState=readJSON(loc.stateFile,{});
    const files=[prepared.ctx.scriptFile,...(prepared.writeDNS?[loc.dnsFile]:[]),loc.runtimeFile,loc.stateFile];
    const backupPath=backup(loc,files,'switch');
    // Extra reference files allow a human to reconstruct the exact subscription context.
    for(const filename of [loc.profilesFile,loc.baseFile,loc.vergeFile]){
      fs.writeFileSync(path.join(backupPath,'reference-'+path.basename(filename)),fs.readFileSync(filename),{mode:0o600});
    }
    const baselineBackup=previousState.baselineBackup || backupPath;
    atomicWrite(loc.journalFile,JSON.stringify({backupPath,startedAt:new Date().toISOString()},null,2));
    let rollbackError;
    try{
      atomicWrite(prepared.ctx.scriptFile,prepared.script);
      if(prepared.writeDNS)atomicWrite(loc.dnsFile,dumpYAML(prepared.dnsConfig));
      atomicWrite(loc.runtimeFile,dumpYAML(prepared.candidate));
      await reload(loc);
      const result=await (options.effects&&options.effects.verify||verifyEndpoints)(loc,{port:prepared.candidate['mixed-port'],scope,
        expectedHost:prepared.parsed.host,expectedIP:preflight.ip,activeProfileID:profile.id,checkTUN:true,
        relayHosts:prepared.routingContext.managedRelayHosts});
      if(!result.success)throw new Error(result.details);
      const state={version:2,activeProfileID:profile.id,name:profile.name,accountDescription:profile.accountDescription||'',
        scope,ip:result.ip,host:prepared.parsed.host,port:prepared.parsed.port,dialerProxy:prepared.dialerProxy,
        routingContext:prepared.routingContext,connectionMode:prepared.dialerProxy?'chained':'direct',
        dnsManagedByScriptOnly:!prepared.writeDNS,
        currentProfileUID:prepared.ctx.current.uid,scriptPath:prepared.ctx.scriptFile,baselineBackup,
        latestBackup:backupPath,appliedAt:new Date().toISOString(),
        managedHashes:{[prepared.ctx.scriptFile]:sha(prepared.script),
          ...(prepared.writeDNS?{[loc.dnsFile]:sha(dumpYAML(prepared.dnsConfig))}:{})}};
      atomicWrite(loc.stateFile,JSON.stringify(state,null,2));
      fs.rmSync(loc.journalFile,{force:true});
      return {...result,backupPath,networkReady:true,managedRelayHosts:prepared.routingContext.managedRelayHosts,
        scopeLabel:scopeLabel(scope,prepared.routingContext.managedRelayHosts),
        details:result.details+' 已保存订阅增强脚本和 DNS 配置，重启及订阅刷新后继续生效。'};
    }catch(error){
      try{restoreSnapshot(backupPath);await reload(loc);fs.rmSync(loc.journalFile,{force:true});}
      catch(failed){rollbackError=safeError(failed);}
      throw new Error(safeError(error)+(rollbackError?' 自动恢复失败：'+rollbackError+'；备份位于 '+backupPath:' 已自动恢复切换前配置。'));
    }
  }finally{unlock();}
}

async function initialize(loc,request,effects) {
  const setup=await setupStatus(loc);
  if(setup.networkReady){
    const state=readJSON(loc.stateFile,{});
    return {success:true,networkReady:true,initialized:false,activeProfileID:state.activeProfileID,scope:state.scope,
      managedRelayHosts:setup.managedRelayHosts,scopeLabel:scopeLabel(state.scope,setup.managedRelayHosts),
      ip:state.ip||null,expectedIP:state.ip||'',checkedAt:new Date().toISOString(),
      backupPath:state.latestBackup||null,details:'网络环境已经初始化，当前账号与连接保持原状。'};
  }
  if(!setup.canInitialize)throw new Error(setup.message+' '+setup.checks.filter(check=>!check.ready&&
    ['clash','subscription','tun','ruleMode','ipv6','interface','enhancement','dnsScope'].includes(check.id)).map(check=>check.title+'：'+check.detail).join('；'));
  const ctx=resolveContext(loc);
  const result=await apply(loc,request.profile,request.scope||'servicesOnly',{initialize:true,
    dialerProxy:request.dialerProxy===undefined?setup.suggestedDialer:request.dialerProxy,routingContext:routingContextFor(loc,ctx),effects});
  return {...result,networkReady:true,initialized:true};
}

async function restore(loc) {
  const unlock=lock(loc);
  try{
    await recoverInterrupted(loc);
    const state=readJSON(loc.stateFile,{});
    if(!state.baselineBackup)throw new Error('尚无本软件创建的初始备份。');
    if(resolveContext(loc).current.uid!==state.currentProfileUID)throw new Error('Clash 当前订阅已变化；为避免覆盖新订阅，请先切回原订阅。');
    for(const [filename,hash]of Object.entries(state.managedHashes||{})){
      if(!fs.existsSync(filename)||sha(fs.readFileSync(filename))!==hash)throw new Error('托管配置已被其他程序修改。请先检查备份，避免覆盖这些修改。');
    }
    const baseline=readJSON(path.join(state.baselineBackup,'manifest.json'));
    const excludedPaths=state.dnsManagedByScriptOnly?[loc.dnsFile]:[];
    const rollbackPath=backup(loc,baseline.files.map(entry=>entry.path).filter(filename=>!excludedPaths.includes(filename)),'before-restore');
    atomicWrite(loc.journalFile,JSON.stringify({backupPath:rollbackPath,startedAt:new Date().toISOString()}));
    try{
      restoreSnapshot(state.baselineBackup,excludedPaths);await reload(loc);
      fs.rmSync(loc.journalFile,{force:true});
      return {success:true,activeProfileID:null,scope:null,ip:null,expectedIP:'',checkedAt:new Date().toISOString(),
        backupPath:rollbackPath,details:'已恢复首次使用本软件之前的 Clash 脚本、DNS 和运行配置。'};
    }catch(error){
      try{restoreSnapshot(rollbackPath);await reload(loc);fs.rmSync(loc.journalFile,{force:true});}catch{}
      throw new Error(safeError(error)+'；恢复未完成，已尝试回到恢复前状态。');
    }
  }finally{unlock();}
}

async function dispatch(request) {
  const loc=locations();
  switch(request.operation){
    case 'status':return status(loc);
    case 'setupStatus':return setupStatus(loc);
    case 'initialize':return initialize(loc,request);
    case 'importCurrent':{
      const ctx=resolveContext(loc),node=currentNode(ctx.runtime);
      if(!node||node.type!=='socks5')throw new Error('当前未找到可导入的专用 SOCKS5 节点。');
      const auth=node.username?encodeURIComponent(node.username)+':'+encodeURIComponent(node.password||'')+'@':'';
      const host=net.isIP(node.server)===6?'['+node.server+']':node.server;
      return {uri:`socks5://${auth}${host}:${node.port}`,name:'当前专用出口',accountDescription:'从现有 Claude / Cloudflare / Stripe 配置导入',host:node.server,port:node.port};
    }
    case 'preview':{
      const prepared=prepare(loc,request.profile,request.scope);validateCore(loc,prepared.candidate);
      return {success:true,scope:request.scope,expectedIP:prepared.parsed.host,host:prepared.parsed.host,port:prepared.parsed.port,
        dialerProxy:prepared.dialerProxy,ruleCount:prepared.candidate.rules.length,
        details:'Mihomo 离线配置校验通过。尚未改变网络；应用时还将检查真实出口并在失败时自动恢复。'};
    }
    case 'preflight':{
      const prepared=prepare(loc,request.profile,request.scope);
      validateCore(loc,prepared.candidate);
      return isolatedPreflight(loc,prepared,false);
    }
    case 'apply':return apply(loc,request.profile,request.scope);
    case 'restore':return restore(loc);
    case 'verify':{
      const state=readJSON(loc.stateFile,{}),ctx=resolveContext(loc),node=currentNode(ctx.runtime);
      const result=await verifyEndpoints(loc,{scope:state.scope || 'servicesOnly',expectedHost:node&&node.server,
        expectedIP:state.ip || null,activeProfileID:state.activeProfileID||null,checkTUN:true,nodeName:node&&node.name||NODE_NAME,
        relayHosts:routingContextFor(loc,ctx).managedRelayHosts});
      return {...result,backupPath:state.latestBackup || null};
    }
    default:throw new Error('未知后端操作。');
  }
}

async function main() {
  let input='';for await(const chunk of process.stdin){input+=chunk;if(input.length>1024*1024)throw new Error('输入过大。');}
  const request=JSON.parse(input);
  const result=await dispatch(request);
  process.stdout.write(JSON.stringify({ok:true,result})+'\n');
}

module.exports={locations,parseSOCKS,resolveContext,managedTransform,makeScript,makeDNS,buildCandidate,
  prepare,validateCore,assertCandidate,dispatch,sha,dumpYAML,backup,restoreSnapshot,verifyEndpoints,
  recoverInterrupted,reload,customDirectRules,policyMatchesDirectDomain,selectPreflightInterface,
  setupStatus,initialize,apply,restore,routingContextFor,LEGACY_ROUTING_CONTEXT,GENERIC_ROUTING_CONTEXT,
  MANAGED_RELAY_HOSTS,MANAGEMENT_DIRECT_RULES,SERVICE_DOMAINS,PRIVATE_RANGES,COMPANY_DOMAINS,NODE_NAME,GROUP_NAME};
if(require.main===module)main().catch(error=>{process.stdout.write(JSON.stringify({ok:false,error:safeError(error)})+'\n');process.exitCode=1;});
