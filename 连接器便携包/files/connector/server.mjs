// connector/server.mjs — DSH 连接器本地服务
// 作用：管理内网转发 / 外网隧道 / 改写代理，提供本地 API 与二维码给 HTA 界面调用
// 端口：14930（本地回环）
import http from 'node:http';
import net from 'node:net';
import https from 'node:https';
import { lookup } from 'node:dns/promises';
import { spawn, execFile } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { networkInterfaces } from 'node:os';

const HOME = join(process.env.USERPROFILE || '', '.dsh');
const DIR = join(HOME, 'connector');
const QR_PATH = join(DIR, 'qr.png');
const SETTINGS_PATH = join(DIR, 'settings.json');
const DESKTOP_URL_FILE = join(HOME, 'desktop-web-url.txt');
const PUBLIC_URL_FILE = join(HOME, 'desktop-public-url.txt');
const EXE = 'F:\\deepseek\\DeepSeek Harness.exe';
const CLOUDFLARED = join(HOME, 'bin', 'cloudflared.exe');
const TUNNEL_LOG = join(HOME, 'tunnel-14926.log');
const API_PORT = 14930;
// ---- 版本契约：界面/插件靠这两个值判断是否适配 ----
// API_VERSION 在破坏性改动时 +1；调用方声明所需版本，低了即判「版本过低」
const API_VERSION = 1;
const PROGRAM_VERSION = '1.0.0';
const LAN_PORT = 14925;
const PROXY_PORT = 14926;

if (!existsSync(DIR)) mkdirSync(DIR, { recursive: true });

// ---------------- 本机局域网 IP（自动探测，避免写死导致换网段就失效） ----------------
const CONFIG_PATH = join(DIR, 'config.json');
function detectLanIp() {
  try {
    const ifs = networkInterfaces();
    const candidates = [];
    for (const name of Object.keys(ifs)) {
      for (const a of ifs[name] || []) {
        if (a.family !== 'IPv4' || a.internal) continue;
        if (a.address.startsWith('169.254.')) continue;   // APIPA 不算
        candidates.push(a.address);
      }
    }
    // 优先私网地址，其次任意
    const priv = candidates.find(x => /^192\.168\./.test(x))
      || candidates.find(x => /^10\./.test(x))
      || candidates.find(x => /^172\.(1[6-9]|2\d|3[01])\./.test(x));
    return priv || candidates[0] || '127.0.0.1';
  } catch { return '127.0.0.1'; }
}
function loadConfig() {
  try { return JSON.parse(readFileSync(CONFIG_PATH, 'utf8').replace(/^\uFEFF/, '')); } catch { return {}; }
}
function saveConfig(c) {
  try { writeFileSync(CONFIG_PATH, JSON.stringify(c, null, 2), 'utf8'); } catch {}
}
// 启动时刷新一次：IP 变了就更新，并记下与 App 启动参数是否一致
const detectedIp = detectLanIp();
saveConfig({ ...loadConfig(), lanIp: detectedIp, updatedAt: new Date().toISOString() });

// ---------------- settings ----------------
const DEFAULT_SETTINGS = { display: 'both', windowMinutes: 5, autoStartLan: true, expiryMode: 'B', channelMode: 'exclusive' };
const GATE_PATH = join(DIR, 'gate.json');
function writeGate(mode, expiresAt) {
  try { writeFileSync(GATE_PATH, JSON.stringify({ mode, expiresAt }), 'utf8'); } catch {}
}
function loadSettings() {
  try { return { ...DEFAULT_SETTINGS, ...JSON.parse(readFileSync(SETTINGS_PATH, 'utf8')) }; }
  catch { return { ...DEFAULT_SETTINGS }; }
}
function saveSettings(s) {
  try { writeFileSync(SETTINGS_PATH, JSON.stringify(s, null, 2), 'utf8'); return true; } catch { return false; }
}
let settings = loadSettings();

// ---------------- state ----------------
const state = {
  lan: { on: false, url: '' },
  wan: { on: false, url: '', domain: '' },
  expiresAt: 0,
  windowMinutes: settings.windowMinutes,
  lastAction: '',
  lastError: ''
};

function portOpen(port, host = '127.0.0.1', timeout = 800) {
  return new Promise((resolve) => {
    const s = net.connect({ port, host });
    const done = (v) => { try { s.destroy(); } catch {} resolve(v); };
    s.setTimeout(timeout);
    s.once('connect', () => done(true));
    s.once('timeout', () => done(false));
    s.once('error', () => done(false));
  });
}
async function waitPort(port, host, ms = 12000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await portOpen(port, host)) return true;
    await new Promise(r => setTimeout(r, 120));
  }
  return false;
}
function runHidden(file, args, extraEnv = {}) {
  const child = spawn(file, args, {
    windowsHide: true,
    detached: true,
    stdio: 'ignore',
    env: { ...process.env, ...extraEnv }
  });
  child.unref();
  return child;
}
function readToken() {
  try {
    const lines = readFileSync(DESKTOP_URL_FILE, 'utf8').split('\n').map(s => s.trim()).filter(Boolean);
    const lan = lines.find(l => l.includes('127.0.0.1')) || '';
    const m = /[?&]token=([A-Za-z0-9_\-]+)/.exec(lan);
    return m ? m[1] : '';
  } catch { return ''; }
}

// ---------------- lan channel ----------------
async function startLan() {
  // 引擎不在时转发器照样能绑端口，但手机连上去会被拒 —— 先拦住这种假成功
  if (!(await portOpen(LAN_PORT, '127.0.0.1'))) {
    throw new Error('桌面 App 引擎未监听 14925，请先打开 DeepSeek');
  }
  const lanIp = loadConfig().lanIp || detectedIp;
  if (await portOpen(LAN_PORT, lanIp)) {
    state.lan.on = true;
    state.lan.url = buildLanUrl();
    return state.lan;
  }
  const fwd = join(HOME, 'run-port-forward.cmd');
  if (!existsSync(fwd)) throw new Error('缺少 run-port-forward.cmd');
  runHidden('cmd.exe', ['/c', fwd], { DSH_FWD_LISTEN_HOST: lanIp });
  const ok = await waitPort(LAN_PORT, lanIp, 10000);
  if (!ok) throw new Error('局域网转发器未能启动（端口 14925 未监听）');
  state.lan.on = true;
  state.lan.url = buildLanUrl();
  return state.lan;
}
function buildLanUrl() {
  const tok = readToken();
  const ip = loadConfig().lanIp || detectedIp;
  return `http://${ip}:${LAN_PORT}/${tok ? '?token=' + tok : ''}`;
}

// ---------------- wan channel ----------------
async function ensureProxy() {
  if (await portOpen(PROXY_PORT, '127.0.0.1')) return true;
  const cmd = join(HOME, 'run-rewrite-proxy.cmd');
  if (!existsSync(cmd)) throw new Error('缺少 run-rewrite-proxy.cmd');
  const ip = loadConfig().lanIp || detectedIp;
  runHidden('cmd.exe', ['/c', cmd], { DSH_PROXY_HOST: ip + ':' + LAN_PORT });
  return await waitPort(PROXY_PORT, '127.0.0.1', 10000);
}
function killTunnel() {
  return new Promise((resolve) => {
    execFile('powershell.exe', ['-NoProfile', '-Command',
      "Get-CimInstance Win32_Process -Filter \"Name='cloudflared.exe'\" | Where-Object { $_.CommandLine -match '14926' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
    ], { windowsHide: true }, () => resolve(true));
  });
}
// 单独关掉某一条通道（互斥模式用）
async function stopWanChannel() {
  await killTunnel();
  state.wan = { on: false, url: '', domain: '', reachable: false };
}
async function stopLanChannel() {
  const psKill = "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and ($_.CommandLine -match 'run-port-forward|dsh-port-forward\\.mjs') } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }";
  await new Promise((resolve) => execFile('powershell.exe', ['-NoProfile', '-Command', psKill], { windowsHide: true }, () => resolve(true)));
  await new Promise(r => setTimeout(r, 900));
  state.lan = { on: false, url: '' };
}

// ---------------- 状态真实性：wan 以「进程 + 隧道域名」为准，不再只看内存 ----------------
// 重启连接器后内存里的 state.wan 是空的，但 cloudflared 还在跑 —— 界面会显示「外网已关闭」，
// 与实际不符。这里用进程 + 日志里最后一个域名还原真实状态，并缓存 4 秒避免频繁查进程。
let wanCache = { at: 0, on: false, domain: '', url: '' };
function cloudflaredRunning() {
  return new Promise((resolve) => {
    execFile('powershell.exe', ['-NoProfile', '-Command',
      "Get-CimInstance Win32_Process -Filter \"Name='cloudflared.exe'\" | Where-Object { $_.CommandLine -match '14926' } | Select-Object -First 1 -ExpandProperty ProcessId"
    ], { windowsHide: true, timeout: 8000 }, (err, so) => resolve(!!String(so || '').trim()));
  });
}
async function detectWan() {
  const now = Date.now();
  if (now - wanCache.at < 4000) return wanCache;
  let on = false, domain = '', url = '';
  if (await cloudflaredRunning()) {
    try {
      const txt = readFileSync(TUNNEL_LOG, 'utf8');
      const ms = [...txt.matchAll(/https:\/\/([a-z0-9-]+\.trycloudflare\.com)/g)];
      if (ms.length > 0) domain = ms[ms.length - 1][1];
    } catch {}
    if (!domain) {
      try {
        const m = /https:\/\/([a-z0-9-]+\.trycloudflare\.com)/.exec(readFileSync(PUBLIC_URL_FILE, 'utf8'));
        if (m) domain = m[1];
      } catch {}
    }
    on = domain !== '';
    if (on) {
      const tok = readToken();
      url = `https://${domain}/${tok ? '?token=' + tok : ''}`;
    }
  }
  wanCache = { at: now, on, domain, url };
  return wanCache;
}

async function readDomain(ms = 45000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try {
      const txt = readFileSync(TUNNEL_LOG, 'utf8');
      const m = /https:\/\/([a-z0-9-]+\.trycloudflare\.com)/.exec(txt);
      if (m) return m[1];
    } catch {}
    await new Promise(r => setTimeout(r, 600));
  }
  return '';
}
async function startWan() {
  if (!existsSync(CLOUDFLARED)) throw new Error('缺少 cloudflared.exe');
  if (!(await portOpen(LAN_PORT, '127.0.0.1'))) throw new Error('桌面 App 引擎未监听 14925，请先打开 DeepSeek');
  if (!(await ensureProxy())) throw new Error('改写代理未能启动（14926）');

  await killTunnel();
  try { writeFileSync(TUNNEL_LOG, '', 'utf8'); } catch {}
  await new Promise(r => setTimeout(r, 800));

  const args = ['tunnel', '--url', `http://127.0.0.1:${PROXY_PORT}`, '--no-autoupdate',
                '--logfile', TUNNEL_LOG, '--loglevel', 'info'];
  runHidden(CLOUDFLARED, args);

  const domain = await readDomain(50000);
  if (!domain) throw new Error('隧道未分配域名，见 tunnel-14926.log');
  const tok = readToken();
  const url = `https://${domain}/${tok ? '?token=' + tok : ''}`;
  // 不等太久：先返回链接让界面立刻切换，DNS 传播可在后台继续
  const reach = await waitReachable(url, 12000);
  state.wan = { on: true, url, domain, reachable: reach.ok, waitedMs: reach.waitedMs };
  try { writeFileSync(PUBLIC_URL_FILE, url + '\n', 'utf8'); } catch {}
  return state.wan;
}

// 探测域名是否已可访问（quick tunnel 首次 DNS 传播需 20-40 秒）
function probeHttps(url, timeout = 8000) {
  return new Promise((resolve) => {
    const req = https.get(url, { timeout }, (res) => {
      res.resume();
      resolve(res.statusCode || 0);
    });
    req.on('error', () => resolve(0));
    req.on('timeout', () => { try { req.destroy(); } catch {} resolve(0); });
  });
}
async function waitReachable(url, ms = 50000) {
  const end = Date.now() + ms;
  const host = new URL(url).hostname;
  let dnsOk = false;
  while (Date.now() < end) {
    if (!dnsOk) { try { await lookup(host); dnsOk = true; } catch {} }
    if (dnsOk) {
      const code = await probeHttps(url);
      if (code > 0) return { ok: true, code, waitedMs: ms - (end - Date.now()) };
    }
    await new Promise(r => setTimeout(r, 2500));
  }
  return { ok: false, code: 0, waitedMs: ms };
}

// ---------------- qr ----------------
function findPython() {
  const cands = [
    join(HOME, 'dsh-runtimes', 'dsh-primary-runtime', 'dependencies', 'python', 'python.exe'),
    'python.exe'
  ];
  for (const c of cands) { try { if (c.includes('\\') ? existsSync(c) : true) return c; } catch {} }
  return 'python.exe';
}
// 每个通道各存一份，双通模式要同时显示两个二维码
const QR_FILES = { lan: join(DIR, 'qr-lan.png'), wan: join(DIR, 'qr-wan.png') };
function qrPathFor(mode) { return QR_FILES[mode] || QR_PATH; }

function makeQr(url, mode) {
  const outPath = qrPathFor(mode || 'lan');
  return new Promise((resolve, reject) => {
    const py = findPython();
    const code = 'import sys,qrcode;from qrcode.constants import ERROR_CORRECT_M;' +
      'q=qrcode.QRCode(error_correction=ERROR_CORRECT_M,box_size=8,border=3);' +
      'q.add_data(sys.argv[1]);q.make(fit=True);' +
      'q.make_image(fill_color="black",back_color="white").convert("RGB").save(sys.argv[2])';
    execFile(py, ['-c', code, url, outPath], { windowsHide: true, timeout: 20000 }, (err) => {
      if (err) reject(new Error('二维码生成失败：' + err.message)); else resolve(outPath);
    });
  });
}

// ---------------- http api ----------------
const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET,POST,OPTIONS',
  'access-control-allow-headers': 'content-type'
};
function send(res, code, obj, type = 'application/json; charset=utf-8') {
  const body = typeof obj === 'string' ? obj : JSON.stringify(obj);
  res.writeHead(code, { ...CORS, 'content-type': type, 'cache-control': 'no-store' });
  res.end(body);
}
const server = http.createServer(async (req, res) => {
  try {
    if (req.method === 'OPTIONS') { res.writeHead(204, CORS); res.end(); return; }
    const u = new URL(req.url, 'http://127.0.0.1');
    if (u.pathname === '/api/status') {
      const engineUp = await portOpen(LAN_PORT, '127.0.0.1');
      const curIp = loadConfig().lanIp || detectedIp;
      const wanLive = await detectWan();
      return send(res, 200, {
        ok: true, apiVersion: API_VERSION, programVersion: PROGRAM_VERSION, settings, state: {
          ...state,
          lan: { ...state.lan, on: await portOpen(LAN_PORT, curIp) },
          wan: {
            ...state.wan,
            on: wanLive.on,
            domain: wanLive.domain || state.wan.domain,
            url: wanLive.url || state.wan.url,
            reachable: state.wan.reachable !== false
          },
          engineUp,
          lanIp: loadConfig().lanIp || detectedIp,
          appTrustedHost: process.env.DSH_DESKTOP_TRUSTED || '',
          ipMismatch: (() => {
            const ip = loadConfig().lanIp || detectedIp;
            const want = ip + ':' + LAN_PORT;
            const cur = process.env.DSH_DESKTOP_TRUSTED || '';
            return cur !== '' && cur !== want;
          })(),
          remainingMs: Math.max(0, state.expiresAt - Date.now())
        }
      });
    }
    if (u.pathname === '/api/settings') {
      if (req.method === 'POST') {
        let body = '';
        req.on('data', c => body += c);
        req.on('end', () => {
          try {
            const j = JSON.parse(body || '{}');
            if (j.display) settings.display = j.display;
            if (j.windowMinutes) settings.windowMinutes = Math.max(1, Math.min(60, Number(j.windowMinutes)));
            if (j.expiryMode && ['A','B','C'].includes(j.expiryMode)) settings.expiryMode = j.expiryMode;
            if (j.channelMode && ['exclusive','dual'].includes(j.channelMode)) settings.channelMode = j.channelMode;
            saveSettings(settings);
            state.windowMinutes = settings.windowMinutes;
            send(res, 200, { ok: true, settings });
          } catch (e) { send(res, 400, { ok: false, error: String(e.message) }); }
        });
        return;
      }
      return send(res, 200, { ok: true, settings });
    }
    if (u.pathname === '/api/start') {
      const mode = u.searchParams.get('mode') || 'lan';
      state.lastError = '';
      try {
        let url = '';
        // 互斥模式：开一条就关掉另一条（同时只保留一个二维码）
        if (settings.channelMode === 'exclusive') {
          if (mode === 'lan') await stopWanChannel();
          else await stopLanChannel();
        }
        if (mode === 'lan') { const r = await startLan(); url = r.url; }
        else { const r = await startWan(); url = r.url; }
        const mins = settings.windowMinutes;
        state.expiresAt = Date.now() + mins * 60000;
        writeGate(settings.expiryMode || 'B', state.expiresAt);
        state.lastAction = mode;
        let qrOk = false;
        try { await makeQr(url, mode); qrOk = true; } catch (e) { state.lastError = e.message; }
        return send(res, 200, {
          ok: true, mode, url, qrOk, expiresAt: state.expiresAt,
          windowMinutes: mins, display: settings.display,
          reachable: state.wan.reachable !== false, waitedMs: state.wan.waitedMs || 0
        });
      } catch (e) {
        state.lastError = String(e.message || e);
        return send(res, 500, { ok: false, error: state.lastError });
      }
    }
    if (u.pathname === '/api/launch-app') {
      if (await portOpen(LAN_PORT, '127.0.0.1')) {
        return send(res, 200, { ok: true, already: true, engineUp: true });
      }
      if (!existsSync(EXE)) return send(res, 500, { ok: false, error: '找不到 DeepSeek: ' + EXE });
      // 关键：本进程带着 ELECTRON_RUN_AS_NODE=1（为了让连接器脚本以 Node 模式跑），
      // 子进程会继承它 —— 那会让 DeepSeek 以 Node 模式启动、没有窗口、不监听端口。
      // 启动 App 前必须把它从环境里摘掉。
      const cleanEnv = { ...process.env };
      delete cleanEnv.ELECTRON_RUN_AS_NODE;
      let launchErr = '';
      let launchedPid = 0;
      await new Promise((resolve) => {
        execFile('powershell.exe',
          ['-NoProfile', '-Command', `$p = Start-Process -FilePath "${EXE}" -PassThru; Write-Output $p.Id`],
          { windowsHide: true, timeout: 20000, env: cleanEnv },
          (err, so, se) => {
            if (err) launchErr = String(err.message || se || err);
            const m = String(so || '').match(/\d+/);
            if (m) launchedPid = Number(m[0]);
            resolve(true);
          });
      });
      if (launchErr) return send(res, 500, { ok: false, error: '启动失败：' + launchErr });
      const launchT0 = Date.now();
      const up = await waitPort(LAN_PORT, '127.0.0.1', 25000);
      const launchedMs = Date.now() - launchT0;
      return send(res, 200, { ok: up, engineUp: up, launchedMs, pid: launchedPid, error: up ? '' : '等待 25 秒仍未就绪，请手动检查 DeepSeek 窗口' });
    }
    if (u.pathname === '/api/stop') {
      await killTunnel();
      state.wan = { on: false, url: '', domain: '' };
      state.expiresAt = 0;
      // 关键：cmd 包装只是父进程，真正监听端口的是它下面的 electron 子进程。
      // 必须同时按脚本名匹配，否则端口仍在监听、手机照样能连（实测踩过）。
      const psKill = "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and ($_.CommandLine -match 'run-port-forward|dsh-port-forward\.mjs|run-rewrite-proxy|dsh-rewrite-proxy\.mjs') } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }";
      await new Promise((resolve) => execFile('powershell.exe', ['-NoProfile', '-Command', psKill], { windowsHide: true }, () => resolve(true)));
      await new Promise(r => setTimeout(r, 1200));
      const laneIp = loadConfig().lanIp || detectedIp;
      const lanGone = !(await portOpen(LAN_PORT, laneIp));
      state.lan = { on: !lanGone, url: '' };
      writeGate('A', 0);
      state.lastAction = 'stop';
      return send(res, 200, { ok: true, lanPortClosed: lanGone });
    }
    if (u.pathname === '/qr.png') {
      const want = u.searchParams.get('mode');
      let target = want ? qrPathFor(want) : QR_PATH;
      if (!existsSync(target)) target = QR_PATH;
      if (!existsSync(target)) return send(res, 404, 'no qr');
      const buf = readFileSync(target);
      res.writeHead(200, { ...CORS, 'content-type': 'image/png', 'cache-control': 'no-store' });
      return res.end(buf);
    }
    if (u.pathname === '/') {
      return send(res, 200, JSON.stringify({ ok: true, service: 'dsh-connector', apiVersion: API_VERSION, programVersion: PROGRAM_VERSION }));
    }
    send(res, 404, { ok: false, error: 'not found', apiVersion: API_VERSION, programVersion: PROGRAM_VERSION });
  } catch (e) {
    send(res, 500, { ok: false, error: String(e.message || e) });
  }
});
server.listen(API_PORT, '127.0.0.1', () => {
  console.log(`connector api on http://127.0.0.1:${API_PORT}`);
  autoStartLanOnBoot();
});

// ---------------- 开机自启内网通道（settings.autoStartLan） ----------------
// 之前这个开关只写进 settings.json、没有任何代码读它 —— 重启后内网通道不会自己回来。
// 现在连接器启动时等引擎就绪（最多 20 秒）再自动开内网；互斥模式且外网还活着时跳过。
async function autoStartLanOnBoot() {
  if (!settings.autoStartLan) { console.log('autoStartLan: off'); return; }
  const engineUp = await waitPort(LAN_PORT, '127.0.0.1', 20000);
  if (!engineUp) { console.log('autoStartLan: 引擎未就绪，跳过'); return; }
  if (settings.channelMode === 'exclusive') {
    const wanLive = await detectWan();
    if (wanLive.on) { console.log('autoStartLan: 互斥模式下外网在跑，跳过'); return; }
  }
  try {
    const r = await startLan();
    const mins = settings.windowMinutes;
    state.expiresAt = Date.now() + mins * 60000;
    writeGate(settings.expiryMode || 'B', state.expiresAt);
    state.lastAction = 'lan(auto)';
    try { await makeQr(r.url, 'lan'); } catch (e) { state.lastError = e.message; }
    console.log('autoStartLan: ' + r.url);
  } catch (e) {
    state.lastError = 'autoStartLan: ' + String(e.message || e);
    console.log(state.lastError);
  }
}
