// dsh-port-forward.mjs — 局域网 TCP 转发 192.168.1.2:14925 -> 127.0.0.1:14925
// 带「过期策略」准入检查：读 ~/.dsh/connector/gate.json
//   A = 不检查（长期有效）
//   B = 过期后拒绝新连接，已连接的继续
//   C = 过期后断开所有连接并拒绝新连接
import net from 'node:net';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// 局域网 IP 从 ~/.dsh/connector/config.json 读取（服务端启动时自动探测写入）
function loadLanIp() {
  try {
    const p = join(process.env.USERPROFILE || '', '.dsh', 'connector', 'config.json');
    const j = JSON.parse(readFileSync(p, 'utf8').replace(/^\uFEFF/, ''));
    return j && j.lanIp ? j.lanIp : '';
  } catch { return ''; }
}const LISTEN_HOST = process.env.DSH_FWD_LISTEN_HOST || loadLanIp() || '127.0.0.1';
const LISTEN_PORT = Number(process.env.DSH_FWD_LISTEN_PORT || 14925);
const TARGET_HOST = '127.0.0.1';
const TARGET_PORT = Number(process.env.DSH_FWD_TARGET_PORT || 14925);
const GATE = join(process.env.USERPROFILE || '', '.dsh', 'connector', 'gate.json');

function readGate() {
  try { return JSON.parse(readFileSync(GATE, 'utf8').replace(/^\uFEFF/, '')); } catch { return { mode: 'A', expiresAt: 0 }; }
}
function expired(g) {
  if (!g || g.mode === 'A') return false;
  return g.expiresAt > 0 && Date.now() > g.expiresAt;
}

const conns = new Set();

const server = net.createServer((client) => {
  const g = readGate();
  if (expired(g)) {
    // 过期：拒绝新连接（B / C 都这样）
    try { client.destroy(); } catch {}
    return;
  }
  client.setNoDelay(true);
  const upstream = net.connect({ host: TARGET_HOST, port: TARGET_PORT });
  upstream.setNoDelay(true);
  conns.add(client); conns.add(upstream);
  const kill = () => {
    try { client.destroy(); } catch {}
    try { upstream.destroy(); } catch {}
    conns.delete(client); conns.delete(upstream);
  };
  client.on('error', kill);
  upstream.on('error', kill);
  client.on('close', kill);
  upstream.on('close', kill);
  upstream.on('connect', () => {
    client.pipe(upstream);
    upstream.pipe(client);
  });
});

// C 模式：过期后主动断开所有已连接
setInterval(() => {
  const g = readGate();
  if (g.mode === 'C' && expired(g)) {
    for (const s of [...conns]) { try { s.destroy(); } catch {} }
    conns.clear();
  }
}, 1000);

server.on('error', (e) => {
  console.error('forwarder error:', e.code || e.message);
  if (e.code === 'EADDRINUSE') process.exit(3);
});
server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(`forwarding ${LISTEN_HOST}:${LISTEN_PORT} -> ${TARGET_HOST}:${TARGET_PORT} (gate: A/B/C)`);
});
