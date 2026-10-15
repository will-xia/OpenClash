#!/bin/sh
# 在确认首次手动更新成功后运行。重复运行不会重复添加。
set -eu
ENTRY='0 */6 * * * /etc/openclash/aggregator/update.sh >> /etc/openclash/aggregator/update.log 2>&1'
(crontab -l 2>/dev/null | grep -Fv '/etc/openclash/aggregator/update.sh' || true; echo "$ENTRY") | crontab -
/etc/init.d/cron restart
echo "$ENTRY"
