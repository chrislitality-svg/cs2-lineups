#!/usr/bin/env bash
# 部署 /cs2/ 三个页面。用法：
#   ./deploy.sh            全部（只传有改动的）
#   ./deploy.sh zs         只传战术沙盘
#   ./deploy.sh portal zl  传门户页和租赁页
#
# 铁律：检查不过就绝不上传。
# 2026-08-18 真出过事：`node --check` 失败了，但后面的 scp 是独立命令照跑，
# 把解析不了的 module 推上生产，线上 HTTP 200 但整个应用挂掉。
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WT=$(cygpath -w "$TMP" 2>/dev/null || echo "$TMP")
BASE=https://www.huyicun.cloud
TS=$(date +%Y%m%d-%H%M%S)

# 用数组 + for 遍历，不用 `cmd | while`：
#   ① 管道会开子 shell，里面的 exit 1 中止不了主脚本，检查形同虚设
#   ② 循环体里的 ssh 会把管道的 stdin 一口吃光，后面的目标被静默跳过
# 所以 ssh 一律加 -n，断掉它读 stdin 的念头。
TARGETS=(
  "zs|$DIR/index.html|/opt/lechuang/web/cs2/zs/index.html|$BASE/cs2/zs/"
  "portal|$DIR/portal/index.html|/opt/lechuang/web/cs2/index.html|$BASE/cs2/"
  "zl|$DIR/zl/index.html|/opt/lechuang/web/cs2/zl/index.html|$BASE/cs2/zl/"
)
WANT="${*:-zs portal zl}"
want() { case " $WANT " in *" $1 "*) return 0;; *) return 1;; esac; }

# zs 是 ESM module，另外两个是普通 script，两种都要验
check_syntax() {   # $1=标签 $2=html $3=输出前缀(Windows 路径)
  node -e '
const fs=require("fs"),[name,src,out]=process.argv.slice(1);
const h=fs.readFileSync(src,"utf8");
const mods =[...h.matchAll(/<script type="module">([\s\S]*?)<\/script>/g)].map(m=>m[1]);
const plain=[...h.matchAll(/<script(?![^>]*\bsrc=)(?![^>]*type=)[^>]*>([\s\S]*?)<\/script>/g)].map(m=>m[1]);
if(!mods.length && !plain.length){console.error(name+": 一个 script 段都没抓到");process.exit(1)}
mods .forEach((c,i)=>fs.writeFileSync(out+".mod"+i+".mjs",c));
plain.forEach((c,i)=>fs.writeFileSync(out+".plain"+i+".js",c));
console.log("    "+name+": module "+mods.length+" 段 / 普通 "+plain.length+" 段");
' "$1" "$2" "$3"
  shopt -s nullglob
  for f in "$3".mod*.mjs "$3".plain*.js; do node --check "$f"; done
  shopt -u nullglob
}

echo "== 1/6 token 一致性 =="
node "$DIR/_design/check-tokens.mjs" >/dev/null
echo "    ✔ 四份 :root 逐字一致"

echo "== 2/6 本地语法 =="
for t in "${TARGETS[@]}"; do IFS='|' read -r name src remote url <<< "$t"
  want "$name" && check_syntax "$name" "$src" "$WT\$name"
done

echo "== 3/6 核对生产未被并发改动 =="
for t in "${TARGETS[@]}"; do IFS='|' read -r name src remote url <<< "$t"
  want "$name" || continue
  rmd5=$(ssh -n ops "md5sum $remote | cut -d' ' -f1")
  rec="$DIR/.last-deployed-$name.md5"
  if [ -f "$rec" ] && [ "$rmd5" != "$(cat "$rec")" ]; then
    echo "    ✘ $name 生产 md5 与上次部署记录不符，可能有并发部署者，先 diff" >&2
    exit 1
  fi
  echo "    ✔ $name"
done

echo "== 4/6 备份 + 上传 =="
for t in "${TARGETS[@]}"; do IFS='|' read -r name src remote url <<< "$t"
  want "$name" || continue
  lmd5=$(md5sum "$src" | cut -d' ' -f1)
  rmd5=$(ssh -n ops "md5sum $remote | cut -d' ' -f1")
  if [ "$lmd5" = "$rmd5" ]; then echo "    - $name 无改动，跳过"; continue; fi
  ssh -n ops "cp -a $remote ${remote%.html}.html.bak-$TS"
  scp -q "$src" "ops:$remote"
  echo "    ✔ $name 已上传（回滚点 .bak-$TS）"
done

echo "== 5/6 线上复验 =="
for t in "${TARGETS[@]}"; do IFS='|' read -r name src remote url <<< "$t"
  want "$name" || continue
  code=$(curl -s -o "$TMP/live-$name.html" -w '%{http_code}' "$url?cb=$RANDOM")
  [ "$code" = "200" ] || { echo "    ✘ $name HTTP $code" >&2; exit 1; }
  check_syntax "$name(线上)" "$TMP/live-$name.html" "$WT\live-$name" >/dev/null
  echo "    ✔ $name HTTP 200 且语法正常"
done

echo "== 6/6 记录 md5 =="
for t in "${TARGETS[@]}"; do IFS='|' read -r name src remote url <<< "$t"
  want "$name" || continue
  md5sum "$src" | cut -d' ' -f1 > "$DIR/.last-deployed-$name.md5"
done
echo "    ✔ 完成"
