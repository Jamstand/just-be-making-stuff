
'use strict';
const net = require('net');
const readline = require('readline');
const PORT = parseInt(process.env.CLAUDE_RESOLVE_BRIDGE_PORT || '0', 10);
const TOKEN = process.env.CLAUDE_RESOLVE_BRIDGE_TOKEN || '';
const SUPPORTED = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

function send(obj) { process.stdout.write(JSON.stringify(obj) + '\n'); }

function bridgeRequest(payload) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(PORT, '127.0.0.1');
    let buf = '';
    sock.setTimeout(600000, () => { sock.destroy(); reject(new Error('bridge timeout')); });
    sock.on('error', reject);
    sock.on('data', (d) => {
      buf += d.toString('utf8');
      const i = buf.indexOf('\n');
      if (i >= 0) {
        try { resolve(JSON.parse(buf.slice(0, i))); } catch (e) { reject(e); }
        sock.end();
      }
    });
    sock.write(JSON.stringify(Object.assign({}, payload, { token: TOKEN })) + '\n');
  });
}

const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on('line', async (line) => {
  line = line.trim();
  if (!line) return;
  let msg;
  try { msg = JSON.parse(line); }
  catch (e) { send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }); return; }
  if (msg.method === undefined) return;            // a response; we send no requests
  const isRequest = ('id' in msg) && msg.id !== null;
  if (!isRequest) return;                          // notifications get no reply
  const id = msg.id;
  try {
    if (msg.method === 'initialize') {
      const req = (msg.params || {}).protocolVersion;
      send({ jsonrpc: '2.0', id, result: {
        protocolVersion: SUPPORTED.indexOf(req) >= 0 ? req : '2025-06-18',
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'resolve', version: '1.0.0' } } });
    } else if (msg.method === 'ping') {
      send({ jsonrpc: '2.0', id, result: {} });
    } else if (msg.method === 'tools/list') {
      const r = await bridgeRequest({ op: 'list' });
      if (!r.ok) send({ jsonrpc: '2.0', id, error: { code: -32603, message: String(r.content || 'bridge error') } });
      else send({ jsonrpc: '2.0', id, result: { tools: r.tools || [] } });
    } else if (msg.method === 'tools/call') {
      const p = msg.params || {};
      if (typeof p.name !== 'string') {
        send({ jsonrpc: '2.0', id, error: { code: -32602, message: "Invalid params: 'name' must be a string" } });
        return;
      }
      let r;
      try { r = await bridgeRequest({ op: 'call', name: p.name, arguments: p.arguments || {} }); }
      catch (e) {
        send({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: 'Resolve bridge unreachable: ' + e.message }], isError: true } });
        return;
      }
      const content = [];
      for (const img of (r.images || [])) {
        if (img && img.data) content.push({ type: 'image', data: img.data, mimeType: img.media_type || 'image/jpeg' });
      }
      let text = r.content;
      if (typeof text !== 'string') text = JSON.stringify(text);
      content.push({ type: 'text', text });
      send({ jsonrpc: '2.0', id, result: { content, isError: !r.ok } });
    } else {
      send({ jsonrpc: '2.0', id, error: { code: -32601, message: 'Method not found: ' + msg.method } });
    }
  } catch (e) {
    send({ jsonrpc: '2.0', id, error: { code: -32603, message: 'Internal error: ' + e.message } });
  }
});
