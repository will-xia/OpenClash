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

## 安全
订阅 URL 往往包含密钥。不要公开 `subscriptions.txt` 或带凭据的日志；保持文件权限 600。
手动节点样例是文档，不是可连通节点。控制接口不要暴露 WAN。
