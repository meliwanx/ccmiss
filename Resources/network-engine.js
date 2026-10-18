#!/usr/bin/env node
'use strict';

// Select one owner for an operation. Existing ccmiss transactions take priority;
// discovering Clash never stops or migrates an already active standalone TUN.
const fs = require('node:fs');
const standalone = require('./standalone-engine.js');
const coexist = require('./coexist-engine.js');

function readState(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return {}; throw new Error('网络状态文件无法读取，请先检查恢复资料。'); }
}

function hasIntent(state) {
  return !!(state.activeProfileID || state.generation || state.proxyMode === 'profile' ||
    ['active', 'desiredActive', 'resumePending', 'activeIntent'].some(key => state[key] === true));
}

function helperHasIntent(info, localState) {
  if (info.running || info.tunEnabled || info.dnsRestorationPending ||
      ['active', 'desiredActive', 'resumePending', 'activeIntent'].some(key => info[key] === true)) return true;
  // The already-running 2.2 helper retains its generation after stop and does not
  // expose desiredActive. Only a matching, locally confirmed stop releases it.
  return !!(info.generation && !(localState.proxyMode === 'system' &&
    localState.systemProxyConfirmedAt && localState.stoppedGeneration === info.generation &&
    (info.ownerUID === undefined || Number(info.ownerUID) === process.getuid())));
}

async function inspectHelper(engine, loc, options) {
  try { return await (options.helperStatus || engine.helperRequest)(loc, 'status'); }
  catch (error) {
    if (error.code === 'ENOENT') return null;
    throw new Error('无法确认 ccmiss 独立网络服务已退出。请重新检查；当前网络保持原样。');
  }
}

async function selectBackend(options = {}) {
  const independent = options.standalone || standalone;
  const shared = options.coexist || coexist;
  const ownLoc = options.standaloneLocations || independent.locations();
  const sharedLoc = options.coexistLocations || shared.locations();
  const ownState = readState(ownLoc.stateFile);
  const sharedState = readState(sharedLoc.stateFile);
  const standalonePending = fs.existsSync(ownLoc.journalFile) || hasIntent(ownState) ||
    (fs.existsSync(ownLoc.configFile) && !ownState.stoppedAt && !ownState.systemProxyConfirmedAt);
  const coexistPending = fs.existsSync(sharedLoc.journalFile) || hasIntent(sharedState);
  if (standalonePending && coexistPending) {
    throw new Error('发现两种网络模式都有未完成记录。已停止自动切换，请先检查恢复资料。');
  }
  if (standalonePending) return { engine: independent, locations: ownLoc, kind: 'standalone' };
  if (coexistPending) {
    if (!['status', 'setupStatus'].includes(options.operation)) {
      const info = await inspectHelper(independent, ownLoc, options);
      if (info && helperHasIntent(info, ownState)) throw new Error('ccmiss 独立网络会话仍在运行或等待恢复，暂不修改 Clash 共存配置。');
    }
    return { engine: shared, locations: sharedLoc, kind: 'clashCoexist' };
  }

  // Include a service-owned session even when the user's local metadata is missing.
  // A failed read is not evidence that a previously owned local session has stopped.
  const info = await inspectHelper(independent, ownLoc, options);
  if (info && helperHasIntent(info, ownState)) {
    return { engine: independent, locations: ownLoc, kind: 'standalone' };
  }
  if (await shared.detect(sharedLoc)) return { engine: shared, locations: sharedLoc, kind: 'clashCoexist' };
  return { engine: independent, locations: ownLoc, kind: 'standalone' };
}

async function dispatch(request, options = {}) {
  if (!request || typeof request.operation !== 'string') throw new Error('缺少网络操作。');
  // Saving an optional upstream changes the next account application only.
  if (request.operation === 'configureUpstream') return (options.standalone || standalone).dispatch(request);
  const selected = await selectBackend({...options, operation: request.operation});
  if (selected.kind === 'standalone') return selected.engine.dispatch(request);
  if (['apply', 'initialize', 'preview', 'preflight'].includes(request.operation) &&
      request.scope && request.scope !== 'servicesOnly') {
    throw new Error('与 Clash 共存时仅支持指定服务，其余网络继续使用原有配置。');
  }
  const loc = selected.locations;
  switch (request.operation) {
    case 'status': return selected.engine.status(loc);
    case 'setupStatus': return selected.engine.setupStatus(loc);
    case 'apply':
    case 'initialize': return selected.engine.apply(loc, {...request, scope: 'servicesOnly'});
    case 'preview': return selected.engine.preview(loc, request);
    case 'preflight': return selected.engine.preflight(loc, request);
    case 'verify': return selected.engine.verify(loc, request);
    case 'useSystemProxy':
    case 'restore': return selected.engine.useSystemProxy(loc);
    case 'importCurrent': return require('./engine.js').dispatch(request);
    default: throw new Error('此网络操作不受支持。');
  }
}

function safeError(error, request) {
  let message = String(error.message || '网络操作失败。');
  const values = [];
  function collect(value, key = '') {
    if (typeof value === 'string' && /^(?:socksURL|url|username|password|secret|uuid)$/i.test(key)) {
      if (value) values.push(value);
      if (/^(?:socks5h?|vless):\/\//i.test(value)) {
        try { const uri = new URL(value); values.push(decodeURIComponent(uri.username), decodeURIComponent(uri.password)); } catch {}
      }
    } else if (value && typeof value === 'object') {
      for (const [field, item] of Object.entries(value)) collect(item, field);
    }
  }
  collect(request);
  for (const value of values.filter(Boolean).sort((a, b) => b.length - a.length)) message = message.split(value).join('[已隐藏]');
  return message.replace(/(?:socks5h?|vless):\/\/[^\s"']+/gi, '[代理链接已隐藏]')
    .replace(/("?(?:password|username|secret|uuid)"?\s*[:=]\s*)[^,\n}]+/gi, '$1[已隐藏]').slice(0, 1800);
}

module.exports = {selectBackend, dispatch, hasIntent, helperHasIntent, safeError};
let currentRequest;
if (require.main === module) (async () => {
  let input = '';
  process.stdin.setEncoding('utf8');
  for await (const chunk of process.stdin) {
    input += chunk;
    if (input.length > 1024 * 1024) throw new Error('输入过大。');
  }
  try { currentRequest = JSON.parse(input); } catch { throw new Error('请求 JSON 格式错误。'); }
  process.stdout.write(JSON.stringify({ok: true, result: await dispatch(currentRequest)}) + '\n');
})().catch(error => {
  // Child backends sanitize their own errors. Do not add request data here.
  process.stdout.write(JSON.stringify({ok: false, error: safeError(error, currentRequest)}) + '\n');
  process.exitCode = 1;
});
