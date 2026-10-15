#!/bin/sh
# OpenClash local provider aggregation diagnostics. Read-only.
set -u
OC=/etc/openclash
CONF=$OC/base.yaml
AGG=$OC/aggregator
PD=$OC/proxy_provider
OK=0; WARN=0
section(){ printf '\n========== %s ==========\n' "$1"; }
pass(){ printf '[OK] %s\n' "$1"; OK=$((OK+1)); }
warn(){ printf '[WARN] %s\n' "$1"; WARN=$((WARN+1)); }
info(){ printf '[INFO] %s\n' "$1"; }
section 'Environment'
date
uname -a 2>/dev/null | cut -c1-180
[ -r /etc/openwrt_release ] && grep -E 'DISTRIB_(ID|RELEASE|ARCH)=' /etc/openwrt_release
if [ -x /etc/init.d/openclash ]; then
  st=$(/etc/init.d/openclash status 2>&1)
  case "$st" in *running*) pass "OpenClash service: running";; *) warn "OpenClash service: $st";; esac
else warn 'OpenClash init script missing'; fi
ps w 2>/dev/null | grep -E '[/]etc/openclash/clash|[/]mihomo' | sed -E 's/(-f )[[:graph:]]+/\1[config]/g' | head -5 || true
section 'Active configuration'
if [ -r "$CONF" ]; then
  pass "$CONF exists"
  ls -lh "$CONF"
  grep -E '^[[:space:]]*(proxy-providers:|proxy-groups:|rules:)' "$CONF" | sort -u
  for p in manual_nodes airport_a; do
    if grep -Eq "^[[:space:]]{2}$p:" "$CONF"; then pass "Provider declared: $p"; else warn "Provider not declared: $p"; fi
  done
  if grep -q 'include-all: true' "$CONF"; then pass 'include-all found'; else warn 'include-all not found'; fi
  for name in '⚡ AUTO' '🌍 GLOBAL' '🤖 AI' '💻 DEV'; do
    if grep -Fq "$name" "$CONF"; then pass "Group/rule name found: $name"; else warn "Name not found: $name"; fi
  done
else warn "$CONF not readable"; fi
section 'Provider files'
for f in "$PD"/*.yaml; do
  [ -f "$f" ] || continue
  name=${f##*/}
  size=$(wc -c < "$f" | tr -d ' ')
  info "$name: ${size} bytes"
  if [ "$size" -gt 0 ]; then pass "$name nonempty"; else warn "$name empty"; fi
  case "$name" in
    manual_nodes.yaml|airport_*.yaml)
      if grep -Eq '^[[:space:]]*proxies:' "$f"; then info "$name: YAML proxies key found"
      else info "$name: no YAML proxies key (may be Base64/URI provider)"; fi;;
  esac
done
section 'Aggregator and cron'
for f in "$AGG/update.sh" "$AGG/subscriptions.txt" "$AGG/install_cron.sh"; do
  if [ -f "$f" ]; then pass "Found ${f##*/}"; else warn "Missing ${f##*/}"; fi
done
if [ -f "$AGG/update.sh" ]; then
  if sh -n "$AGG/update.sh" 2>/dev/null; then pass 'update.sh shell syntax'; else warn 'update.sh shell syntax error'; fi
fi
if command -v crontab >/dev/null 2>&1; then
  if crontab -l 2>/dev/null | grep -Fq '/etc/openclash/aggregator/update.sh'; then pass 'Cron entry found'; else warn 'Cron entry not found'; fi
else warn 'crontab command not found'; fi
if [ -f "$AGG/update.log" ]; then
  info 'Recent update log (URLs/tokens suppressed):'
  tail -12 "$AGG/update.log"
else info 'No update.log yet'; fi
section 'Mihomo API'
# Extract controller and secret from flat YAML lines without printing the secret.
controller=$(sed -n 's/^[[:space:]]*external-controller:[[:space:]]*//p' "$CONF" 2>/dev/null | head -1 | tr -d '\r"')
secret=$(sed -n 's/^[[:space:]]*secret:[[:space:]]*//p' "$CONF" 2>/dev/null | head -1 | tr -d '\r"')
port=$(printf '%s' "$controller" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')
[ -n "$port" ] || port=9090
if command -v curl >/dev/null 2>&1; then
  if [ -n "$secret" ]; then
    response=$(curl -fsS --connect-timeout 2 --max-time 5 -H "Authorization: Bearer $secret" "http://127.0.0.1:$port/providers/proxies" 2>/dev/null) || response=''
  else
    response=$(curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$port/providers/proxies" 2>/dev/null) || response=''
  fi
  if [ -n "$response" ]; then
    pass "Providers API reachable on localhost:$port"
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "$response" | jq -r 'to_entries[] | "[PROVIDER] \(.key): \(.value.proxies | length) nodes"' 2>/dev/null || warn 'Provider API JSON parse failed'
    else
      info 'Install jq for per-provider counts (opkg install jq / apk add jq)'
      for p in manual_nodes airport_a; do
        case "$response" in *\"$p\"*) pass "API mentions $p";; *) warn "API does not mention $p";; esac
      done
    fi
  else warn "Providers API inaccessible at localhost:$port (controller may use another port/secret)"; fi
  if [ -n "$secret" ]; then
    groups=$(curl -fsS --connect-timeout 2 --max-time 5 -H "Authorization: Bearer $secret" "http://127.0.0.1:$port/proxies" 2>/dev/null) || groups=''
  else
    groups=$(curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$port/proxies" 2>/dev/null) || groups=''
  fi
  if [ -n "$groups" ]; then
    pass 'Proxies API reachable'
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "$groups" | jq -r '.proxies | to_entries[] | select(.value.type == "Selector" or .value.type == "URLTest") | "[GROUP] \(.key): \(.value.all | length) members"' 2>/dev/null | head -35
    fi
  else warn 'Proxies API inaccessible'; fi
else warn 'curl not installed'; fi
section 'Recent relevant log messages'
for f in /tmp/openclash_start.log /tmp/openclash.log; do
  if [ -r "$f" ]; then
    info "$f (recent error/provider lines, credentials not shown)"
    grep -iE 'level=(error|warning)|\[Provider\]|parse error|configuration error' "$f" | tail -12
  fi
done
section 'Summary'
printf 'Checks passed: %s | Warnings: %s\n' "$OK" "$WARN"
printf 'Read-only diagnostics complete. Review output for any sensitive hostnames before sharing.\n'
