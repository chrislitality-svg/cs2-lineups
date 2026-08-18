#!/usr/bin/env bash
# 部署 /cs2/zs/ 的 index.html。
# 铁律：语法不过就绝不上传。上一次就是因为 `node --check` 失败了但后面的
# scp 是独立命令照跑，把解析不了的文件推上了生产。
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/index.html"
TMP="${TMPDIR:-/tmp}/deploy-$$"
mkdir -p "$TMP"
WIN_TMP=$(cygpath -w "$TMP" 2>/dev/null || echo "$TMP")

echo "1/5 抽出 module 段做语法检查"
node -e "
const fs=require('fs');
const h=fs.readFileSync(process.argv[1],'utf8');
const m=h.match(/<script type=\"module\">([\s\S]*?)<\/script>/);
if(!m){console.error('找不到 module 段');process.exit(1)}
fs.writeFileSync(process.argv[2],m[1]);
" "$SRC" "$WIN_TMP\mod.mjs"
node --check "$WIN_TMP\mod.mjs"
echo "    ✔ 语法通过"

echo "2/5 核对生产未被并发改动"
REMOTE_MD5=$(ssh ops "md5sum /opt/lechuang/web/cs2/zs/index.html | cut -d' ' -f1")
if [ -f "$DIR/.last-deployed-md5" ] && [ "$REMOTE_MD5" != "$(cat "$DIR/.last-deployed-md5")" ]; then
  echo "    ✘ 生产 md5 ($REMOTE_MD5) 与上次部署记录不符，可能有并发部署者。先 diff 再说。" >&2
  exit 1
fi
echo "    ✔ 生产 = 上次部署结果"

echo "3/5 备份生产"
TS=$(date +%Y%m%d-%H%M%S)
ssh ops "cp -a /opt/lechuang/web/cs2/zs/index.html /opt/lechuang/web/cs2/zs/index.html.bak-$TS"

echo "4/5 上传"
scp -q "$SRC" ops:/opt/lechuang/web/cs2/zs/

echo "5/5 线上复验"
curl -s -o "$WIN_TMP\live.html" -w '    HTTP %{http_code}  %{size_download} bytes\n' \
  "https://www.huyicun.cloud/cs2/zs/?cb=$RANDOM"
node -e "
const fs=require('fs');
const h=fs.readFileSync(process.argv[1],'utf8');
const m=h.match(/<script type=\"module\">([\s\S]*?)<\/script>/);
if(!m){console.error('线上抓不到 module 段');process.exit(1)}
fs.writeFileSync(process.argv[2],m[1]);
" "$WIN_TMP\live.html" "$WIN_TMP\live.mjs"
node --check "$WIN_TMP\live.mjs"
md5sum "$SRC" | cut -d' ' -f1 > "$DIR/.last-deployed-md5"
rm -rf "$TMP"
echo "    ✔ 线上 module 语法正常，部署完成（回滚点 index.html.bak-$TS）"
