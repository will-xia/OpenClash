# frozen_string_literal: false
# 按订阅累计 YouTube 下载流量，用于长期观察配额是否被均匀摊薄。
# 数据来源：mihomo /connections，按链路 [节点, 📺 YT-N, 📺 YT-LB] 归属到订阅。
# 每 5 秒采样一次；每 300 秒追加一行累计 CSV。
#
# 口径说明：
#  * 只统计 download(下载)。视频以下载为主，上传可忽略。
#  * 首次见到某连接时，把它已传输的字节一并计入（该连接已消耗的配额是真实发生的），
#    之后按增量累加。连接级高水位持久化在 state.json，重启不会重复计数。
#  * 采样间隔内开合的连接其字节仍可能漏计（视频长连接不受影响）。
require 'json'

DIR   = '/etc/ytwatch'
CSV   = "#{DIR}/quota.csv"
DELTA = "#{DIR}/delta.csv"
STATE = "#{DIR}/state.json"
PIDF  = "#{DIR}/quota.pid"
CFG   = '/etc/openclash/base.yaml'

SAMPLE = 5     # 秒
FLUSH  = 300   # 秒
LB     = "\u{1F4FA} YT-LB"
LBPFX  = "\u{1F4FA} YT-"
GROUPS = (1..10).map { |i| "#{LBPFX}#{i}" }

Dir.mkdir(DIR) unless Dir.exist?(DIR)

# ---- 单实例保护 ----
if File.exist?(PIDF)
  old = File.read(PIDF).strip
  begin
    cmd = File.read("/proc/#{old}/cmdline", 500).to_s
    if old =~ /\A\d+\z/ && !cmd.empty? && cmd.include?('quota_logger')
      warn "already running (pid #{old})"
      exit 0
    end
  rescue StandardError
    nil
  end
end
File.write(PIDF, Process.pid.to_s)
at_exit { File.delete(PIDF) if File.exist?(PIDF) && File.read(PIDF) == Process.pid.to_s }

# ---- secret ----
secret = File.readlines(CFG).find { |l| l.start_with?('secret:') }
          .to_s.sub('secret:', '').strip
abort 'secret not found in base.yaml' if secret.empty?

# ---- 载入连接级高水位 ----
seen = {}
if File.exist?(STATE)
  begin
    seen = JSON.parse(File.read(STATE))
  rescue StandardError
    seen = {}
  end
end
seen = {} unless seen.is_a?(Hash)

def save_state(seen)
  File.write(STATE, JSON.generate(seen))
rescue StandardError
  nil
end

def flush(acc, live)
  tot = acc.values.sum
  row = [Time.now.to_i, live, tot] + GROUPS.map { |g| acc[g] }
  File.open(CSV, 'a') { |f| f.puts(row.join(',')) }
end

# ------------------------------------------------------------------
# 失效告警
#
# 采集器有三种「静默失效」模式，每一种都会让数据看起来正常但实际是空：
#   1. empty  —— OpenClash 没起/端口不通/secret 失效导致 curl 无返回
#   2. parse  —— 返回内容不是 JSON（如被替换成 HTML 错误页）
#   3. shape  —— JSON 能解析但没有 connections 数组（mihomo 升级改了 API）
# 连续失败达到阈值才告警一次，避免重启期间的正常抖动刷屏；恢复时也会记一条。
# ------------------------------------------------------------------
ALERT_AFTER = 6    # 连续失败次数阈值，×SAMPLE 秒 ≈ 30 秒

def alert(msg)
  ['=' * 64,
   "!! YTWATCH ALERT #{Time.now}: #{msg}",
   '=' * 64].join("\n")
end

fail_streak = 0
alerted = false

loop do
  live = 0
  deltas = Hash.new(0)
  state = :ok
  detail = nil
  j = nil

  begin
    raw = IO.popen(
      ['curl', '-s', '-m', '4', '-H', "Authorization: Bearer #{secret}",
       'http://127.0.0.1:9090/connections'], err: File::NULL, &:read
    )

    if raw.nil? || raw.strip.empty?
      state = :empty
      detail = 'curl 无返回：OpenClash 未运行、端口不通、或 secret 已失效'
    else
      begin
        j = JSON.parse(raw)
      rescue JSON::ParserError => e
        state = :parse
        detail = "返回不是合法 JSON：#{e.message[0, 60]}"
      else
        unless j.is_a?(Hash) && j['connections'].is_a?(Array)
          state = :shape
          detail = 'JSON 缺 connections 数组：mihomo 版本可能已升级，API 结构需检查'
        end
      end
    end
  rescue StandardError => e
    state = :empty
    detail = "curl 启动失败：#{e.message[0, 60]}"
  end

  if state == :ok
    if alerted
      warn "ytwatch: API 已恢复正常 #{Time.now}（此前数据有缺失）"
      alerted = false
    end
    fail_streak = 0

    now = Time.now.to_i
    (j['connections'] || []).each do |c|
      ch = c['chains'] || []
      next unless ch.include?(LB)

      sub = ch[1].to_s
      next unless GROUPS.include?(sub)

      live += 1
      id = c['id'].to_s
      dl = c['download'].to_i
      prev = seen[id]
      if prev
        d = dl - prev
        deltas[sub] += d if d.positive?
        seen[id] = dl if dl > prev
      else
        # 首见：该连接已消耗的配额计入
        deltas[sub] += dl if dl.positive?
        seen[id] = dl
      end
    end

    # 丢弃已消失的连接，防止 seen 无限增长
    alive = (j['connections'] || []).map { |c| c['id'].to_s }
    seen.reject! { |k, _| !alive.include?(k) }
    save_state(seen)

    unless deltas.empty?
      File.open(DELTA, 'a') do |f|
        f.puts([now, deltas.values.sum, *GROUPS.map { |g| deltas[g] }].join(','))
      end
    end

    if (now % FLUSH) < SAMPLE
      acc = Hash.new(0)
      if File.exist?(DELTA)
        File.readlines(DELTA).each do |l|
          p = l.strip.split(',')
          next if p.size < 3

          p[2..].each_with_index { |v, i| acc[GROUPS[i]] += v.to_i }
        end
      end
      flush(acc, live)
      File.write(DELTA, '')
    end
  else
    fail_streak += 1
    # 首次失败记一条明细（便于定位），持续失败不再重复刷
    warn "#{Time.now} 采样失败[#{state}]：#{detail}" if fail_streak == 1
    if fail_streak >= ALERT_AFTER && !alerted
      warn alert("连续 #{fail_streak} 次采样失败（约 #{fail_streak * SAMPLE} 秒）。" +
                 "末次原因：#{detail}。" +
                 "配额数据未记录 —— 请检查 OpenClash 与 API 状态。")
      alerted = true
    end
  end

  sleep SAMPLE
end
