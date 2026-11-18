// cdp-check.mjs — 用 Chrome DevTools 协议在真浏览器里验证 DSH 手机端页面
// 用途：打开连接器给出的 URL → 关掉插件首启弹窗 → 点左侧「连接器」→ 截图
// 用法（Electron 以 Node 模式跑）：
//   set ELECTRON_RUN_AS_NODE=1
//   "F:\deepseek\DeepSeek Harness.exe" cdp-check.mjs <debugPort> <url> <outPng> [--keep]
// 前置：chrome --headless=new --remote-debugging-port=<port> --user-data-dir=<tmp>
import { writeFileSync } from 'node:fs';

const port = process.argv[2] || '9333';
const url = process.argv[3];
const out = process.argv[4] || 'shot.png';
if (!url) { console.error('usage: cdp-check.mjs <port> <url> <out.png>'); process.exit(2); }

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function targets() {
  const r = await fetch(`http://127.0.0.1:${port}/json/list`);
  return await r.json();
}

async function connect() {
  for (let i = 0; i < 60; i++) {
    try {
      const list = await targets();
      const page = list.find(t => t.type === 'page' && t.webSocketDebuggerUrl);
      if (page) return page.webSocketDebuggerUrl;
    } catch {}
    await sleep(500);
  }
  throw new Error('devtools endpoint not ready');
}

// Chrome 只监听 127.0.0.1，而 target 里给的是 localhost —— Node 会先解析到 ::1 导致握手失败
const rawWsUrl = (await connect()).replace('://localhost:', '://127.0.0.1:');
const ws = new WebSocket(rawWsUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = (e) => rej(new Error('ws error')); });

let id = 0;
const pending = new Map();
ws.onmessage = (ev) => {
  let msg; try { msg = JSON.parse(ev.data); } catch { return; }
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
};
function cmd(method, params = {}) {
  const myId = ++id;
  return new Promise((resolve) => {
    pending.set(myId, resolve);
    ws.send(JSON.stringify({ id: myId, method, params }));
  });
}
async function evalJs(expression) {
  const r = await cmd('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  return r.result?.result?.value;
}

await cmd('Page.enable');
await cmd('Runtime.enable');
await cmd('Page.navigate', { url });
// 等 SPA 真正渲染出内容（隧道慢时首屏要 8~15 秒）
let bodyLen = 0;
for (let i = 0; i < 15; i++) {
  await sleep(1500);
  bodyLen = (await evalJs('document.body ? document.body.innerText.length : 0')) || 0;
  if (bodyLen > 200) break;
}

const report = {};
report.title = await evalJs('document.title');
report.boot = await evalJs('typeof window.__DSH_BOOT__');
report.bodyLen = await evalJs('document.body.innerText.length');

// 1) 关掉插件首启「用户须知」弹窗（勾选 + 确认）
report.modal = await evalJs(`(() => {
  const box = document.querySelector('input[type=checkbox]');
  if (box && !box.checked) box.click();
  const btn = [...document.querySelectorAll('button')].find(b => /我已知晓|继续/.test(b.textContent || ''));
  if (btn) { btn.click(); return 'dismissed'; }
  return box ? 'checked-only' : 'no-modal';
})()`);
await sleep(1500);

// 2) 点左侧「连接器」
report.nav = await evalJs(`(() => {
  const leaves = [...document.querySelectorAll('a,button,div,span,li')];
  const hit = leaves.find(e => e.childElementCount === 0 && (e.textContent || '').trim() === '连接器');
  if (!hit) return 'not-found';
  hit.click();
  return 'clicked';
})()`);
await sleep(3500);

// 3) 记录连接器页面上真实可见的文字（判断是不是插件渲染成功）
report.pageText = await evalJs(`(() => {
  const t = document.body.innerText.replace(/\\s+/g, ' ').trim();
  return t.slice(0, 400);
})()`);

const shot = await cmd('Page.captureScreenshot', { format: 'png' });
if (shot.result?.data) { writeFileSync(out, Buffer.from(shot.result.data, 'base64')); report.png = out; }
report.pngBytes = shot.result?.data ? Buffer.from(shot.result.data, 'base64').length : 0;

console.log(JSON.stringify(report, null, 2));
ws.close();
process.exit(0);
