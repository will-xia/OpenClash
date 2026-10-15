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

loop do
  live = 0
  deltas = Hash.new(0)
  begin
    raw = IO.popen(
      ['curl', '-s', '-m', '4', '-H', "Authorization: Bearer #{secret}",
       'http://127.0.0.1:9090/connections'], err: File::NULL, &:read
    )
    # 重启内核时 curl 会返回空，此时静默跳过本次采样，不记错误也不丢累计
    if raw.nil? || raw.strip.empty?
      sleep SAMPLE
      next
    end
    j = JSON.parse(raw)
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

    next if (now % FLUSH) >= SAMPLE

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
  rescue StandardError => e
    warn "#{Time.now} #{e.class}: #{e.message}"
  end
  sleep SAMPLE
end
