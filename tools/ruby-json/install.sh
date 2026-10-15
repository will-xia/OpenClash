#!/bin/sh
# 把自包含的纯 Ruby JSON 实现装到路由器的 site_ruby 下。
#
# 为什么需要它：OpenWrt 上的 ruby 是精简构建，stdjson 只剩
# date/digest/pstore/psych/yaml，缺 json 与 strscan，而官方 json gem
# (>=2.9) 已移除纯 Ruby 回退、只剩 C 扩展；最后一个还有 pure 的 2.7.2
# 其 parser 又 require 'strscan'。所以只能装自包含实现。
#
# 目标路径按运行时的 $LOAD_PATH 探测，不写死 ruby 版本号。
# 用法: ./install.sh <router-ssh-target>
#   例: ./install.sh root@192.168.10.2
set -eu
[ $# -eq 1 ] || { echo "用法: $0 <router-ssh-target>"; exit 1; }
T="$1"
HERE=$(cd "$(dirname "$0")" && pwd)

echo "==> 目标: $T"
echo "==> 探测 site_ruby 路径"
DIR=$(ssh "$T" 'ruby -e "puts \$LOAD_PATH.grep(/site_ruby/).first"' 2>/dev/null || true)
if [ -z "$DIR" ]; then
  echo "!! 未能探测到 site_ruby，路由器上 ruby 是否已安装？"
  exit 1
fi
echo "    site_ruby = $DIR"

echo "==> 安装 json.rb"
ssh "$T" "mkdir -p '$DIR'"
scp -q "$HERE/json.rb" "$T:$DIR/json.rb"
ssh "$T" "chmod 644 '$DIR/json.rb'; ls -la '$DIR/json.rb'"

echo "==> 运行回归测试"
scp -q "$HERE/test.rb" "$T:/tmp/json_shim_test.rb"
ssh "$T" 'ruby /tmp/json_shim_test.rb 2>&1 | tail -4; rm -f /tmp/json_shim_test.rb'

echo
echo "完成。验证: ssh $T 'ruby -rjson -e \"puts JSON::VERSION\"'"
echo "卸载:   ssh $T 'rm -f $DIR/json.rb'"
