# OpenClash v0.48.002 本地多来源节点方案（v2）

## 文件用途
- `base.yaml`：唯一主配置（上传至 `/etc/openclash/config/base.yaml`）
- `full_rules_only.conf`：统一规则覆写模块（上传至 `/etc/openclash/overwrite/` 并启用）
- `node_sources.conf`：节点提供者覆写模块（由脚本生成；上传至 `/etc/openclash/overwrite/` 并启用）
- `subscriptions.txt`：机场 URL 清单（`/etc/openclash/aggregator/`）
- `update.sh`：下载并检查订阅，生成 node_sources.conf（`/etc/openclash/aggregator/`）
- `manual_nodes.yaml`：真正加载的手动节点（`/etc/openclash/proxy_provider/`）
- `manual_nodes.examples.yaml`：8 类协议示例，仅供参考，不要直接启用
- `install_cron.sh`：安装每六小时一次的 cron 任务

## 安装（SSH）
1. 先备份 `/etc/openclash`，保留原主配置作为回退。安装 `curl ca-bundle`，并确保 `base64` 命令可用。
2. 创建目录：`mkdir -p /etc/openclash/{config,overwrite,proxy_provider,aggregator}`（若 ash 不支持花括号展开，请逐个 mkdir）。
3. 将文件按上面路径上传；不要把 `.conf` 文件作为主配置。
4. 编辑 `subscriptions.txt`：取消注释真实 URL。每行 `名称|URL|格式`；格式可为 `yaml`、`base64`、`uri`、`auto`。
5. 编辑 `manual_nodes.yaml`，用真实节点替换占位符。没有手动节点时可移除 `manual_nodes` 提供者条目，或先放一个真实节点。**不要让占位符节点参与运行。**
6. `chmod 700 /etc/openclash/aggregator/*.sh; chmod 600 /etc/openclash/aggregator/subscriptions.txt /etc/openclash/proxy_provider/manual_nodes.yaml`。
7. `/etc/openclash/aggregator/update.sh`。若返回错误，检查日志并排除不兼容订阅。
8. LuCI → OpenClash → 覆写模块：启用 `node_sources.conf`、`full_rules_only.conf`，禁用旧 full。选 `base.yaml` 为主配置。**模块文件是否识别/启用以 LuCI 实际界面为准。**
9. 启动后确认节点提供者和 `🚀 PROXY` 等策略组均出现，再运行 `install_cron.sh`。

## 格式限制与更新
- Mihomo file proxy-provider 可读取 **三种互斥格式**：顶层 `proxies:` 的 YAML、URI 列表、Base64 编码的 URI 列表。无需将 Base64 订阅转换为 YAML。
- `update.sh` 会下载并检查基本形态，不进行协议参数完整校验；完整 Clash YAML 只有在顶层 `proxies:` 能被 provider 解析时才可直接使用。
- 本方案统一**逻辑汇总**多个 provider，而非物理合并一个 YAML；`include-all: true` 策略组可使用所有 provider 的节点。
- 新增订阅后，重新执行 `update.sh`，再确认 LuCI 中覆写模块已重新应用；更新现有订阅通常只更新本地文件，但是否热重载由当前内核决定。必要时先验证再重启 OpenClash。
- 文件提供者 `path` 受 Mihomo HomeDir / SAFE_PATHS 限制，实际运行路径须通过启动日志确认；若 `./proxy_provider/...` 无法读取，应检查 OpenClash 核心工作目录。
- 只有基础格式校验，不能保证无效节点不被替换。生产环境建议使用内核 `-t` 对**最终运行配置**做完整测试后再切换。

## 测试命令
```sh
sh -n /etc/openclash/aggregator/update.sh
/etc/openclash/aggregator/update.sh
ls -lh /etc/openclash/proxy_provider/
sed -n '1,80p' /etc/openclash/overwrite/node_sources.conf
logread | grep -iE 'openclash|mihomo|provider|error' | tail -80
crontab -l
```

## 工具：YouTube 订阅用量观测器

`tools/ytwatch/` 下的脚本用于回答一个问题：**YouTube 流量在各订阅之间摊得均不均。**

它按连接链路里的 `📺 YT-N` 把下载字节归属到对应订阅，每 5 秒采样、每 5 分钟落一行，可长期运行后出均匀度报表（含基尼系数）。

```sh
# 若路由器 ruby 缺 json 库，先装 shim（见下一节）
tools/ruby-json/install.sh root@192.168.10.2

# 安装观测器
tools/ytwatch/install.sh root@192.168.10.2

# 看报表
ssh root@192.168.10.2 'ruby /etc/ytwatch/report.rb'

# 停止 / 卸载
ssh root@192.168.10.2 '/etc/init.d/ytwatch stop'
ssh root@192.168.10.2 '/etc/init.d/ytwatch disable; rm -rf /etc/ytwatch /etc/init.d/ytwatch'
```

**口径与局限**（读数前务必了解）：

- 只统计 `📺 YT-LB` 下归属到 `📺 YT-N` 的下载流量。其他策略组（`⚡ AUTO`/`🚀 PROXY`）的节点名在多个订阅间重名，无法归属到具体订阅。
- 只统计 download，不统计 upload。
- 5 秒采样间隔内开合的短连接会漏计；视频长连接不受影响。绝对值略低于真实值，**比例关系可信**。
- mihomo 的负载均衡按**连接**而非字节分流，单设备长期观看的分布会偏斜；多设备并行才能显著降低基尼系数。

路由器上的数据文件 `quota.csv` / `delta.csv` / `state.json` 是运行产物，不要提交。

## 工具：ruby json shim

OpenWrt 的 ruby 是精简构建，stdlib 只剩 `date/digest/pstore/psych/yaml`，**缺 `json` 与 `strscan`**，而官方 json gem 从 2.9 起已移除纯 Ruby 回退、只剩 C 扩展（无法在此编译）；最后一个还带 pure 实现的 2.7.2，其 parser 又 `require 'strscan'`。所以观测器改用自包含的纯 Ruby 实现。

`tools/ruby-json/json.rb` 就是这个实现，API 对齐官方 gem 的常用子集（`parse`/`generate`/`pretty_generate`/`load_file`/`dump`/`[]`/`to_json`/`symbolize_names`/`max_nesting`），不依赖任何 C 扩展，语法兼容 ruby 2.6 与 3.4。

```sh
tools/ruby-json/install.sh root@192.168.10.2
```

install.sh 会按运行时 `$LOAD_PATH` 探测 site_ruby 路径（**不写死 ruby 版本号**），安装后跑 51 项回归测试。卸载：`rm -f <site_ruby>/json.rb`。

**注意**：这是自研实现，非官方 gem。不支持 `json/add/*` 附加混入类、`create_additions`、`JSON::Coder`、quirks 模式。用于调试 mihomo 输出足够，别用在生产链路。

## 面板：策略组的「固定」与「解除固定」

这台路由器的面板是 **zashboard**（`/usr/share/openclash/ui/zashboard/`）。它和 metacubexd 的交互不同，**不要按 metacubexd 的文案去找按钮**。

### zashboard 里怎么解除固定

**点该策略组的「测速」按钮** —— 这就是解除固定的动作。对 Selector / LoadBalance / Smart 组，测速会先发一个 `DELETE /proxies/<组名>` 清除固定，再跑延迟测试。

依据（`assets/clash-CrgcscFv.js`，chunk 名随版本变化）：

```js
proxyGroupLatencyTest = async name => {
  const g = groups[name], all = g.all ?? [], url = ...;
  if (speedtestMode === DASHBOARD &&
      ["Selector","LoadBalance","Smart"].includes(g.type.toLowerCase()))
    return g.fixed && unfixProxy(name),   // 先解除固定
           runLatencyTest(name, all, url);
  ...
}
// unfixProxy = name => http.delete(`/proxies/${encodeURIComponent(name)}`)
```

**前提**：仅当「设置 → 测速方式」为 **面板控制（Dashboard）** 时才会先解除固定（这是默认值）。改成其它测速方式后，点测速不再解除固定。

### 视觉提示

被固定的组，在当前节点名**左侧**显示一个小图钉图标（判定条件是 `fixed === now`）。悬停它出现提示：

> 当前策略组被固定在了当前节点，点击测速来恢复{type}行为

**metacubexd 的对应物**是一个警示色小图标，tooltip 为 `Restore automatic selection`（中文「恢复自动选择」）。zashboard 没有这个名字的按钮 —— 找不到是正常的。

### 查看哪些组被固定 / 直接清除

```sh
ssh root@<router> '
S=$(sed -n "s/^secret:[[:space:]]*//p" /etc/openclash/base.yaml)
# 列出 fixed 非空的组
curl -s -H "Authorization: Bearer $S" http://127.0.0.1:9090/proxies \
  | python3 -c "import json,sys;d=json.load(sys.stdin)[\"proxies\"];\
[print(k,\"->\",v[\"fixed\"]) for k,v in d.items() if v.get(\"fixed\")]"
# 清除某一组的固定（把 NAME 换成组名，需 URL 编码）
curl -s -X DELETE -H "Authorization: Bearer $S" \
  "http://127.0.0.1:9090/proxies/$(python3 -c "import urllib.parse;print(urllib.parse.quote(\"NAME\"))")"'
```

### 两个易混点

- 组的 `now=⚡ AUTO` **不是**固定到某个节点，它本身就是自动模式，无需解除。
- `store-selected: true` 会把固定写进 `cache.db`（BoltDB 格式），**重启后仍在**，必须显式解除。

## 内网 DNS 覆盖：让域名在局域网内解析到内网 IP

**场景**：RustDesk 服务端在 `192.168.10.168`，但客户端 `ID Server` 必须填公网域名 `home.weixia.de5.net:21116`（填域名出门才可用）。在家时该域名解析到**公网 IP**，内网流量于是绕一圈 NAT 回环；RustDesk 还会去连 Pro 版的 `21114` API 端口（开源服务端没有），在 OpenClash 日志里刷满：

```
[TCP] dial DIRECT (match RuleSet/cncidr) 192.168.10.188:xxxxx --> home.weixia.de5.net:21114 error: dial tcp 180.109.183.x:21114: connect: connection refused
```

**目标**：让 `home.weixia.de5.net` 在**局域网内**解析到 `192.168.10.168`（在外仍走公网 DNS）。这样 21116 命中 `IPCIDR(192.168.0.0/16)` 直接走二层，21114 也不再产生出站连接。

### 机制：OpenClash 原生 custom_host

OpenClash 自带「自定义 Hosts」开关，把条目合进运行配置的 `hosts:` 段：

| 项 | 值 |
|---|---|
| UCI 开关 | `openclash.config.custom_host='1'` |
| 条目文件 | `/etc/openclash/custom/openclash_custom_hosts.list`（**YAML 映射**格式） |
| 消费方 | `/usr/share/openclash/yml_change.sh`：读该文件 → 合并进 `hosts:` → 自动设 `dns.use-hosts: true` |

条目写法（与文件里已有的 `'alpha.clash.dev': '::1'` 同格式）：

```yaml
'home.weixia.de5.net': 192.168.10.168
```

```sh
ssh root@<router> '
  F=/etc/openclash/custom/openclash_custom_hosts.list
  cp "$F" "$F.bak-$(date +%Y%m%d-%H%M%S)"
  printf "\047home.weixia.de5.net\047: 192.168.10.168\n" >> "$F"
  ruby -ryaml -e "p YAML.load_file(\"$F\")"      # 先确认能解析成 Hash，再往下走
  uci set openclash.config.custom_host=1 && uci commit openclash
  /etc/init.d/openclash restart
  grep -A2 "^hosts:" /etc/openclash/base.yaml    # 应含该条目
  grep "^  use-hosts" /etc/openclash/base.yaml   # 应为 true'
```

（按本章「操作纪律」：**追加后先 `ruby -ryaml` 解析确认合法**，最后才重启。）

### 关键第二步：dnsmasq 的 rebind protection 会吃掉内网应答

只做上面一步**不够**。LAN 客户端的 DNS 路径是 `客户端 → (OpenClash DNS Hijack，redirect to :53) → dnsmasq → clash:7874`。clash 明明返回了 `192.168.10.168`，但 **dnsmasq 的 `rebind_protection='1'` 会把「上游返回私有地址」当成 DNS rebinding 攻击而丢弃**（fake-ip `198.18.x` 不在拦截范围，所以此前一直没暴露）。必须把该域名加进白名单（对应 `--rebind-domain-ok=`）：

```sh
ssh root@<router> '
  uci add_list dhcp.@dnsmasq[0].rebind_domain="home.weixia.de5.net"
  uci commit dhcp
  /etc/init.d/dnsmasq restart'
```

### 验证：clash 直查 vs dnsmasq，缺一不可

只查一次会误判，必须**分别**确认 clash 与 dnsmasq 都返回内网 IP（BusyBox `nslookup` 不能指定端口，用 python 发查询）：

```sh
ssh root@<router> 'python3 - <<"PY"
import socket,struct
def q(name,port):
    h=struct.pack(">HHHHHH",0x1234,0x0100,1,0,0,0)
    qn=b"".join(bytes([len(p)])+p.encode() for p in name.split("."))+b"\x00"
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(3)
    s.sendto(h+qn+struct.pack(">HH",1,1),("127.0.0.1",port))
    d,_=s.recvfrom(2048); an=struct.unpack(">H",d[6:8])[0]; i=12
    while d[i]!=0: i+=d[i]+1
    i+=5; out=[]
    for _ in range(an):
        if d[i]&0xc0==0xc0: i+=2
        else:
            while d[i]!=0: i+=d[i]+1
            i+=1
        t=struct.unpack(">H",d[i:i+2])[0]; i+=8
        rl=struct.unpack(">H",d[i:i+2])[0]; i+=2; rd=d[i:i+rl]; i+=rl
        if t==1: out.append(socket.inet_ntoa(rd))
    return out
print("clash 7874 :", q("home.weixia.de5.net",7874))   # 期望 [192.168.10.168]
print("dnsmasq 53 :", q("home.weixia.de5.net",53))     # 期望 [192.168.10.168]；空=被 rebind 丢弃
PY'
```

排查信号：

| 现象 | 含义 |
|---|---|
| clash 有值、dnsmasq 空 | rebind protection 未加白名单（**最常见的坑**） |
| 两者都空 | `custom_host` 未开，或条目文件 YAML 写错（看日志 `Set Hosts Rules Failed`） |
| 两者都是 `198.18.x` | `hosts:` 条目没进运行配置 |

**客户端缓存**：域名有 TTL，改完后 RustDesk 可能仍持有旧的 fake-ip 连接一段时间，等其重连或重启客户端即可。判断修复是否生效，看日志里该域名的连接是否从 `match RuleSet(cncidr)` 变成 `match IPCIDR(192.168.0.0/16) using DIRECT`。

两处改动都在 `/etc` 下，换镜像升级后保留：`openclash_custom_hosts.list`、`/etc/config/openclash`（`custom_host`）、`/etc/config/dhcp`（`rebind_domain`）。

### 四个实测陷阱（2026-10-19 全量刷机重排时验证）

**1. mihomo 只认配置顶层的 `hosts:`（内核 alpha-smart-gdaf3ad0 实测）**。把条目嵌进 `dns.hosts:`（即使 `use-hosts: true`）后，clash 直查 7874 仍返回 fake-ip；合并到**顶层** `hosts:` 时返回真实 IP。`yml_change.sh` 原生就是合并到顶层的 —— **不要为了「更规范」把它挪进 dns 段**（试过，是负优化）。

**2. dnsmasq `address=` 本地直答（双保险，已保留）**。让 dnsmasq 对该域名直接返回内网 IP、完全不经 clash，clash 配置即使丢/坏也不影响在家使用：

```sh
ssh root@<router> '
  uci add_list dhcp.@dnsmasq[0].address="/home.weixia.de5.net/192.168.10.168"
  uci commit dhcp
  /etc/init.d/dnsmasq restart'
```

**3. 调测期切忌信 Mac 本机 `nslookup`**。Mac 常驻 TUN 代理工具（默认路由是 `utunN`、解析器 `198.18.0.2`），它返回的 fake-ip 是**本机工具**的，与路由器无关 —— 2026-10-19 整个排障日的 fake-ip 迷惑皆源于此，路由器侧机制当时一直是好的。定向验证必须显式指定服务器：

```sh
dig +short @192.168.10.2 home.weixia.de5.net          # dnsmasq 路径 → 期望 192.168.10.168
dig +short @192.168.10.2 -p 7874 home.weixia.de5.net  # clash 直查   → 期望 192.168.10.168
```

**4. Quick Start 会静默跳过重生成**。UCI 无变化时 restart 走 `Quick Start Mode, Skip Modify The Config File`，直接复用旧 base.yaml —— 刚改完覆写条目重启可能看到的还是旧文件。强制重生成：先改任意一个 UCI 值（如把 `log_size` 在 1024/2048 间改一下）再 restart，日志出现「Pause quick start」才算真跑了 Step 3。

## fake-ip 与「拒绝非公网地址」的客户端

`enhanced-mode: fake-ip` 会给域名返回 `198.18.0.0/15` 的假地址。这对浏览器/curl 透明，但**自带 SSRF 防护的客户端会把 `198.18.x` 判为「非公网」而直接拒绝**。实测 ollama 拉模型时：

```
Error: redirect target not allowed: dd20bb891979d25aebc8bec07b2b3bbc.r2.cloudflarestorage.com resolves to non-public 198.18.4.206
```

注意：这**与走哪个节点无关**（换 `🚀 PROXY`、换手工节点都一样报），因为报错发生在客户端解析阶段，连接还没建立。

**解法**：把这些域名加进 mihomo 的 `fake-ip-filter`（列进去的域名返回**真实 IP**）。OpenClash 的自定义入口：

| 项 | 值 |
|---|---|
| UCI 开关 | `openclash.config.custom_fakeip_filter='1'`（本机已开） |
| 模式 | `openclash.config.custom_fakeip_filter_mode='blacklist'` |
| 清单文件 | `/etc/openclash/custom/openclash_custom_fake_filter.list`（每行一个域名，`#` 注释） |
| 消费方 | `yml_change.sh:723` 合并进 `dns.fake-ip-filter` |

```sh
ssh root@<router> '
  F=/etc/openclash/custom/openclash_custom_fake_filter.list
  cp "$F" "$F.bak-$(date +%Y%m%d-%H%M%S)"
  printf "\n# ollama/R2\n+.r2.cloudflarestorage.com\n+.cloudflarestorage.com\n+.ollama.ai\n" >> "$F"
  /etc/init.d/openclash restart
  grep -nE "cloudflarestorage|ollama" /etc/openclash/base.yaml'   # 应出现在 fake-ip-filter 段
```

验证：查这些域名应返回**真实公网 IP**（非 `198.18.x`）：

```sh
ssh root@<router> 'nslookup registry.ollama.ai | tail -3'
```

客户端若已缓存过假地址，需等 TTL 或重启客户端/容器再重试。同类软件（任何做 SSRF/redirect 校验的 Go/Rust 程序，如 docker/podman 拉镜像、部分 CLI）遇到 `resolves to non-public` 都可照此处理。

**国内主流域名不用手动加**：`china_ip_route≠0` 时 `yml_change.sh:749` 会自动往 fake-ip-filter 追加 `rule-set:oc-cn-domain`（默认 `china_ip_route_domain_source='mrs'`；改成 `'geosite'` 才是 `geosite:cn`），cn 域名一律返回真 IP。所以需要手动维护的只有**境外域名里需要真 IP 的一小撮**（对象存储、内网自托管域名等）。

## 分流规则：让某个地址走代理或不走代理

规则**自上而下匹配、命中即止**。要改变某个地址的走向，就在会命中它的规则**之前**插一条。

### 两个入口

| 入口 | 位置 | 优先级 | 适合 |
|---|---|---|---|
| 仓库 `full_rules_only.conf` 的 `rules!:` | 按文件内先后；须在 `RULE-SET,proxy,...` 与末尾 `MATCH,...` 之前 | 高 | 长期、纳入版本管理（推荐） |
| `/etc/openclash/custom/openclash_custom_rules.list` | `yml_rules_change.sh` 插到规则**最顶**（`position: 'top'`） | 最高 | 临时试验 |
| `/etc/openclash/custom/openclash_custom_rules_2.list` | 插到**最底**（`position: 'bottom'`） | 最低 | 兜底追加 |

两个自定义清单由 `openclash.config.enable_custom_clash_rules='1'` 启用，内容里 `#` 为注释。

### 语法

```yaml
- "DOMAIN-SUFFIX,cloudflarestorage.com,DIRECT"   # 域名后缀
- "DOMAIN,example.com,DIRECT"                     # 精确域名
- "DOMAIN-KEYWORD,ollama,🚀 PROXY"                # 关键字
- "IP-CIDR,1.2.3.4/32,DIRECT,no-resolve"          # 单个 IP / 网段
- "GEOSITE,category-ads-all,REJECT"               # geosite 分类
- "RULE-SET,<规则集名>,DIRECT"                     # 整个规则集
```

第三段是出口：`DIRECT`（路由器本地直出）、`REJECT`、或任意策略组名（`🚀 PROXY` / `🤖 AI` / `🇭🇰 HK` …）。

### 例：让 ollama / Cloudflare R2 直连

在 `full_rules_only.conf` 的 `rules!:` 里、私有/LAN 段之后插入：

```yaml
  - "DOMAIN-SUFFIX,cloudflarestorage.com,DIRECT"
  - "DOMAIN-SUFFIX,ollama.ai,DIRECT"
```

路由器本机快速验证（插到最顶）：

```sh
ssh root@<router> '
  F=/etc/openclash/custom/openclash_custom_rules.list
  cp "$F" "$F.bak-$(date +%Y%m%d-%H%M%S)"
  printf -- "- \"DOMAIN-SUFFIX,example.com,DIRECT\"\n" >> "$F"
  /etc/init.d/openclash restart'
```

### 验证

```sh
# 1. 规则是否进了运行配置、且在做代理的规则之前
ssh root@<router> 'grep -n "cloudflarestorage" /etc/openclash/base.yaml'

# 2. 实际走的链：chains[0] 是出口，直连时为 DIRECT，代理时为节点名
S=$(ssh root@<router> 'sed -n "s/^secret:[[:space:]]*//p" /etc/openclash/base.yaml')
curl -s -H "Authorization: Bearer $S" http://<router>:9090/connections \
 | python3 -c 'import json,sys
for c in json.load(sys.stdin).get("connections",[]):
    m=c["metadata"]; h=m.get("host") or ""
    if "example.com" in h:
        print(h, "| rule:", c["rule"], "| chains:", " → ".join(c["chains"]))'
```

`chains` 从出口到外层：`chains[0]` = 实际出口（节点名或 `DIRECT`），`chains[-1]` = 进入的策略组。实测例：`DIRECT → 🍎 APPLE`、`[Self] Katabump-TUIC-TLS → 🚀 PROXY`。

### 前提：域名规则要能命中真实-IP 连接

- 本机 **sniffer 已开**（`sniffer.enable: true`、`override-destination: true`），mihomo 从 TLS SNI 还原域名，所以即使目标被 `fake-ip-filter` 解析成真实 IP，`DOMAIN-*` 规则照样命中。纯 IP、无 SNI 的连接只能靠 `IP-CIDR` 规则。
- fake-ip 模式下，被规则判定为直连的域名，客户端拿到的**仍是 `198.18.x`**（除非该域名同时在 `fake-ip-filter` 里）。所以对「拒绝非公网地址」的客户端（如 ollama，见上一节），要**同时**做两件事：域名进 `fake-ip-filter`（拿真实 IP）+ 加 `DIRECT` 规则。

## 升级（OpenWrt / OpenClash）

刷固件或升级 OpenClash 前**务必先读这一节**。这台设备上没有 `opkg`，ruby 与 OpenClash 都是**镜像内置**，所以升级等于换镜像，`/usr` 会被整个替换。

### 操作纪律：先验证产物，再重启服务

**这一条不只适用于升级，适用于任何修改配置的场景。** 违反它的代价是一次真实发生过的全站宕机。

错误的做法是把破坏性动作串起来一路做到底：

```
改脚本 → 上传 → 跑生成 → 重启服务         ← 中间零验证
```

正确的顺序是**把「重启」放在最后，且它之前必须有一个「产物合法」的明确信号**：

```
本地用假数据跑通生成逻辑并解析产物
  → 上传
  → 只跑生成，不要重启
  → 校验产物（YAML 可解析、结构符合预期、缩进一致）
  → 最后才重启服务
```

三个容易省略但关键的动作：

| 动作 | 为什么不能省 |
|---|---|
| 本地先跑生成 | 上传前发现语法/缩进问题，代价为零 |
| 生成后不马上重启 | 给「发现坏了但不生效」留出窗口 |
| 重启前校验产物 | 唯一的硬闸门；`update.sh` 已内置此关卡 |

**另外，动手前先确认 OpenClash 的启用状态**：

```sh
uci get openclash.config.enable      # 必须是 1
```

若为 `'0'`,OpenClash 处于禁用态，**不会重新生成配置**。此时即使你把坏文件修好，服务也不会自愈 —— 它会继续用上一份残缺配置拉起内核。这种情况下必须 `uci set openclash.config.enable='1' && uci commit openclash` 再 restart。

这条纪律的代价不对等：**验证一次的成本是几秒，跳过验证的代价是全部节点消失**，而且如果当时坏的是防火墙或 DNS，连修复入口都会失去。


### 会自动保留的

| 路径 | 依据 |
|---|---|
| `/etc/openclash/` | `/lib/upgrade/keep.d/luci-app-openclash` 明确保留 |
| `/etc/ytwatch/`、`/etc/init.d/ytwatch`、`/etc/rc.d/S99ytwatch` | 均在 `/etc` 下，`base-files` 保留 |
| `/etc/config/openclash`（`custom_host`）、`/etc/config/dhcp`（`rebind_domain`） | 均在 `/etc` 下，`base-files` 保留 |

配置、订阅清单、手动节点、覆写模块、采集器的全部历史数据都在保留范围内。

> **上表只对 sysupgrade（保留配置升级）成立。全新刷机（换镜像）连 `/etc` 一起丢** —— 2026-10-19 实测：`/etc/ytwatch` 历史数据从零、`/etc/config/{openclash,dhcp}`、custom 条目全部清零，只剩仓库源文件可重灌；且面板/API secret 回到出厂值，而 `quota_logger.rb` 是启动时一次性读 `base.yaml` 里的 secret —— **重装后必须重启 ytwatch**，否则一直 401（症状极误导：日志报「JSON 缺 connections 数组」的 shape 错误，实为鉴权失败）。

### 一定会丢的

`/usr/lib/ruby/site_ruby/<版本>/json.rb` —— 手工放入的 JSON shim，`/usr` 下没有任何 keep.d 条目。

不过 `tools/ruby-json/install.sh` 是**运行时探测 site_ruby 路径**的，不写死版本号，新版 ruby 无论是 3.5 / 3.6 都会自动落到对应目录。

### 升级前：备份

```sh
ssh root@<router> '
  tar czf /root/openclash-preupgrade-$(date +%Y%m%d).tar.gz \
    /etc/openclash/config /etc/openclash/overwrite \
    /etc/openclash/aggregator/subscriptions.txt \
    /etc/openclash/proxy_provider/manual_nodes.yaml /etc/ytwatch \
  && ls -lh /root/openclash-preupgrade-*.tar.gz'
```

### 升级后：按顺序重装

```sh
git pull
tools/ruby-json/install.sh root@<router>   # ① 补回 json shim
tools/ytwatch/install.sh  root@<router>    # ② 重装采集器
```

（**全新刷机**额外两步：`echo '+ /etc/ytwatch/' > /lib/upgrade/keep.d/ytwatch` 重建保留条目；覆写模块若用 UCI 脚本注册，`config` 选项必须是**列表** —— `uci add_list openclash.$sid.config="all"`，若写成字符串（`uci set`）会被 `config_list_foreach` 静默跳过，模块不生效且无任何报错。）

### 重装后的设置分工：UI 能做什么、哪些只能 SSH

OpenClash 的核心改造文件都在 `/etc` 下，部分设置没有 UI 入口。按这个顺序做（UI 操作认字根即可，中文标签随版本略有出入，不确定时用右侧 UCI 等价命令，结果一致）：

**① SSH 重灌文件（无 UI 入口，一次性）**

```sh
scp README同目录/{base.yaml,full_rules_only.conf,node_sources.conf} \
    root@<router>:/etc/openclash/   # 再分别移入 config/ overwrite/ overwrite/
scp update.sh subscriptions.txt  root@<router>:/etc/openclash/aggregator/ && chmod 600 subscriptions.txt
scp manual_nodes.yaml            root@<router>:/etc/openclash/proxy_provider/
git pull && tools/ruby-json/install.sh root@<router>   # json shim
tools/ytwatch/install.sh  root@<router>
echo '+ /etc/ytwatch/' > /lib/upgrade/keep.d/ytwatch   # 全新刷机时
```

**② UI 里要点的开关**

| 设置项 | LuCI 位置 | UCI 等价 |
|---|---|---|
| 选主配置 | OpenClash 主页 →「配置文件」下拉选 `base.yaml` | `config_path` |
| 启用覆写模块 | 全局设置 →「覆写设置」→ 勾选两个 conf | `uci add_list openclash.$sid.config="all"`（必须列表） |
| 自定义 Hosts | 全局设置 →「模式设置/自定义规则」→ 启用自定义 Host 条目 | `custom_host='1'` |
| fake-ip 过滤 | 同页「自定义 Fake-IP 过滤」+ 过滤模式 blacklist | `custom_fakeip_filter='1'`、`_mode='blacklist'` |
| GeoIP 自定义更新 | 全局设置 →「云端更新」 | `enable_geoip_dat='0'`（overlay 余量大时可不管） |
| rebind 白名单 | 网络 → DHCP/DNS → 高级设置 → 重绑白名单 加 `home.weixia.de5.net` | `uci add_list dhcp.@dnsmasq[0].rebind_domain=…` |
| 计划任务 | 系统 → 计划任务末尾加行 | 见下 |

计划任务内容：

```
0 */6 * * * /etc/openclash/aggregator/update.sh >> /etc/openclash/aggregator/update.log 2>&1
```

**③ 只有 UCI/SSH 能做的**

```sh
# dnsmasq 本地直答（双保险，UI 没有该字段）
ssh root@<router> 'uci add_list dhcp.@dnsmasq[0].address="/home.weixia.de5.net/192.168.10.168"
  uci commit dhcp && /etc/init.d/dnsmasq restart'
```

custom 条目文件（`openclash_custom_hosts.list` / `openclash_custom_fake_filter.list`）可在 UI「配置文件」页直接编辑，也可照本章前文的 scp/printf 流程。

**④ 启动与验证**：主页一键启动 → 日志见两行 `Processing Overwrite Module` 且无 `Quick Start Mode, Skip Modify...`（若有，随改一个 UCI 值再重启强制全量重生成）→ DNS 双路径 `dig +short @192.168.10.2 home.weixia.de5.net` 与 `dig +short @192.168.10.2 -p 7874 home.weixia.de5.net` 都应返回 `192.168.10.168`（顺带见「内网 DNS 覆盖」章的排查表）→ 再跑下面的逐项验证。

### 升级后：逐项验证

**不能只看"进程起来了"** —— 下面这些故障都不会让服务挂掉，只会让规则静默失效或数据静默变空。

```sh
# 1. 覆写模块是否真的生效
ssh root@<router> 'grep -c "YT-LB" /etc/openclash/base.yaml'      # 应 >5
ssh root@<router> 'grep -c "RULE-SET" /etc/openclash/base.yaml'   # 应 ≈12

# 2. 规则集是否全部加载（9 个）
S=$(ssh root@<router> 'sed -n "s/^secret:[[:space:]]*//p" /etc/openclash/base.yaml')
ssh root@<router> "curl -s -H \"Authorization: Bearer $S\" \
  http://127.0.0.1:9090/rules | grep -o '\"type\":\"RuleSet\"' | wc -l"   # 应 =9

# 3. provider 数量是否正常（12 个：10 订阅 + manual_nodes + default）
ssh root@<router> "curl -s -H \"Authorization: Bearer $S\" \
  http://127.0.0.1:9090/providers/proxies \
  | grep -oE '\"name\":\"[a-zA-Z0-9_]+\",\"type\":\"Proxy\"' | wc -l"

# 4. 采集器是否真的在记数（最能骗你的一项）
ssh root@<router> 'ruby /etc/ytwatch/report.rb'   # 看「总下载」是否在涨
```

### 踩过的坑：heredoc 缩进 / 字符前缀类错误

此类错误的共同点是**看文件看不出来，只有把不可见字符显式化才能发现**，且后果是整份 YAML 报废、覆写模块静默不生效。以下两次都是实测发生过的。

#### 实例 1：heredoc 里 `$name` 缩进写错一级（造成过真实宕机）

`update.sh` 的循环 heredoc 中，provider 顶层键原本是 **2 空格**：

```sh
  $name:                      # 2 空格，与 header 的 manual_nodes 同级
    type: file
```

误改成 **3 空格**后，`airport_*` 比 `manual_nodes` 深一级，YAML 直接解析失败：

```
Psych::SyntaxError: did not find expected key while parsing a block mapping at line 2 column 3
```

连锁后果：`node_sources.conf` 应用失败 → 生成配置丢失 `proxy-providers` → 全部节点消失。

**当时为什么没自愈**：`openclash.config.enable` 恰好是 `'0'`。禁用状态下 init 脚本不会重新生成配置，只会用上一份残缺的 `base.yaml` 拉起内核 —— 所以事后把 `update.sh` 修好也无效，必须 `uci set openclash.config.enable='1'` 再 restart。

**根因之一是误读工具输出**：`Read` 工具的行号前缀是 `<行号>: `（4 字符），其后的 `  $name:` 实际只有 2 空格。把前缀当内容读就会多数一格。

**现形命令**（把空格变成 `·`，一眼看出层级）：

```sh
sed 's/ /·/g' update.sh | grep -n 'name:'        # heredoc 内
sed 's/ /·/g' /etc/openclash/overwrite/node_sources.conf | grep '^·*[a-z]'
```

**防线**：`update.sh` 现在有安装前校验关卡（见 `tools/update-gate-test.sh`），provider 顶层键若不是 2 空格直接退出码 1 并保留原模块。

#### 实例 2：跨行字符串拼接被当成语法错误

```ruby
warn alert("第一段。"
           "第二段。")      # ← ruby 2.6 报 syntax error
```

**`f("a"\n"b")` 这种跨行相邻字符串在方法参数位不合法**，必须显式 `+`。写成 `+` 后 2.6 与 3.4 都通过。

#### 共性防范

| 错误类型 | 为什么危险 | 怎么现形 |
|---|---|---|
| 缩进差一级 | YAML 语义完全改变，肉眼不可见 | `sed 's/ /·/g'` |
| Tab 当缩进 | YAML 直接拒绝；曾导致整份配置解析失败 | `grep -nP '\t'`（OpenWrt BusyBox 用 `grep -n "$(printf '\t')"`） |
| 字符串跨行拼接 | 语法错误，但只在特定 ruby 版本暴露 | 统一用 `+`，两端版本都跑测试 |
| 工具行号前缀 | 把 `  内容` 读成 `    内容` | 用 `sed 's/ /·/g'` 而非直接读 |

**通用纪律**：详见本章开头的「操作纪律：先验证产物，再重启服务」—— 改动任何「生成配置」的脚本后，先在本地用假数据跑一遍生成逻辑并解析产物，再上传；上传后先跑生成、**校验产物**，最后才重启服务。重启必须放在最后一步。

### 踩过的坑：BusyBox 工具假设类错误

这类错误的共同点是**「这个命令我以为有，其实没有」，且失败不报错、只是静默返回空**，最容易导致误判（本轮实测）。

| 我用了 | 实际（BusyBox） | 后果 | 改用 |
|---|---|---|---|
| `echo > /dev/tcp/host/port` | `ash` **无 `/dev/tcp`**，直接 shell 报错 | 端口探测结果全部为假 | `python3` socket |
| `nslookup <域名> <server> -port=N` | `nslookup` 不支持指定端口 | 查不到 clash 的 7874，误以为 clash 没响应 | 用 `python3` 发 DNS 查询 |
| `grep -P '\t'` | 无 `-P` | 匹配为空，误判「没有 Tab」 | `grep "$(printf '\t')"` 或 `sed` |

**自检习惯**：任何探测/查询类命令，先拿一个**已知必然成立**的目标试一次（如 `nslookup localhost` 应返回、`python3` 连 `127.0.0.1:9090` 应通）。自检失败说明**命令本身不可用**，而不是「对象不存在」。



| 依赖 | 现在的工作方式 | 升级后风险 |
|---|---|---|
| `base.yaml` 的 `secret:` 行 | 采集器与诊断脚本按 `start_with?('secret:')` 读取 | 格式若变 → 读到空 → 持续 401 → **告警会触发**（见下） |
| `/providers/proxies`、`/connections` | mihomo REST API | 端点若变 → JSON 缺 `connections` → **告警会触发** |
| 连接链 `[节点, 📺 YT-N, 📺 YT-LB]` | 采集器靠 `chains[1]` 归属订阅 | 链结构若变 → 归属失效，**静默**（无告警，需人工比对 `chains`） |
| 覆写模块语法 `[YAML]` / `proxy-groups!:` | OpenClash 覆写机制 | 不兼容则模块不生效但进程照常起，**静默** |
| `./rule_provider/` 路径 | OpenClash 把 `./ruleset/` 规范化成它 | 若改名 → 9 个规则集加载失败，**静默** |

### 加固：把采集数据加进升级保留清单

`/lib/upgrade/keep.d/ytwatch` 内容为 `/etc/ytwatch/`，让「保留配置」式升级连采集器的历史数据一起保留。

```sh
ssh root@<router> 'echo "/etc/ytwatch/" > /lib/upgrade/keep.d/ytwatch'
```

**局限**：`/lib/upgrade/keep.d/` 本身位于镜像内，**整包刷机后会被重置**，此条目即失效。它对「保留配置升级」（sysupgrade -k 或 LuCI 勾选保留配置）有效，对不留配置的刷机无效。后者依赖 `/etc` 默认保留，通常也够，但显式条目更稳。



### 采集器失效告警

`quota_logger.rb` 会区分三种静默失效并告警，写在 `/etc/ytwatch/run.log`：

| 状态 | 含义 |
|---|---|
| `empty` | curl 无返回：OpenClash 未运行、端口不通、或 secret 失效 |
| `parse` | 返回不是合法 JSON（如被替换成 HTML 错误页） |
| `shape` | JSON 能解析但缺 `connections` 数组：mihomo 升级改了 API |

行为：连续失败 **6 次（约 30 秒）**才告警一次，避免重启抖动刷屏；恢复时记一条「API 已恢复正常（此前数据有缺失）」。首次失败另记一条明细便于定位。

```sh
ssh root@<router> 'tail -20 /etc/ytwatch/run.log'
```

测试：`ruby tools/ytwatch/quota_logger_test.rb`（20 项，含三种失效模式的告警行为）。


订阅 URL 往往包含密钥。不要公开 `subscriptions.txt` 或带凭据的日志；保持文件权限 600。
手动节点样例是文档，不是可连通节点。控制接口不要暴露 WAN。
`manual_nodes.yaml` 与 `subscriptions.txt` 已列入 `.gitignore`，禁止提交。

