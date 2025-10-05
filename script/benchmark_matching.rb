#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'optparse'
require 'benchmark'
require 'redis_exchange'

DEFAULT_SYMBOL = 'BTCUSDT'
DEFAULT_OPTIONS = {
  symbol: DEFAULT_SYMBOL,
  resting_orders: 10_000,
  taker_orders: 10_000,
  redis_url: ENV['BENCH_REDIS_URL'] || ENV['SPEC_REDIS_URL'] || ENV['REDIS_URL'],
  price: 30_000_00,
  quantity: 1_000_000
}.freeze

options = DEFAULT_OPTIONS.dup
OptionParser.new do |parser|
  parser.banner = <<~BANNER
    Usage: ruby script/benchmark_matching.rb [options]

    Benchmarks the order matching path by:
      1. Seeding a market and loading a sell book with RESTING orders.
      2. Submitting taker BUY market orders against the book.
  BANNER

  parser.on('--symbol=SYMBOL', "Market symbol (default: #{DEFAULT_OPTIONS[:symbol]})") do |value|
    options[:symbol] = value
  end
  parser.on('--resting=N', Integer, 'Number of resting sell limit orders to seed (default: 10000)') do |value|
    options[:resting_orders] = value
  end
  parser.on('--taker=N', Integer, 'Number of taker market buy orders to execute (default: 10000)') do |value|
    options[:taker_orders] = value
  end
  parser.on('--redis-url=URL', 'Target Redis URL (default: BENCH_REDIS_URL | SPEC_REDIS_URL | REDIS_URL | in-memory)') do |value|
    options[:redis_url] = value
  end
  parser.on('--price=INTEGER', Integer, 'Scaled price for resting limit orders (default: 3_000_000)') do |value|
    options[:price] = value
  end
  parser.on('--quantity=INTEGER', Integer, 'Scaled quantity per order (default: 1_000_000)') do |value|
    options[:quantity] = value
  end
  parser.on('-h', '--help', 'Show this help message') do
    puts parser
    exit
  end
end.parse!

symbol = options[:symbol]
resting_orders = options[:resting_orders]
taker_orders = options[:taker_orders]
price = options[:price]
quantity = options[:quantity]

redis = if options[:redis_url]
          require 'redis'
          client = Redis.new(url: options[:redis_url])
          begin
            client.ping
          rescue StandardError => e
            warn "[benchmark] Failed to connect to Redis at #{options[:redis_url]}: #{e.message}"
            warn '[benchmark] Falling back to in-memory Redis'
            require 'redis_exchange/in_memory_redis'
            RedisExchange::InMemoryRedis.new
          else
            client
          end
        else
          require 'redis_exchange/in_memory_redis'
          RedisExchange::InMemoryRedis.new
        end

client = RedisExchange::Client.new(redis: redis)

trap('INT') do
  puts '\n[benchmark] Interrupted, cleaning up...'
  redis.close if redis.respond_to?(:close)
  exit 1
end

puts "[benchmark] WARNING: flushing Redis database at #{options[:redis_url] || 'in-memory instance'}"
redis.flushdb

client.seed_market(
  symbol: symbol,
  base_asset: 'BTC',
  quote_asset: 'USDT',
  price_scale: 100,
  quantity_scale: 100_000_000,
  maker_fee_bps: 5,
  taker_fee_bps: 10,
  min_qty: 1,
  min_notional: 1
)

client.set_balance(user_id: 'maker', asset: 'BTC', available: quantity * resting_orders)
client.set_balance(user_id: 'taker', asset: 'USDT', available: price * taker_orders * 2)

puts "[benchmark] Seeding #{resting_orders} resting sell limit orders..."
resting_orders.times do |i|
  client.place_limit_order(
    symbol: symbol,
    side: 'SELL',
    order_id: "rest-#{i}",
    user_id: 'maker',
    price: price,
    quantity: quantity
  )
end

puts "[benchmark] Executing #{taker_orders} taker market buy orders..."

timing = Benchmark.measure do
  taker_orders.times do |i|
    client.place_market_order(
      symbol: symbol,
      side: 'BUY',
      order_id: "taker-#{i}",
      user_id: 'taker',
      quantity: quantity,
      price_cap: price + 10_000
    )
  end
end

ops = taker_orders.to_f / timing.real
puts format('[benchmark] Total time: %.4fs', timing.real)
puts format('[benchmark] Throughput: %.2f orders/sec', ops)

redis.close if redis.respond_to?(:close)
