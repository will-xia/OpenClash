# frozen_string_literal: false
# quota_logger.rb 的单元级回归测试：用假数据驱动，验证计费逻辑
require 'json'
require 'tmpdir'

LBPFX = "\u{1F4FA} YT-"
LB    = "\u{1F4FA} YT-LB"
GROUPS = (1..10).map { |i| "#{LBPFX}#{i}" }

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

fails = 0
chk = ->(label, got, exp) {
  ok = got == exp
  puts(format('  %-34s %s', label, ok ? 'PASS' : "FAIL got=#{got.inspect} exp=#{exp.inspect}"))
  fails += 1 unless ok
}

puts '=== 增量累加 ==='
seen = {}
d1 = tick([conn('a', 1, 100)], seen)
d2 = tick([conn('a', 1, 250)], seen)
d3 = tick([conn('a', 1, 250)], seen)
chk.call('首见计全部', d1['📺 YT-1'], 100)
chk.call('增量', d2['📺 YT-1'], 150)
chk.call('无新增不计', d3['📺 YT-1'], 0)

puts '=== 多连接分别归属 ==='
seen = {}
d = tick([conn('x', 3, 10), conn('y', 7, 20), conn('z', 3, 5)], seen)
chk.call('YT-3 合计', d['📺 YT-3'], 15)
chk.call('YT-7', d['📺 YT-7'], 20)
chk.call('其他订阅为 0', d['📺 YT-2'], 0)

puts '=== 连接消失后新连接 id 不串味 ==='
seen = {}
tick([conn('p', 2, 999)], seen)
d = tick([conn('q', 5, 30)], seen)
chk.call('旧连接已清理', d['📺 YT-2'], 0)
chk.call('新连接独立', d['📺 YT-5'], 30)

puts '=== 重启不重复计数 ==='
seen = {}
tick([conn('r', 4, 1_000_000)], seen)
persisted = JSON.generate(seen)
seen2 = JSON.parse(persisted)
d = tick([conn('r', 4, 1_000_000)], seen2)
chk.call('重启后同连接增量为 0', d['📺 YT-4'], 0)
d = tick([conn('r', 4, 1_500_000)], seen2)
chk.call('重启后继续累加', d['📺 YT-4'], 500_000)

puts '=== 非 YT-LB 流量被忽略 ==='
seen = {}
other = { 'id' => 'o', 'download' => 999, 'chains' => ["\u8282\u70b9", '⚡ AUTO', '🚀 PROXY'] }
d = tick([other], seen)
chk.call('非 YT-LB 不计', d.values.sum, 0)
chk.call('seen 未记录', seen.key?('o'), false)

puts '=== HTML 反注(链接消失前把字节吃干净) ==='
seen = {}
tick([conn('s', 6, 5_000)], seen)
# 连接在下一个采样前关闭，且曾达到 8000
tick([conn('s', 6, 8_000)], seen)
d = tick([], seen) # 已消失
chk.call('关闭前增量已收齐', d['📺 YT-6'], 0)
chk.call('总计应为 8000', (d.values.sum + 8000), 8000)

puts
puts fails.zero? ? 'ALL PASS' : "#{fails} FAILED"
exit(fails.zero? ? 0 : 1)
