#!/usr/bin/env ruby
# frozen_string_literal: true

# Demo: Consume trades from Redis Streams and persist to local file
# Usage:
#   bundle exec ruby script/trades_demo.rb
#   # Environment overrides:
#   # REDIS_URL=redis://127.0.0.1:6379/0 SYMBOL=BTCUSDT GROUP=trades-consumers CONSUMER=demo-1 OUTPUT=tmp/trades_demo.log bundle exec ruby script/trades_demo.rb
#   # Seed a sample trade:
#   # SEED=1 bundle exec ruby script/trades_demo.rb

require 'json'
require 'redis'
require 'socket'
require 'fileutils'
require_relative '../lib/redis_exchange'

redis_url   = ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379/0')
symbol      = ENV.fetch('SYMBOL', 'BTCUSDT')
group       = ENV.fetch('GROUP', 'trades-consumers')
consumer_id = ENV.fetch('CONSUMER', "demo-#{Socket.gethostname rescue 'local'}")
output_path = ENV.fetch('OUTPUT', File.join(__dir__, '..', 'tmp', 'trades_demo.log'))

redis    = Redis.new(url: redis_url)
exchange = RedisExchange::Client.new(redis: redis)
consumer = exchange.trade_consumer(symbol: symbol, group: group, consumer: consumer_id)

FileUtils.mkdir_p(File.dirname(output_path))
puts "[START] Trade consumer for #{symbol} group=#{group} consumer=#{consumer_id} output=#{output_path}"

trap 'INT' do
  puts "\n[STOP] Shutting down consumer..."
  begin
    redis.close if redis.respond_to?(:close)
  rescue StandardError
  end
  exit 0
end

# Optional: seed a sample trade for the demo
if ENV['SEED'] == '1'
  puts '[SEED] Seeding market and generating a sample trade...'
  exchange.seed_market(
    symbol: symbol,
    base_asset: 'BTC',
    quote_asset: 'USDT',
    price_scale: 100,
    quantity_scale: 100_000_000,
    maker_fee_bps: 0,
    taker_fee_bps: 0,
    min_qty: 1,
    min_notional: 1
  )

  exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)
  exchange.place_limit_order(
    symbol: symbol,
    side: 'SELL',
    order_id: 'maker-1',
    user_id: 'maker',
    price: 3_000_000,
    quantity: 50_000_000
  )

  exchange.set_balance(user_id: 'taker', asset: 'USDT', available: 1_000_000_000)
  exchange.place_market_order(
    symbol: symbol,
    side: 'BUY',
    order_id: 'taker-1',
    user_id: 'taker',
    quantity: 50_000_000,
    price_cap: 3_100_000
  )
end

count    = ENV.fetch('COUNT', '100').to_i
block_ms = ENV.fetch('BLOCK_MS', '2000').to_i

File.open(output_path, 'a') do |f|
  loop do
    entries = consumer.read(count: count, block_ms: block_ms)
    next if entries.empty?

    entries.each do |e|
      fields = e.fields
      record = {
        stream_entry_id: e.id,
        symbol: fields['symbol'],
        taker_side: fields['taker_side'],
        price: fields['price'].to_i,
        quantity: fields['quantity'].to_i,
        quote: fields['quote'].to_i,
        maker_fee: fields['maker_fee'].to_i,
        taker_fee: fields['taker_fee'].to_i,
        maker_order_id: fields['maker_order_id'],
        taker_order_id: fields['taker_order_id'],
        buy_order_id: fields['buy_order_id'],
        sell_order_id: fields['sell_order_id'],
        executed_ts_ms: fields['ts'].to_i
      }

      line = JSON.generate(record)
      f.puts(line)
      f.flush
      puts "[TRADE] #{line}"

      consumer.ack(e.id)
    rescue StandardError => err
      warn "[ERROR] failed to persist/ack trade #{e.id}: #{err.message}"
      # On error, do not ack; pending entries will be retried/claimed later
    end
  end
end