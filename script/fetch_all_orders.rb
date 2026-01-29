#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/redis_exchange'

redis = Redis.new(url: ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0')
exchange = RedisExchange::Client.new(redis: redis)

symbol = ARGV[0] || 'BTCUSDT'

puts "Fetching all active orders for #{symbol}..."
orders = exchange.market_active_orders(symbol: symbol)

if orders.empty?
  puts "No active orders found for #{symbol}."
else
  puts "Found #{orders.size} active orders:"
  orders.each do |o|
    puts "  [#{o[:side]}] ID: #{o[:order_id]}, Price: #{o[:price]}, Qty: #{o[:quantity]}, User: #{o[:user_id]}"
  end
end
