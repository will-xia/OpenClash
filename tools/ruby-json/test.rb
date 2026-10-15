# frozen_string_literal: false
# 用 require_relative 强制加载本目录下的实现，避免命中系统 json
require_relative 'json'

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

def bad(label, src)
  print "  #{label}: "
  begin
    JSON.parse(src)
    puts 'FAIL (未报错)'
    $fail += 1
  rescue JSON::ParserError
    puts 'PASS (ParserError)'
    $pass += 1
  rescue Exception => e
    puts "FAIL 抛了 #{e.class}: #{e.message[0, 50]}"
    $fail += 1
  end
end

puts '确认加载的是本目录实现:'
puts "  JSON::VERSION = #{JSON::VERSION}"
raise '加载错了，不是 shim' unless JSON::VERSION.include?('shim')

puts '=== 解析 ==='
ok('解析对象') { raise unless JSON.parse('{"a":1}') == { 'a' => 1 } }
ok('解析数组') { raise unless JSON.parse('[1,2,3]') == [1, 2, 3] }
ok('解析嵌套') do
  raise unless JSON.parse('{"a":[1,{"b":[true,false,null]}]}') == { 'a' => [1, { 'b' => [true, false, nil] }] }
end
ok('浮点/指数') { raise unless JSON.parse('[1.5,-0.5,2e3,-1.5E-2]') == [1.5, -0.5, 2000.0, -0.015] }
ok('零/负数/大整数') { raise unless JSON.parse('[0,-7,123456789012345]') == [0, -7, 123456789012345] }

# JSON 文本：{"s":"a\"b\\c\/d\be\ff\ng\rh\ti"}
STR_JSON = "{\"s\":\"a\\\"b\\\\c\\/d\\be\\ff\\ng\\rh\\ti\"}"
STR_EXP  = "a\"b\\c/d\be\ff\ng\rh\ti"
ok('字符串转义') do
  got = JSON.parse(STR_JSON)['s']
  raise "got #{got.inspect}" unless got == STR_EXP
end
ok('\\uXXXX') { raise unless JSON.parse('{"u":"\u00e9\u4e2d"}')['u'] == "é中" }
ok('代理对') { raise unless JSON.parse('"\ud83c\udfac"') == "\u{1F3AC}" }
ok('U+1F4FA 代理对') { raise unless JSON.parse('"\ud83d\udcfa"') == "\u{1F4FA}" }
ok('裸中文') { raise unless JSON.parse('{"k":"中文直接量"}')['k'] == '中文直接量' }
ok('空对象/数组') { raise unless JSON.parse('{"o":{},"a":[]}') == { 'o' => {}, 'a' => [] } }
ok('空白容忍') { raise unless JSON.parse("  {  \"a\" :  1  }  ") == { 'a' => 1 } }
ok('tab/newline 分隔') { raise unless JSON.parse("{ \"a\"\t:\n1 }") == { 'a' => 1 } }
ok('超长数组') do
  a = JSON.parse('[' + (1..5000).to_a.join(',') + ']')
  raise unless a.size == 5000 && a.last == 5000
end
ok('深层嵌套(未超限)') do
  d = 90
  raise unless JSON.parse('[' * d + ']' * d).is_a?(Array)
end

puts '=== 生成 ==='
ok('生成对象') { raise unless JSON.generate('a' => 1) == '{"a":1}' }
ok('生成数组') { raise unless JSON.generate([1, 'x', nil, true]) == '[1,"x",null,true]' }
ok('生成转义') do
  got = JSON.generate('k' => "a\"b\\c\nd")
  exp = "{\"k\":\"a\\\"b\\\\c\\nd\"}"
  raise "got #{got.inspect} exp #{exp.inspect}" unless got == exp
end
ok('生成控制符') { raise unless JSON.generate(["\x00\x1f"]) == '["\u0000\u001f"]' }
ok('生成中文') { raise unless JSON.generate('k' => '中') == '{"k":"中"}' }
ok('符号键') { raise unless JSON.generate(a: 1) == '{"a":1}' }
ok('符号值') { raise unless JSON.generate([:a, :b]) == '["a","b"]' }
ok('浮点') { raise unless JSON.generate([1.0, 1.5, -0.25]) == '[1.0,1.5,-0.25]' }
ok('空容器') { raise unless JSON.generate([]) == '[]' && JSON.generate({}) == '{}' }
ok('pretty') do
  exp = "{\n  \"a\": [\n    1,\n    2\n  ]\n}"
  got = JSON.pretty_generate('a' => [1, 2])
  raise "got #{got.inspect}" unless got == exp
end
ok('嵌套 pretty') do
  exp = "{\n  \"x\": {\n    \"y\": [\n      1\n    ]\n  }\n}"
  got = JSON.pretty_generate('x' => { 'y' => [1] })
  raise "got #{got.inspect}" unless got == exp
end

puts '=== 其他 API ==='
ok('JSON[]') { raise unless JSON['[1]'] == [1] && JSON('z' => 1) == '{"z":1}' }
ok('Kernel#JSON') { raise unless send(:JSON, '{"a":1}') == { 'a' => 1 } }
ok('to_json') { raise unless [1, 'a', nil, true].to_json == '[1,"a",null,true]' }
ok('String#to_json') { raise unless "a\"b".to_json == '"a\"b"' }
ok('fast_generate') { raise unless JSON.fast_generate('a' => 1) == '{"a":1}' }
ok('dump') { raise unless JSON.dump('a' => 1) == '{"a":1}' }
ok('load_file') do
  File.write('/tmp/jsonshim_t.json', '{"f":1}')
  raise unless JSON.load_file('/tmp/jsonshim_t.json') == { 'f' => 1 }
end
ok('symbolize_names') { raise unless JSON.parse('{"a":1}', symbolize_names: true) == { a: 1 } }
ok('parse!') { raise unless JSON.parse!('{"a":1}') == { 'a' => 1 } }
ok('depth 限制') do
  begin
    JSON.parse('[' * 50 + ']' * 50, max_nesting: 10)
    raise '应该抛 NestingError'
  rescue JSON::NestingError
    true
  end
end

puts '=== 往返一致性 ==='
ok('roundtrip ASCII+中文') do
  src = "{\"n\":123,\"f\":1.5,\"s\":\"a\\\"b\\\\c\\nd\\te\",\"u\":\"é中🎬\",\"b\":[true,false,null],\"e\":{},\"z\":[]}"
  obj = JSON.parse(src)
  got = JSON.generate(obj)
  raise "got #{got.inspect}\n exp #{src.inspect}" unless got == src
end
ok('roundtrip 深层') do
  o = (1..50).inject({}) { |h, i| { "k#{i}" => [i, "v#{i}", nil] } }
  raise unless JSON.parse(JSON.generate(o)) == o
end

puts '=== 错误处理 ==='
bad('空输入', '')
bad('残缺对象', '{"a":')
bad('尾随垃圾', '{"a":1}x')
bad('裸字面量', 'foo')
bad('坏转义 \\q', '{"a":"\q"}')
bad('缺引号键', '{a:1}')
bad('数字残缺', '[1.]')
bad('坏 \\u', '{"a":"\u00"}')
bad('未闭合字符串', '{"a":"abc}')
bad('裸逗号', '[,]')
bad('双逗号', '[1,,2]')
bad('true 拼错', 'tru')
bad('串中控制字符', "{\"a\":\"x\ty\"}")

puts
puts "通过 #{$pass} / #{$pass + $fail}"
exit($fail.zero? ? 0 : 1)
