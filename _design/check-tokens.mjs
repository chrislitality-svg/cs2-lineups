#!/usr/bin/env node
/* 守卫：三个页面的 :root token 表必须逐字一致。
   用法  node _design/check-tokens.mjs
   退出码 0 = 一致，1 = 有漂移（可直接挂进部署前检查）。

   为什么不抽成一个共享 CSS 文件：那会给每个页面加一个渲染阻塞的外部请求，
   而「首帧即终态」正是这次改造要解决的问题。所以选择内联 + 脚本守卫。 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const FILES = {
  'zs  (战术沙盘)': resolve(here, '../index.html'),
  'zs  (总 Demo)': resolve(here, 'demo.html'),
  'cs2 (门户页)': resolve(here, '../../cs2-portal/index.html'),
  'zl  (我的租赁)': resolve(here, '../../cs2-zl/index.html'),
};

/* 只比对「设计决策」类 token。--panel-w / --gutter / --topbar-h 这类
   页面各自的布局尺寸不参与比对。 */
const SHARED = /^--(fs|lh|fw|ls|ink|acc|u|ct|t|ok|warn|danger|sh|r|sp|e|blur|glass|scrim|bg|surface|line|text|mono|font)(-|$)/;

function tokensOf(path) {
  const src = readFileSync(path, 'utf8');
  const root = src.match(/:root\s*\{([\s\S]*?)\n\}/);
  if (!root) throw new Error(`${path}: 找不到 :root 块`);
  const body = root[1].replace(/\/\*[\s\S]*?\*\//g, '');
  const out = new Map();
  for (const [, name, value] of body.matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) {
    if (SHARED.test(name)) out.set(name, value.replace(/\s+/g, ' ').trim());
  }
  return out;
}

const all = Object.entries(FILES).map(([label, p]) => [label, tokensOf(p)]);
const [baseLabel, base] = all[0];
let bad = 0;

for (const [label, tk] of all.slice(1)) {
  const problems = [];
  for (const [k, v] of base) {
    if (!tk.has(k)) problems.push(`  缺少 ${k}`);
    else if (tk.get(k) !== v) problems.push(`  ${k}\n     ${baseLabel}: ${v}\n     ${label}: ${tk.get(k)}`);
  }
  for (const k of tk.keys()) if (!base.has(k)) problems.push(`  多出 ${k}: ${tk.get(k)}`);
  if (problems.length) {
    bad += problems.length;
    console.error(`✗ ${label} 与 ${baseLabel} 不一致（${problems.length} 处）:\n${problems.join('\n')}\n`);
  } else {
    console.log(`✓ ${label}`);
  }
}
console.log(bad ? `\n共 ${bad} 处漂移，改回一致后再部署。` : `\n全部一致，共比对 ${base.size} 个 token。`);
process.exit(bad ? 1 : 0);
