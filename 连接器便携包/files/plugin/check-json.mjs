// check-json.mjs — 用与 DSH 完全一致的方式校验 JSON 文件
// 用法: node check-json.mjs <file> [more files...]
// 退出码: 0 = 全部通过; 1 = 有文件不合法
import { readFileSync } from 'node:fs';

const files = process.argv.slice(2);
let bad = 0;
for (const f of files) {
  try {
    const raw = readFileSync(f, 'utf8');
    const hasBom = raw.charCodeAt(0) === 0xFEFF;
    // DSH 的 readProfileManifest 直接 JSON.parse 原文，BOM 会让它抛错
    JSON.parse(raw);
    if (hasBom) {
      console.log(`FAIL ${f}  (含 UTF-8 BOM，DSH 的 JSON.parse 会崩)`);
      bad++;
    } else {
      console.log(`OK   ${f}`);
    }
  } catch (e) {
    console.log(`FAIL ${f}  ${e.message}`);
    bad++;
  }
}
process.exit(bad === 0 ? 0 : 1);
