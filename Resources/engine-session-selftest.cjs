'use strict';
// Isolated regression check: reload only a temporary non-TUN core, never the live service.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const net=require('node:net');
const http=require('node:http');
const path=require('node:path');
const crypto=require('node:crypto');
const {spawn}=require('node:child_process');
const engine=require('./engine.js');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const loc={core:path.join(__dirname,'mihomo')};
const directory='/tmp/account-proxy-session-'+process.pid+'-'+crypto.randomBytes(4).toString('hex');
fs.mkdirSync(directory,{mode:0o700});
const socketPath=path.join(directory,'core.sock');
const echoClients=new Set(),clientSockets=new Set();
let core,echoServer;

function api(method,endpoint,body){
  return new Promise((resolve,reject)=>{
    const request=http.request({socketPath,path:endpoint,method,headers:{'Content-Type':'application/json'}},response=>{
      let data='';response.on('data',part=>data+=part);response.on('end',()=>{
        if(response.statusCode>=400)return reject(new Error('Temporary API HTTP '+response.statusCode));
        resolve(data?JSON.parse(data):{});
      });
    });
    request.setTimeout(3000,()=>request.destroy(new Error('Temporary API timeout')));
    request.on('error',reject);if(body)request.write(JSON.stringify(body));request.end();
  });
}

function listen(server){return new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',()=>resolve(server.address().port));});}

async function unusedPort(){const probe=net.createServer();const port=await listen(probe);await new Promise(resolve=>probe.close(resolve));return port;}

function tunnel(mixedPort,host,destinationPort){
  return new Promise((resolve,reject)=>{
    const client=net.createConnection({host:'127.0.0.1',port:mixedPort});clientSockets.add(client);
    let data=Buffer.alloc(0),done=false;
    const timeout=setTimeout(()=>finish(new Error('CONNECT timeout')),3000);
    function finish(error){
      if(done)return;done=true;clearTimeout(timeout);client.off('data',receive);client.off('error',failed);client.off('close',closed);
      if(error){client.destroy();reject(error);}else resolve(client);
    }
    function failed(error){finish(error);}function closed(){finish(new Error('CONNECT closed'));}
    function receive(chunk){
      data=Buffer.concat([data,chunk]);const separator=data.indexOf('\r\n\r\n');
      if(separator<0)return;
      if(!/^HTTP\/1\.[01] 200\b/.test(data.toString('utf8',0,separator)))return finish(new Error('CONNECT rejected'));
      const rest=data.subarray(separator+4);if(rest.length)client.unshift(rest);finish();
    }
    client.on('error',failed);client.on('close',closed);client.on('data',receive);
    client.once('connect',()=>client.write(`CONNECT ${host}:${destinationPort} HTTP/1.1\r\nHost: ${host}:${destinationPort}\r\n\r\n`));
    // Keep an error handler after handshake so a rejected test connection cannot crash Node.
    client.on('error',()=>{});
  });
}

function exchange(client,message){
  return new Promise((resolve,reject)=>{
    let received='';const timeout=setTimeout(()=>finish(new Error('Echo timeout')),2500);
    function finish(error){clearTimeout(timeout);client.off('data',data);client.off('error',fail);client.off('close',closed);error?reject(error):resolve();}
    function data(chunk){received+=chunk.toString();if(received.includes(message))finish();}
    function fail(error){finish(error);}function closed(){finish(new Error('Echo closed'));}
    client.on('data',data);client.once('error',fail);client.once('close',closed);client.write(message);
  });
}

async function main(){
  echoServer=net.createServer(client=>{echoClients.add(client);client.on('close',()=>echoClients.delete(client));client.on('error',()=>{});client.pipe(client);});
  const echoPort=await listen(echoServer),mixedPort=await unusedPort();
  const before={mode:'rule','mixed-port':mixedPort,'allow-lan':false,'bind-address':'127.0.0.1',ipv6:false,
    'external-controller':'','external-controller-unix':socketPath,secret:'','log-level':'silent',
    tun:{enable:false},dns:{enable:false},hosts:{'longtask.test':'127.0.0.1','changed.test':'127.0.0.1'},
    proxies:[],'proxy-groups':[],rules:['DOMAIN,longtask.test,DIRECT','DOMAIN,changed.test,DIRECT','MATCH,REJECT']};
  const filename=path.join(directory,'candidate.yaml');fs.writeFileSync(filename,engine.dumpYAML(before),{mode:0o600});
  core=spawn(loc.core,['-d',directory,'-f',filename],{stdio:'ignore'});
  let started=false;
  for(let i=0;i<40;i++){
    if(core.exitCode!==null)throw new Error('Temporary core stopped');
    try{await api('GET','/configs');started=true;break;}catch{await sleep(75);}
  }
  assert(started,'Temporary core must start');
  const longTask=await tunnel(mixedPort,'longtask.test',echoPort);
  await exchange(longTask,'before-reload\n');
  const initial=(await api('GET','/connections')).connections.find(connection=>Number(connection.metadata.sourcePort)===longTask.localPort);
  assert(initial,'Long connection must be tracked');
  const changedBefore=await tunnel(mixedPort,'changed.test',echoPort);await exchange(changedBefore,'rule-before\n');changedBefore.destroy();
  const after={...before,rules:['DOMAIN,longtask.test,DIRECT','DOMAIN,changed.test,REJECT','MATCH,REJECT']};
  await api('PUT','/configs?force=false',{payload:engine.dumpYAML(after)});
  await exchange(longTask,'after-reload-1\n');
  const rules=(await api('GET','/rules')).rules;
  assert(rules.some(rule=>rule.payload==='changed.test'&&rule.proxy==='REJECT'),'New rule must apply');
  const stillAlive=(await api('GET','/connections')).connections.find(connection=>connection.id===initial.id);
  assert(stillAlive,'Original live connection must keep the same tracker ID');
  await exchange(longTask,'after-reload-2\n');
  let rejected=false;
  try{const newTask=await tunnel(mixedPort,'changed.test',echoPort);await exchange(newTask,'must-be-rejected\n');newTask.destroy();}
  catch{rejected=true;}
  assert(rejected,'A new connection must obey the changed REJECT rule');
  longTask.destroy();
  console.log('PASS: 隔离 Mihomo force=false 热重载后，同一条已建立直连 TCP 连接继续双向传输；新连接遵循新规则；全部路径由临时fixture生成。');
}

main().catch(error=>{console.error(error.message);process.exitCode=1;}).finally(async()=>{
  for(const client of clientSockets)client.destroy();for(const client of echoClients)client.destroy();
  if(echoServer)await new Promise(resolve=>echoServer.close(resolve));
  if(core&&core.exitCode===null){core.kill('SIGTERM');await Promise.race([new Promise(resolve=>core.once('exit',resolve)),sleep(1000)]);if(core.exitCode===null)core.kill('SIGKILL');}
  fs.rmSync(directory,{recursive:true,force:true});
});
