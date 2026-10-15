# frozen_string_literal: false
# quota_logger.rb 的回归测试
#   A. 计费逻辑：首见计入 / 增量累加 / 重启不重复 / 连接消失 / 非 YT 流量忽略
#   B. 失效告警：空响应 / JSON 解析失败 / API 结构变化 三种静默失效模式
# 运行: ruby quota_logger_test.rb
require 'json'

LBPFX = "\u{1F4FA} YT-"
LB    = "\u{1F4FA} YT-LB"
GROUPS = (1..10).map { |i| "#{LBPFX}#{i}" }
ALERT_AFTER = 6

$pass = 0
$fail = 0

def ok(label)
  print "  #{label}: "
  begin
    yield
    puts 'PASS'
    $pass += 1
  rescue Exception => e
    puts "FAIL #{e.class}: #{e.message[0, 70]}"
    $fail += 1
  end
end

# ==================================================================
# A. 计费逻辑
# ==================================================================
def conn(id, sub, dl)
  { 'id' => id, 'download' => dl, 'upload' => 0,
    'chains' => ["\u8282\u70b9", "#{LBPFX}#{sub}", LB] }
end

def tick(snapshots, seen)
  deltas = Hash.new(0)
  live = 0
  snapshots.each do |c|
    ch = c['chains']
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
      deltas[sub] += dl if dl.positive?
      seen[id] = dl
    end
  end
  alive = snapshots.map { |c| c['id'].to_s }
  seen.reject! { |k, _| !alive.include?(k) }
  deltas
end

puts '=== A. 计费逻辑 ==='
ok('首见计全部') do
  s = {}; raise unless tick([conn('a', 1, 100)], s)["#{LBPFX}1"] == 100
end
ok('增量累加') do
  s = {}
  tick([conn('a', 1, 100)], s)
  raise unless tick([conn('a', 1, 250)], s)["#{LBPFX}1"] == 150
end
ok('无新增不计') do
  s = {}
  tick([conn('a', 1, 100)], s)
  raise unless tick([conn('a', 1, 100)], s)["#{LBPFX}1"] == 0
end
ok('多连接分别归属') do
  s = {}
  d = tick([conn('x', 3, 10), conn('y', 7, 20), conn('z', 3, 5)], s)
  raise unless d["#{LBPFX}3"] == 15 && d["#{LBPFX}7"] == 20 && d["#{LBPFX}2"] == 0
end
ok('连接消失后不串味') do
  s = {}
  tick([conn('p', 2, 999)], s)
  d = tick([conn('q', 5, 30)], s)
  raise unless d["#{LBPFX}2"] == 0 && d["#{LBPFX}5"] == 30
end
ok('重启不重复计数') do
  s = {}
  tick([conn('r', 4, 1_000_000)], s)
  s2 = JSON.parse(JSON.generate(s))
  raise unless tick([conn('r', 4, 1_000_000)], s2)["#{LBPFX}4"] == 0
end
ok('重启后继续累加') do
  s = {}
  tick([conn('r', 4, 1_000_000)], s)
  s2 = JSON.parse(JSON.generate(s))
  raise unless tick([conn('r', 4, 1_500_000)], s2)["#{LBPFX}4"] == 500_000
end
ok('非 YT-LB 流量被忽略') do
  s = {}
  d = tick([{ 'id' => 'o', 'download' => 999, 'chains' => ["\u8282\u70b9", '⚡ AUTO', '🚀 PROXY'] }], s)
  raise unless d.values.sum.zero? && !s.key?('o')
end
ok('连接关闭前增量已收齐') do
  s = {}
  tick([conn('s', 6, 5_000)], s)
  tick([conn('s', 6, 8_000)], s)
  d = tick([], s)
  raise unless d["#{LBPFX}6"].zero?
end

# ==================================================================
# B. 失效告警（与 quota_logger.rb 内的分类逻辑保持一致）
# ==================================================================
def classify(raw)
  return :empty if raw.nil? || raw.strip.empty?

  begin
    j = JSON.parse(raw)
    (j.is_a?(Hash) && j['connections'].is_a?(Array)) ? :ok : :shape
  rescue JSON::ParserError
    :parse
  end
end

def simulate(cases)
  fs = 0
  al = false
  out = []
  cases.each do |raw|
    if classify(raw) == :ok
      out << '已恢复正常' if al
      al = false
      fs = 0
      out << 'sampled'
    else
      fs += 1
      out << "失败[#{classify(raw)}]" if fs == 1
      if fs >= ALERT_AFTER && !al
        out << 'ALERT'
        al = true
      end
    end
  end
  out
end

puts '=== B. 失效告警 ==='
ok('首次失败记明细') { raise unless simulate([''] * 3).first == '失败[empty]' }
ok('空响应会告警') { raise unless simulate([''] * 10).include?('ALERT') }
ok('告警不重复') { raise unless simulate([''] * 20).count { |x| x == 'ALERT' } == 1 }
ok('抖动<阈值不告警') { raise if simulate([''] * 5).include?('ALERT') }
ok('API结构变化会告警') { raise unless simulate(['{"proxies":[]}'] * 8).include?('ALERT') }
ok('非JSON返回会告警') { raise unless simulate(['<html>502</html>'] * 8).include?('ALERT') }
ok('connections非数组会告警') { raise unless simulate(['{"connections":"x"}'] * 8).include?('ALERT') }
ok('恢复有记录') do
  r = simulate([''] * 7 + ['{"connections":[]}'])
  raise unless r.include?('已恢复正常')
end
ok('恢复后可再次告警') do
  r = simulate([''] * 7 + ['{"connections":[]}'] + [''] * 7)
  raise unless r.count { |x| x == 'ALERT' } == 2
end
ok('正常数据不受影响') { raise unless simulate(['{"connections":[]}'] * 4) == ['sampled'] * 4 }
ok('持续失败不刷明细') { raise unless simulate([''] * 15).count { |x| x.start_with?('失败') } == 1 }

puts
puts "通过 #{$pass} / #{$pass + $fail}"
exit($fail.zero? ? 0 : 1)
