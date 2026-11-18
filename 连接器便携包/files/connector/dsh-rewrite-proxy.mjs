// dsh-rewrite-proxy.mjs — 公网隧道访问桌面 App 引擎
// 隧道 -> 127.0.0.1:14926（本代理）-> 改写 Host/Origin 为受信任 authority -> 127.0.0.1:14925
// 带「过期策略」准入检查（gate.json）：A 不检查 / B 过期拒新连接 / C 过期全断
import http from 'node:http';
import net from 'node:net';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const LISTEN_PORT = Number(process.env.DSH_PROXY_PORT || 14926);
const TARGET_PORT = Number(process.env.DSH_PROXY_TARGET || 14925);
// 局域网 IP 从 ~/.dsh/connector/config.json 读取（服务端启动时自动探测写入）
function loadLanIp() {
  try {
    const p = join(process.env.USERPROFILE || '', '.dsh', 'connector', 'config.json');
    const j = JSON.parse(readFileSync(p, 'utf8').replace(/^\uFEFF/, ''));
    return j && j.lanIp ? j.lanIp : '';
  } catch { return ''; }
}const FAKE_HOST = process.env.DSH_PROXY_HOST || ((loadLanIp() || '127.0.0.1') + ':' + TARGET_PORT);
const TARGET_HOST = '127.0.0.1';
const GATE = join(process.env.USERPROFILE || '', '.dsh', 'connector', 'gate.json');

function readGate() {
  try { return JSON.parse(readFileSync(GATE, 'utf8').replace(/^\uFEFF/, '')); } catch { return { mode: 'A', expiresAt: 0 }; }
}
function expired(g) {
  if (!g || g.mode === 'A') return false;
  return g.expiresAt > 0 && Date.now() > g.expiresAt;
}

function rewriteHeaders(headers) {
  const h = { ...headers };
  h.host = FAKE_HOST;
  h.origin = `http://${FAKE_HOST}`;
  if (h.referer) h.referer = `http://${FAKE_HOST}/`;
  return h;
}

const server = http.createServer((req, res) => {
  const g = readGate();
  if (expired(g)) {
    res.writeHead(403, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('link expired: 请在 DSH 连接器里重新生成二维码');
    return;
  }
  const up = http.request({
    host: TARGET_HOST, port: TARGET_PORT, method: req.method, path: req.url,
    headers: rewriteHeaders(req.headers)
  }, (r) => {
    res.writeHead(r.statusCode || 502, r.headers);
    r.pipe(res);
  });
  up.on('error', (e) => {
    try { res.writeHead(502, { 'content-type': 'text/plain' }); res.end('proxy error: ' + (e.code || e.message)); } catch {}
  });
  req.pipe(up);
});

// WebSocket upgrade：同样做准入检查
server.on('upgrade', (req, socket) => {
  const g = readGate();
  if (expired(g)) { try { socket.destroy(); } catch {} return; }
  const up = net.connect(TARGET_PORT, TARGET_HOST, () => {
    const h = rewriteHeaders(req.headers);
    const lines = [`${req.method} ${req.url} HTTP/1.1`];
    for (const [k, v] of Object.entries(h)) {
      if (Array.isArray(v)) v.forEach(x => lines.push(`${k}: ${x}`));
      else if (v !== undefined) lines.push(`${k}: ${v}`);
    }
    lines.push('', '');
    up.write(lines.join('\r\n'));
    up.pipe(socket);
    socket.pipe(up);
  });
  up.on('error', () => { try { socket.destroy(); } catch {} });
  socket.on('error', () => { try { up.destroy(); } catch {} });
  socket.on('close', () => { try { up.destroy(); } catch {} });
});

// 跟踪底层连接，供 C 模式强制断开
const conns = new Set();
server.on('connection', (socket) => {
  const g = readGate();
  if (expired(g)) { try { socket.destroy(); } catch {} return; }
  conns.add(socket);
  socket.on('close', () => conns.delete(socket));
});
setInterval(() => {
  const g = readGate();
  if (g.mode === 'C' && expired(g)) {
    for (const s of [...conns]) { try { s.destroy(); } catch {} }
    conns.clear();
  }
}, 1000);

server.on('error', (e) => { console.error('proxy error:', e.code || e.message); if (e.code === 'EADDRINUSE') process.exit(3); });
server.listen(LISTEN_PORT, '127.0.0.1', () => console.log(`rewrite proxy 127.0.0.1:${LISTEN_PORT} -> ${TARGET_PORT} as ${FAKE_HOST} (gate: A/B/C)`));
