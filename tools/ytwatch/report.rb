# frozen_string_literal: false
# 读取 /etc/ytwatch/quota.csv，输出各订阅的用量曲线与均匀度评估
# 注意：quota.csv 每行是「每 300 秒窗口的增量」，不是累计值，故此处求和。
# 用法: ruby /etc/ytwatch/report.rb [csv路径]
require 'json'

LBPFX  = "\u{1F4FA} YT-"
GROUPS = (1..10).map { |i| "#{LBPFX}#{i}" }
path   = ARGV[0] || '/etc/ytwatch/quota.csv'

rows = []
if File.exist?(path)
  File.readlines(path).each do |l|
    p = l.strip.split(',')
    next if p.size < 13

    rows << { t: p[0].to_i, live: p[1].to_i, total: p[2].to_i,
              subs: p[3..].map(&:to_i) }
  end
end

if rows.empty?
  puts "没有数据：#{path} 为空或不存在"
  exit 0
end

mb = ->(b) { b > 1_048_576 ? format('%.2f MB', b / 1_048_576.0) : format('%.0f KB', b / 1024.0) }
first = rows.first
last  = rows.last

# 各行是窗口增量，求和得总量
sums = GROUPS.each_with_index.map { |_, i| rows.sum { |r| r[:subs][i] } }
tot = sums.sum
t0 = first[:t]
t1 = last[:t]

puts '=' * 68
puts " 观测窗口: #{Time.at(t0)}  →  #{Time.at(t1)}"
puts format(" 时长: %.2f 小时   采样窗口数: %d   峰值并发 YT 连接: %d",
            (t1 - t0) / 3600.0, rows.size, rows.map { |r| r[:live] }.max)
puts format(" 总下载: %s   (每 5 分钟一个窗口)", mb.(tot))
puts

puts '=== 各订阅下载总量 ==='
GROUPS.each_with_index.sort_by { |_, i| -sums[i] }.each do |g, i|
  d = sums[i]
  pct = tot.positive? ? (d * 100.0 / tot) : 0.0
  ideal = tot.positive? ? (tot.to_f / 10) : 0.0
  ratio = ideal.positive? ? (d / ideal) : 0.0
  bar = pct.positive? ? '#' * [pct.to_i / 2, 0].max : ''
  puts format('  %-10s %10s  %5.1f%%  相对理想1/10 %5.1fx  %s',
              g, mb.(d), pct, ratio, bar)
end
puts

puts '=== 均匀度 ==='
used = sums.count { |d| d.positive? }
puts "  有流量的订阅数: #{used}/10"
nz = sums.select { |d| d.positive? }
if nz.size > 1
  mx = nz.max
  mn = nz.min
  puts format("  最大/最小 比: %s / %s = %.1fx", mb.(mx), mb.(mn), mx.to_f / mn)
end
if tot.positive?
  xs = sums.sort
  n = xs.size
  cum = 0.0
  xs.each_with_index { |x, i| cum += (2 * (i + 1) - n - 1) * x }
  gini = cum / (n * tot.to_f)
  puts format("  基尼系数: %.3f   (0=完全均匀, 1=全部集中在一个)", gini)
  verdict = if gini < 0.15 then '很均匀'
            elsif gini < 0.30 then '基本均匀'
            elsif gini < 0.50 then '偏斜'
            else '严重倾斜'
            end
  puts "  判定: #{verdict}"
end
puts

puts '=== 累计曲线(每点 = 截至该时刻的累计下载) ==='
step = [rows.size / 12, 1].max
cum_arr = []
run = [0] * GROUPS.size
rows.each do |r|
  run = run.each_index.map { |k| run[k] + r[:subs][k] }
  cum_arr << { t: r[:t], total: run.sum, live: r[:live], run: run.dup }
end
sel = (0...cum_arr.size).step(step).to_a
sel << cum_arr.size - 1 unless sel.empty? || sel.last == cum_arr.size - 1
cum_arr.each_with_index do |c, i|
  next unless sel.include?(i)

  top_k = c[:run].each_with_index.max_by { |v, _| v }[1]
  share = c[:total].positive? ? (c[:run][top_k] * 100.0 / c[:total]) : 0.0
  puts format('  %s  %9s  并发:%-2d  最大: %s %.0f%%',
              Time.at(c[:t]).strftime('%m-%d %H:%M'), mb.(c[:total]), c[:live],
              GROUPS[top_k], share)
end

