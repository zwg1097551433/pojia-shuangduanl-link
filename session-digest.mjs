// session-digest.mjs — 直接读 DSH 会话日志（zstd 多帧），列出最近会话与最后几条消息
// 用法：node session-digest.mjs [条数] [会话数]
// 不需要 DSH 在跑，也不需要 token；纯读文件。
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { zstdDecompressSync } from 'node:zlib';

const DSH_HOME = process.env.DSH_HOME || join(process.env.USERPROFILE || '', '.dsh');
const SESSIONS = join(DSH_HOME, 'sessions');
const wantMsgs = parseInt(process.argv[2] || '3', 10);
const wantSess = parseInt(process.argv[3] || '8', 10);
const MAGIC = [0x28, 0xB5, 0x2F, 0xFD];

function decodeFrames(buf) {
  const pos = [];
  for (let i = 0; i <= buf.length - 4; i++) {
    if (buf[i] === MAGIC[0] && buf[i + 1] === MAGIC[1] && buf[i + 2] === MAGIC[2] && buf[i + 3] === MAGIC[3]) pos.push(i);
  }
  const lines = [];
  for (let k = 0; k < pos.length; k++) {
    const s = pos[k], e = (k + 1 < pos.length) ? pos[k + 1] : buf.length;
    try { lines.push(...zstdDecompressSync(buf.subarray(s, e)).toString('utf8').split('\n').filter(Boolean)); } catch {}
  }
  return lines;
}

function textOf(d) {
  const c = d?.message?.content ?? d?.content;
  if (Array.isArray(c)) return c.map(x => x.text || '').join(' ').trim();
  if (typeof c === 'string') return c.trim();
  return '';
}

// 找出所有会话目录，按文件修改时间倒序
const found = [];
if (!existsSync(SESSIONS)) { console.log('找不到 ' + SESSIONS); process.exit(1); }
for (const ws of readdirSync(SESSIONS)) {
  const wsDir = join(SESSIONS, ws);
  let st; try { st = statSync(wsDir); } catch { continue; }
  if (!st.isDirectory()) continue;
  for (const s of readdirSync(wsDir)) {
    if (!s.startsWith('session-')) continue;
    const sDir = join(wsDir, s);
    const f = readdirSync(sDir).find(n => n.startsWith('session.v4.jsonl'));
    if (!f) continue;
    const fpath = join(sDir, f);
    try {
      const fs2 = statSync(fpath);
      found.push({ ws, sid: s, path: fpath, mtime: fs2.mtimeMs, size: fs2.size });
    } catch {}
  }
}
found.sort((a, b) => b.mtime - a.mtime);

const wsName = w => w.replace(/^--/, '').replace(/--$/, '').replace(/~/g, '%').replace(/%([0-9A-F]{4})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));
const ts = ms => new Date(ms).toLocaleString('sv-SE').replace('T', ' ');

for (const s of found.slice(0, wantSess)) {
  let lines = [];
  try { lines = decodeFrames(readFileSync(s.path)); } catch {}
  const msgs = [];
  let title = '';
  for (const line of lines) {
    let o; try { o = JSON.parse(line); } catch { continue; }
    const ev = o.event || o;
    if (String(ev.type || '').endsWith('/title') && ev.data?.title) title = ev.data.title;
    const role = ev.data?.message?.role || ev.data?.role;
    if (role !== 'user' && role !== 'assistant') continue;
    const t = textOf(ev.data);
    if (!t) continue;
    if (t.startsWith('<system-reminder>')) continue;
    msgs.push({ role, text: t, time: ev.time });
  }
  console.log('='.repeat(78));
  console.log(`会话 ${s.sid}`);
  console.log(`  工作区 ${wsName(s.ws)}`);
  console.log(`  修改   ${ts(s.mtime)}   ${(s.size / 1024).toFixed(0)} KB   ${msgs.length} 条消息`);
  if (title) console.log(`  标题   ${title}`);
  const tail = msgs.slice(-wantMsgs);
  if (!tail.length) { console.log('  （无正文消息）'); continue; }
  for (const m of tail) {
    const t = m.time ? new Date(m.time).toLocaleTimeString('sv-SE') : '';
    const who = m.role === 'user' ? '你' : 'AI';
    console.log(`  [${t}] ${who}: ${m.text.replace(/\s+/g, ' ').slice(0, 200)}`);
  }
}
console.log('='.repeat(78));
console.log(`共 ${found.length} 个会话，显示最近 ${Math.min(wantSess, found.length)} 个`);
