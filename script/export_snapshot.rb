#!/usr/bin/env ruby
# frozen_string_literal: true

# Export an immutable JSON snapshot of all Redis Exchange state.
# Includes markets, assets, balances, order books, queues, user indexes,
# streams (trades/orders/account_ledger), tickers, and sequence counters.

require 'optparse'
require 'json'
require 'redis'
require 'time'
require 'fileutils'
require 'set'

begin
  require_relative '../lib/redis_exchange/version'
rescue LoadError
end

options = {
  redis_url: ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0',
  output: File.join('tmp', "redis_exchange_export-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}.json"),
  pretty: true,
  stream_batch: 1000,
  max_stream_entries: nil,
  quiet: false
}

OptionParser.new do |parser|
  parser.banner = 'Usage: bundle exec ruby script/export_snapshot.rb [options]'

  parser.on('--redis-url=URL', 'Redis connection URL (default: REDIS_URL or local)') do |url|
    options[:redis_url] = url
  end

  parser.on('--output=PATH', 'Output file (default: tmp/redis_exchange_export-<timestamp>.json)') do |path|
    options[:output] = path
  end

  parser.on('--[no-]pretty', 'Pretty print JSON (default: true)') do |flag|
    options[:pretty] = flag
  end

  parser.on('--stream-batch=N', Integer, 'Stream pagination batch size (default: 1000)') do |size|
    options[:stream_batch] = [size.to_i, 1].max
  end

  parser.on('--max-stream-entries=N', Integer, 'Optional limit per stream (default: all entries)') do |limit|
    options[:max_stream_entries] = limit.to_i if limit
  end

  parser.on('--quiet', 'Suppress progress output') do
    options[:quiet] = true
  end
end.parse!

class SnapshotExporter
  NUMERIC_REGEX = /\A-?\d+\z/
  FLOAT_REGEX = /\A-?\d+\.\d+\z/

  def initialize(redis, stream_batch:, max_stream_entries: nil)
    @redis = redis
    @stream_batch = [stream_batch.to_i, 1].max
    @max_stream_entries = max_stream_entries && max_stream_entries > 0 ? max_stream_entries : nil
  end

  def call
    markets = gather_hashes('market:*', strip_prefix: 'market:')
    symbols = collect_symbols(markets.keys)

    {
      exported_at: Time.now.utc.iso8601,
      metadata: metadata,
      assets: gather_hashes('asset:*', strip_prefix: 'asset:'),
      markets: markets,
      tickers: gather_hashes('ticker:*', strip_prefix: 'ticker:'),
      balances: gather_balances,
      orders: gather_orders,
      books: gather_books(symbols),
      queues: gather_lists('queue:*', strip_prefix: 'queue:'),
      user_order_indexes: gather_zsets('user_orders:*', strip_prefix: 'user_orders:'),
      streams: {
        trades: gather_streams('trades:*', strip_prefix: 'trades:'),
        orders: gather_streams('orders:*', strip_prefix: 'orders:'),
        account_ledger: read_stream('account_ledger')
      },
      sequences: {
        market: gather_sequences('seq:*', strip_prefix: 'seq:'),
        ledger: gather_ledger_sequences
      }
    }
  end

  private

  def collect_symbols(existing)
    symbols = Set.new(existing)
    pattern_index = {
      'book:*' => 1,
      'volume:*' => 1,
      'trades:*' => 1,
      'orders:*' => 1,
      'ticker:*' => 1,
      'queue:*' => 1
    }
    pattern_index.each do |pattern, idx|
      scan_keys(pattern).each do |key|
        parts = key.split(':')
        symbols << parts[idx] if parts[idx]
      end
    end
    symbols.to_a
  end

  def metadata
    meta = { ruby_version: RUBY_VERSION }
    if defined?(RedisExchange::VERSION)
      meta[:redis_exchange_version] = RedisExchange::VERSION
    end
    meta
  end

  def gather_hashes(pattern, strip_prefix: nil)
    result = {}
    scan_keys(pattern).sort.each do |key|
      data = normalize_hash(@redis.hgetall(key))
      next if data.empty?
      result[strip_key(key, strip_prefix)] = data
    end
    result
  end

  def gather_balances
    result = {}
    scan_keys('balance:*').sort.each do |key|
      raw = @redis.hgetall(key)
      next if raw.empty?
      user = strip_key(key, 'balance:')
      structured = {}
      raw.each do |field, value|
        if field.include?(':')
          asset, bucket = field.split(':', 2)
          next unless bucket
          structured[asset] ||= {}
          structured[asset][bucket] = coerce_number(value)
        else
          structured[field] = coerce_number(value)
        end
      end
      result[user] = structured unless structured.empty?
    end
    result
  end

  def gather_orders
    result = {}
    scan_keys('order:*').sort.each do |key|
      data = normalize_hash(@redis.hgetall(key))
      next if data.empty?
      result[strip_key(key, 'order:')] = data
    end
    result
  end

  def gather_books(symbols)
    result = {}
    symbols.sort.each do |symbol|
      buy = fetch_book_side(symbol, 'BUY')
      sell = fetch_book_side(symbol, 'SELL')
      volume_buy = normalize_hash(@redis.hgetall("volume:#{symbol}:BUY"))
      volume_sell = normalize_hash(@redis.hgetall("volume:#{symbol}:SELL"))
      next if buy.empty? && sell.empty? && volume_buy.empty? && volume_sell.empty?
      result[symbol] = {
        buy: buy,
        sell: sell,
        volume: {
          buy: volume_buy,
          sell: volume_sell
        }
      }
    end
    result
  end

  def gather_lists(pattern, strip_prefix: nil)
    result = {}
    scan_keys(pattern).sort.each do |key|
      values = @redis.lrange(key, 0, -1)
      next if values.empty?
      result[strip_key(key, strip_prefix)] = values
    end
    result
  end

  def gather_zsets(pattern, strip_prefix: nil)
    result = {}
    scan_keys(pattern).sort.each do |key|
      entries = fetch_zset(key)
      next if entries.empty?
      result[strip_key(key, strip_prefix)] = entries
    end
    result
  end

  def gather_streams(pattern, strip_prefix: nil)
    result = {}
    scan_keys(pattern).sort.each do |key|
      entries = read_stream(key)
      next if entries.empty?
      result[strip_key(key, strip_prefix)] = entries
    end
    result
  end

  def gather_sequences(pattern, strip_prefix: nil)
    result = {}
    scan_keys(pattern).sort.each do |key|
      value = @redis.get(key)
      next unless value
      result[strip_key(key, strip_prefix)] = coerce_number(value)
    end
    result
  end

  def gather_ledger_sequences
    result = {}
    scan_keys('ledger_seq:*').sort.each do |key|
      parts = key.split(':', 3)
      next unless parts.length == 3
      user = parts[1]
      asset = parts[2]
      seq = @redis.get(key)
      next unless seq
      result[user] ||= {}
      result[user][asset] = coerce_number(seq)
    end
    result
  end

  def fetch_book_side(symbol, side)
    book_key = "book:#{symbol}:#{side}"
    normalize_zset(@redis.zrange(book_key, 0, -1, with_scores: true)).map do |member, score|
      entry = { value: member, score: coerce_number(score) }
      numeric = integer_like?(member) ? member.to_i : nil
      entry[:value_numeric] = numeric if numeric
      entry
    end
  end

  def fetch_zset(key)
    normalize_zset(@redis.zrange(key, 0, -1, with_scores: true)).map do |member, score|
      entry = { member: member, score: coerce_number(score) }
      entry[:member_numeric] = member.to_i if integer_like?(member)
      entry
    end
  end

  def read_stream(key)
    entries = []
    start = '-'
    remaining = @max_stream_entries

    loop do
      count = @stream_batch
      count = [count, remaining].min if remaining
      batch = count ? @redis.xrange(key, start, '+', count: count) : @redis.xrange(key, start, '+')
      break if batch.nil? || batch.empty?

      batch.each do |unit|
        id, fields = unit
        entries << { id: id, fields: normalize_hash(fields_to_hash(fields)) }
      end

      break if batch.length < (count || @stream_batch)

      if remaining
        remaining -= batch.length
        break if remaining <= 0
      end

      start = increment_stream_id(batch.last[0])
    end

    entries
  end

  def scan_keys(pattern)
    keys = []
    cursor = '0'
    loop do
      cursor, batch = @redis.scan(cursor, match: pattern, count: 200)
      keys.concat(Array(batch))
      break if cursor == '0'
    end
    keys
  end

  def strip_key(key, strip_prefix)
    return key unless strip_prefix
    key.start_with?(strip_prefix) ? key[strip_prefix.length..-1] : key
  end

  def normalize_hash(hash)
    hash.each_with_object({}) do |(k, v), acc|
      acc[k] = coerce_number(v)
    end
  end

  def fields_to_hash(fields)
    return fields if fields.is_a?(Hash)
    array = Array(fields)
    result = {}
    array.each_slice(2) do |field, value|
      result[field] = value
    end
    result
  end

  def normalize_zset(raw)
    array = Array(raw)
    return array if array.empty?
    if array.first.is_a?(Array)
      array
    else
      array.each_slice(2).to_a
    end
  end

  def coerce_number(value)
    return value if value.nil?
    return value if value.is_a?(Numeric)
    string = value.to_s
    return string.to_i if integer_like?(string)
    return string.to_f if string.match?(FLOAT_REGEX)
    string
  end

  def integer_like?(value)
    return false if value.nil?
    value = value.to_s unless value.is_a?(String)
    value.match?(NUMERIC_REGEX)
  end

  def increment_stream_id(last_id)
    ms, seq = last_id.split('-', 2)
    ms_i = ms.to_i
    seq_i = seq.to_i
    "#{ms_i}-#{seq_i + 1}"
  end
end

redis = Redis.new(url: options[:redis_url])
exporter = SnapshotExporter.new(
  redis,
  stream_batch: options[:stream_batch],
  max_stream_entries: options[:max_stream_entries]
)

payload = exporter.call

FileUtils.mkdir_p(File.dirname(options[:output]))
json = options[:pretty] ? JSON.pretty_generate(payload) : JSON.generate(payload)
File.write(options[:output], json)

puts "Export completed: #{options[:output]}" unless options[:quiet]

begin
  redis.close if redis.respond_to?(:close)
rescue StandardError
end
