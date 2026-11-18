// dsh-connector host 侧：极薄，只占一个插件位。
// 全部业务逻辑在 DSH 连接器程序（http://127.0.0.1:14930），界面在 client.js。
import { appendFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

export const name = 'dsh-connector';
export const inject = [];

function log(msg) {
  try {
    const dir = join(process.env.USERPROFILE || '', '.dsh', 'connector-plugin');
    mkdirSync(dir, { recursive: true });
    appendFileSync(join(dir, 'loaded.log'), `[${new Date().toISOString()}] ${msg}\n`, 'utf8');
  } catch {}
}

export function apply(ctx, config) {
  const enabled = config && config.enabled !== false;
  if (!enabled) { log('skipped: disabled by config'); return; }
  log('mount ok');
  try { ctx.logger?.info?.('[dsh-connector] mounted'); } catch {}
}

export function dispose() {
  log('disposed');
}