#!/bin/sh
# update.sh 安装前校验关卡的回向测试
# 用「故意写错的缩进」喂给同一套检查逻辑，确认它真的会拦截、
# 且保留旧模块、以非零退出。正常用例也要通过，防止关卡误报。
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
chk() {
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1  got=[$2] want=[$3]"; fail=$((fail+1)); fi
}

# 从 update.sh 抽出校验逻辑，避免重复实现
extract() {
  sed -n '/^if grep -qE .\^   \[A-Za-z0-9_-\]/,/^fi$/p' "$HERE/update.sh" > "$WORK/gate.sh"
  sed -n '/^for k in "type: file"/,/^done$/p'    "$HERE/update.sh" >> "$WORK/gate.sh"
  # 把真实退出改成可观测的返回
  sed -i 's/^  exit 1$/  return 1/' "$WORK/gate.sh"
}

gate() {
  # $1=候选文件 $2=provider 数
  rm -rf "$WORK/g"; mkdir -p "$WORK/g"
  ( TMPMODULE="$1"; count="$2"; MODULE="$WORK/g/node_sources.conf"; . "$WORK/gate.sh" ) >/dev/null 2>&1
  echo $?
}

extract
echo "=== 用例 1：缩进错误(3 空格) 必须被拦截 ==="
cat > "$WORK/bad.yaml" <<'Y'
[YAML]
proxy-providers:
  manual_nodes:
    type: file
    path: ./proxy_provider/manual_nodes.yaml
    health-check:
      enable: true
      expected-status: 204
   airport_1:
     type: file
     expected-status: 204
Y
chk "关卡返回非零" "$(gate "$WORK/bad.yaml" 1)" "1"

echo "=== 用例 2：缩进正确必须放行 ==="
cat > "$WORK/good.yaml" <<'Y'
[YAML]
proxy-providers:
  manual_nodes:
    type: file
    path: ./proxy_provider/manual_nodes.yaml
    health-check:
      enable: true
      expected-status: 204
  airport_1:
    type: file
    path: ./proxy_provider/airport_1.yaml
    health-check:
      enable: true
      expected-status: 204
Y
chk "关卡返回零" "$(gate "$WORK/good.yaml" 1)" "0"

echo "=== 用例 3：字段缺失(漏 expected-status) 必须被拦截 ==="
sed '/expected-status: 204/d' "$WORK/good.yaml" > "$WORK/missing.yaml"
chk "关卡返回非零" "$(gate "$WORK/missing.yaml" 1)" "1"

echo "=== 用例 4：空 provider 列表(count=0) 不误报 ==="
cat > "$WORK/onlyheader.yaml" <<'Y'
[YAML]
proxy-providers:
  manual_nodes:
    type: file
    path: ./proxy_provider/manual_nodes.yaml
    health-check:
      enable: true
      expected-status: 204
Y
chk "关卡返回零" "$(gate "$WORK/onlyheader.yaml" 0)" "0"

echo "=== 用例 5：真 update.sh 语法仍合法 ==="
sh -n "$HERE/update.sh" 2>/dev/null; chk "语法 OK" "$?" "0"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS ($pass)"; exit 0; else echo "$fail FAILED"; exit 1; fi
