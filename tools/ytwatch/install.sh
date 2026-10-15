#!/bin/sh
# 安装 YouTube 订阅用量观测器到 OpenWrt 路由器。
# 用法: ./install.sh <router-ssh-target>
#   例: ./install.sh root@192.168.10.2
# 依赖: 路由器已运行 OpenClash(mihomo 内核)，且已装 ruby + json 库。
set -eu
[ $# -eq 1 ] || { echo "用法: $0 <router-ssh-target>"; exit 1; }
T="$1"
D=/etc/ytwatch
HERE=$(cd "$(dirname "$0")" && pwd)

echo "==> 目标: $T   安装到: $D"
echo "==> 依赖检查: ruby + json 库"
if ! ssh "$T" 'command -v ruby >/dev/null 2>&1'; then
  echo "!! 路由器未安装 ruby，无法运行采集器"
  exit 1
fi
if ! ssh "$T" 'ruby -rjson -e "exit 0" 2>/dev/null'; then
  echo "!! ruby 缺少 json 库。OpenWrt 的精简 ruby 需先装 shim："
  echo "   $(dirname "$HERE")/ruby-json/install.sh $T"
  exit 1
fi
ssh "$T" "mkdir -p $D"
for f in quota_logger.rb report.rb quota_logger_test.rb; do
  scp -q "$HERE/$f" "$T:$D/$f"
done
scp -q "$HERE/ytwatch" "$T:/etc/init.d/ytwatch"
ssh "$T" "chmod +x $D/quota_logger.rb /etc/init.d/ytwatch"
echo "==> 已安装:"
ssh "$T" "ls $D"

echo "==> 运行测试"
ssh "$T" "ruby $D/quota_logger_test.rb" | tail -3

echo "==> 启用开机自启并启动"
ssh "$T" "/etc/init.d/ytwatch enable"
ssh "$T" "/etc/init.d/ytwatch start"

echo
echo "完成。日常用法:"
echo "  看报表      ssh $T 'ruby $D/report.rb'"
echo "  停止采集    ssh $T '/etc/init.d/ytwatch stop'"
echo "  卸载        ssh $T '/etc/init.d/ytwatch disable; rm -rf $D /etc/init.d/ytwatch'"
echo
echo "数据文件(在路由器上, 不要提交): $D/quota.csv $D/delta.csv $D/state.json"
