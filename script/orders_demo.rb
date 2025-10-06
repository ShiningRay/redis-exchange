#!/usr/bin/env ruby
# frozen_string_literal: true

# Demo: Consume order events from Redis Streams and persist to local file
# Usage:
#   bundle exec ruby script/orders_demo.rb
#   # Environment overrides:
#   # REDIS_URL=redis://127.0.0.1:6379/0 SYMBOL=BTCUSDT GROUP=orders-consumers CONSUMER=demo-1 OUTPUT=tmp/orders_demo.log bundle exec ruby script/orders_demo.rb
#   # Seed a sample flow:
#   # SEED=1 bundle exec ruby script/orders_demo.rb

require 'json'
require 'redis'
require 'socket'
require 'fileutils'
require_relative '../lib/redis_exchange'

redis_url   = ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379/0')
symbol      = ENV.fetch('SYMBOL', 'BTCUSDT')
group       = ENV.fetch('GROUP', 'orders-consumers')
consumer_id = ENV.fetch('CONSUMER', "demo-#{Socket.gethostname rescue 'local'}")
output_path = ENV.fetch('OUTPUT', File.join(__dir__, '..', 'tmp', 'orders_demo.log'))

redis    = Redis.new(url: redis_url)
exchange = RedisExchange::Client.new(redis: redis)
consumer = exchange.order_consumer(symbol: symbol, group: group, consumer: consumer_id)

FileUtils.mkdir_p(File.dirname(output_path))
puts "[START] Order consumer for #{symbol} group=#{group} consumer=#{consumer_id} output=#{output_path}"

trap 'INT' do
  puts "\n[STOP] Shutting down consumer..."
  begin
    redis.close if redis.respond_to?(:close)
  rescue StandardError
  end
  exit 0
end

# Optional: seed a sample order/cancel/match flow for the demo
if ENV['SEED'] == '1'
  puts '[SEED] Seeding market and generating sample order events...'
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

  exchange.set_balance(user_id: 'demo-maker', asset: 'BTC', available: 100_000_000)
  exchange.place_limit_order(
    symbol: symbol,
    side: 'SELL',
    order_id: 'demo-sell-1',
    user_id: 'demo-maker',
    price: 3_000_000,
    quantity: 50_000_000
  )

  exchange.cancel_order('demo-sell-1')
end

File.open(output_path, 'a') do |f|
  consumer.each(count: 100, block_ms: 2000, auto_ack: true) do |e|
    fields = e.fields
    record = {
      stream_entry_id: e.id,
      symbol: fields['symbol'],
      order_id: fields['order_id'],
      user_id: fields['user_id'],
      side: fields['side'],
      type: fields['type'],
      status: fields['status'],
      price: fields['price'].to_i,
      quantity: fields['quantity'].to_i,
      remaining: fields['remaining'].to_i,
      sequence: fields['sequence'].to_i,
      ts_ms: fields['ts'].to_i
    }

    line = JSON.generate(record)
    f.puts(line)
    f.flush
    puts "[ORDER] #{line}"

    # auto_ack: true will ack if block succeeds
  rescue StandardError => err
    warn "[ERROR] failed to persist order #{e.id}: #{err.message}"
    # On error, do not ack; pending entries will be retried/claimed later
  end
end