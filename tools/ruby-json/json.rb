# frozen_string_literal: false
#
# 自包含的纯 Ruby JSON 实现，为这台设备上被精简过的 Ruby 提供 JSON.parse / JSON.generate。
# 官方 json gem 依赖 strscan C 扩展，该扩展在此环境中不存在，故用本文件替代。
# API 对齐官方 json gem 的常用子集。
# 安装位置：/usr/lib/ruby/site_ruby/3.4/json.rb（在 $LOAD_PATH 中，require 'json' 即可加载）

module JSON
  VERSION = '2.7.2-pure-ruby-shim'

  class JSONError < StandardError; end
  class ParserError < JSONError; end
  class NestingError < ParserError; end
  class GeneratorError < JSONError; end

  UNSET = Object.new

  # ------------------------------------------------------------------
  # 解析
  # ------------------------------------------------------------------
  class Parser
    WS = " \t\n\r".freeze
    DIGITS = ('0'..'9').to_a.freeze
    HEXDIG = /\A[0-9a-fA-F]{4}\z/

    def initialize(source, opts = nil)
      s = source.to_str
      s = s.dup.force_encoding(Encoding::UTF_8) unless s.encoding == Encoding::UTF_8
      unless s.valid_encoding?
        raise JSON::ParserError, 'source is not valid UTF-8'
      end
      @s = s
      @i = 0
      @n = s.length
      o = opts || {}
      @max_nesting = o.key?(:max_nesting) ? o[:max_nesting] : 100
      @symbolize = o[:symbolize_names] ? true : false
      @depth = 0
    end

    def parse
      skip_ws
      v = parse_value
      skip_ws
      unless @i >= @n
        raise JSON::ParserError, format('unexpected token %p at %d', @s[@i], @i)
      end
      v
    end

    def self.parse(source, opts = nil)
      new(source, opts).parse
    end

    private

    def skip_ws
      @i += 1 while @i < @n && WS.include?(@s[@i])
    end

    def parse_value
      raise JSON::ParserError, 'unexpected end of input' if @i >= @n
      case (c = @s[@i])
      when '{' then parse_object
      when '[' then parse_array
      when '"' then parse_string
      when 't' then parse_keyword('true', true)
      when 'f' then parse_keyword('false', false)
      when 'n' then parse_keyword('null', nil)
      when '-', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'
        parse_number
      else
        raise JSON::ParserError, format('unexpected token %p at %d', c, @i)
      end
    end

    def enter!
      @depth += 1
      if @max_nesting && @depth > @max_nesting
        raise JSON::NestingError, "nesting of #{@depth} is too deep"
      end
    end

    def leave!
      @depth -= 1
    end

    def parse_keyword(word, value)
      if @s[@i, word.length] == word
        @i += word.length
        value
      else
        raise JSON::ParserError,
              format('invalid literal, expected %p at %d', word, @i)
      end
    end

    def parse_object
      enter!
      @i += 1
      obj = {}
      skip_ws
      if @s[@i] == '}'
        @i += 1
        leave!
        return obj
      end
      loop do
        skip_ws
        unless @s[@i] == '"'
          raise JSON::ParserError,
                format('object key must be a string at %d (got %p)', @i, @s[@i])
        end
        key = parse_string
        skip_ws
        unless @s[@i] == ':'
          raise JSON::ParserError, format("expected ':' at %d", @i)
        end
        @i += 1
        skip_ws
        obj[@symbolize ? key.to_sym : key] = parse_value
        skip_ws
        case @s[@i]
        when ','
          @i += 1
        when '}'
          @i += 1
          leave!
          return obj
        else
          raise JSON::ParserError,
                format("expected ',' or '}' at %d (got %p)", @i, @s[@i])
        end
      end
    end

    def parse_array
      enter!
      @i += 1
      arr = []
      skip_ws
      if @s[@i] == ']'
        @i += 1
        leave!
        return arr
      end
      loop do
        skip_ws
        arr << parse_value
        skip_ws
        case @s[@i]
        when ','
          @i += 1
        when ']'
          @i += 1
          leave!
          return arr
        else
          raise JSON::ParserError,
                format("expected ',' or ']' at %d (got %p)", @i, @s[@i])
        end
      end
    end

    ESCAPES = {
      '"'  => '"',
      '\\' => '\\',
      '/'  => '/',
      'b'  => "\b",
      'f'  => "\f",
      'n'  => "\n",
      'r'  => "\r",
      't'  => "\t"
    }.freeze

    def parse_string
      @i += 1 # opening quote
      out = +''
      loop do
        if @i >= @n
          raise JSON::ParserError, 'unterminated string'
        end
        c = @s[@i]
        if c == '"'
          @i += 1
          return out
        elsif c == '\\'
          @i += 1
          if @i >= @n
            raise JSON::ParserError, 'unterminated escape'
          end
          e = @s[@i]
          if ESCAPES.key?(e)
            out << ESCAPES[e]
            @i += 1
          elsif e == 'u'
            out << parse_unicode_escape
          else
            raise JSON::ParserError,
                  format('invalid escape %p at %d', '\\' + e.to_s, @i)
          end
        elsif c.ord < 0x20
          raise JSON::ParserError,
                format('control character 0x%02x in string at %d', c.ord, @i)
        else
          out << c
          @i += 1
        end
      end
    end

    def parse_unicode_escape
      @i += 1 # 'u'
      cp = read_hex4
      if cp >= 0xD800 && cp <= 0xDBFF && @s[@i, 2] == '\\u'
        save = @i
        @i += 2
        lo = read_hex4
        if lo >= 0xDC00 && lo <= 0xDFFF
          cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
        else
          @i = save
        end
      end
      [cp].pack('U')
    rescue RangeError
      raise JSON::ParserError, 'invalid unicode code point'
    end

    def read_hex4
      hex = @s[@i, 4]
      if hex.nil? || hex.length < 4 || hex !~ HEXDIG
        raise JSON::ParserError, format('invalid \\u escape at %d', @i)
      end
      @i += 4
      hex.to_i(16)
    end

    def digit?(c)
      !c.nil? && DIGITS.include?(c)
    end

    def parse_number
      start = @i
      @i += 1 if @s[@i] == '-'

      int_start = @i
      if @s[@i] == '0'
        @i += 1
      else
        @i += 1 while digit?(@s[@i])
        if @i == int_start
          raise JSON::ParserError,
                format('number expected at %d (got %p)', @i, @s[@i])
        end
      end

      is_float = false
      if @s[@i] == '.'
        is_float = true
        @i += 1
        frac_start = @i
        @i += 1 while digit?(@s[@i])
        if @i == frac_start
          raise JSON::ParserError, format('digit expected after "." at %d', @i)
        end
      end

      if @s[@i] == 'e' || @s[@i] == 'E'
        is_float = true
        @i += 1
        @i += 1 if @s[@i] == '+' || @s[@i] == '-'
        exp_start = @i
        @i += 1 while digit?(@s[@i])
        if @i == exp_start
          raise JSON::ParserError, format('digit expected in exponent at %d', @i)
        end
      end

      raw = @s[start, @i - start]
      is_float ? raw.to_f : raw.to_i
    end
  end

  # ------------------------------------------------------------------
  # 生成
  # ------------------------------------------------------------------
  module GeneratorMethods
  end

  ESCAPE_MAP = {
    '"'  => '\\"',
    '\\' => '\\\\',
    "\b" => '\\b',
    "\f" => '\\f',
    "\n" => '\\n',
    "\r" => '\\r',
    "\t" => '\\t'
  }.freeze

  def self.quote(s)
    out = +'"'
    s.each_char do |c|
      if ESCAPE_MAP.key?(c)
        out << ESCAPE_MAP[c]
      elsif c.ord < 0x20
        out << format('\\u%04x', c.ord)
      else
        out << c
      end
    end
    out << '"'
    out
  end

  def self.nan?(f)
    f.respond_to?(:nan?) && f.nan?
  end

  def self.infinite?(f)
    f.respond_to?(:infinite?) && !f.infinite?.nil?
  end

  # 紧凑输出
  def self.generate(obj, _opts = nil)
    buf = +''
    build(obj, buf, nil, nil, nil, nil)
    buf
  end
  class << self
    alias_method :fast_generate, :generate
  end

  # 美化输出
  def self.pretty_generate(obj, opts = nil)
    o = opts || {}
    indent = o[:indent] || '  '
    space  = o.key?(:space) ? o[:space] : ' '
    nl     = o.key?(:object_nl) ? o[:object_nl] : "\n"
    nl2    = o.key?(:array_nl) ? o[:array_nl] : "\n"
    buf = +''
    build(obj, buf, indent, space, nl, nl2)
    buf
  end

  def self.build(o, buf, ind, sp, onl, anl, level = 0)
    case o
    when nil    then buf << 'null'
    when true   then buf << 'true'
    when false  then buf << 'false'
    when String then buf << quote(o)
    when Symbol then buf << quote(o.to_s)
    when Integer then buf << o.to_s
    when Float
      if nan?(o) || infinite?(o)
        raise JSON::GeneratorError, format('cannot generate %p', o)
      end
      buf << o.to_s
    when Array
      if o.empty?
        buf << '[]'
      else
        pad  = ind ? anl + (ind * (level + 1)) : ''
        tail = ind ? anl + (ind * level) : ''
        buf << '['
        first = true
        o.each do |v|
          buf << ',' unless first
          first = false
          buf << pad
          build(v, buf, ind, sp, onl, anl, level + 1)
        end
        buf << tail << ']'
      end
    when Hash
      if o.empty?
        buf << '{}'
      else
        pad  = ind ? onl + (ind * (level + 1)) : ''
        tail = ind ? onl + (ind * level) : ''
        buf << '{'
        first = true
        o.each do |k, v|
          buf << ',' unless first
          first = false
          buf << pad << quote(key_str(k)) << ':' << (sp || '')
          build(v, buf, ind, sp, onl, anl, level + 1)
        end
        buf << tail << '}'
      end
    else
      if o.respond_to?(:to_json)
        v = o.to_json
        raise JSON::GeneratorError, 'to_json must return a String' unless v.is_a?(String)
        buf << v
      else
        raise JSON::GeneratorError,
              format('source sequence is illegal - %p', o)
      end
    end
  end

  def self.key_str(k)
    case k
    when String then k
    when Symbol then k.to_s
    else k.to_s
    end
  end

  def self.dump(obj, an_io = nil, _limit = nil)
    s = generate(obj)
    if an_io.respond_to?(:write)
      an_io.write(s)
      an_io
    else
      s
    end
  end

  def self.load_file(path, _opts = nil)
    parse(File.read(path, encoding: Encoding::UTF_8))
  end

  # ------------------------------------------------------------------
  # 顶层入口
  # ------------------------------------------------------------------
  class << self
    def parse(source, opts = nil)
      Parser.parse(source, opts)
    end

    def parse!(source, opts = nil)
      o = { max_nesting: false, allow_nan: true }
      o.merge!(opts) if opts
      Parser.new(source, o).parse
    end

    def load(source, _proc = nil, _opts = nil)
      Parser.parse(source.to_str)
    end
    alias_method :restore, :load
    alias_method :unsafe_load, :load

    def [](object, opts = nil)
      object.is_a?(String) ? parse(object, opts) : generate(object, opts)
    end
  end
end

# ------------------------------------------------------------------
# 让常用对象支持 #to_json（对齐官方 gem 的常见行为）
# ------------------------------------------------------------------
class Object
  def to_json(*)
    JSON.quote(to_s)
  end
end

class NilClass
  def to_json(*)
    'null'
  end
end

class TrueClass
  def to_json(*)
    'true'
  end
end

class FalseClass
  def to_json(*)
    'false'
  end
end

class String
  def to_json(*)
    JSON.quote(self)
  end
end

class Symbol
  def to_json(*)
    JSON.quote(to_s)
  end
end

class Integer
  def to_json(*)
    to_s
  end
end

class Float
  def to_json(*)
    if JSON.nan?(self) || JSON.infinite?(self)
      raise JSON::GeneratorError, format('cannot generate %p', self)
    end
    to_s
  end
end

class Array
  def to_json(*)
    JSON.generate(self)
  end
end

class Hash
  def to_json(*)
    JSON.generate(self)
  end
end

module Kernel
  private

  def JSON(object, *args)
    object.is_a?(String) ? ::JSON.parse(object, args.first) : ::JSON.generate(object, args.first)
  end
end
