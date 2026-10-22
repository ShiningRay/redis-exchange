#!/usr/bin/env ruby
# frozen_string_literal: true

# Prints detailed market configuration for one or more symbols.
#
# Usage:
#   ruby script/market_info.rb BTCUSDT
#   ruby script/market_info.rb BTCUSDT ETHUSDT
#   ruby script/market_info.rb --redis-url redis://127.0.0.1:6379/0 BTCUSDT

require 'bundler/setup'
require 'optparse'
require 'redis'
require 'redis_exchange'
require 'json'

options = {
  redis_url: ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0'
}

OptionParser.new do |opts|
  opts.banner = 'Usage: ruby script/market_info.rb [options] SYMBOL [SYMBOL ...]'

  opts.on('--redis-url URL', "Redis URL (default: ENV['REDIS_URL'] or local)") do |v|
    options[:redis_url] = v
  end
  opts.on('-h', '--help', 'Show this help message') do
    puts opts
    exit
  end
end.parse!

symbols = ARGV.map { |s| s.strip.upcase }.reject(&:empty?)
abort '[market_info] At least one SYMBOL is required' if symbols.empty?

redis = Redis.new(url: options[:redis_url])
begin
  redis.ping
rescue StandardError => e
  abort "[market_info] Failed to connect to Redis at #{options[:redis_url]}: #{e.message}"
end

client = RedisExchange::Client.new(redis: redis)

symbols.each do |symbol|
  cfg = client.market_config(symbol)
  if cfg.empty?
    puts "#{symbol}: NOT_FOUND"
    next
  end

  puts "#{symbol}:"
  puts "  base_asset:              #{cfg[:base_asset]}"
  puts "  quote_asset:             #{cfg[:quote_asset]}"
  puts "  price_scale:             #{cfg[:price_scale]}"
  puts "  quantity_scale:          #{cfg[:quantity_scale]}"
  puts "  maker_fee_bps:           #{cfg[:maker_fee_bps]}"
  puts "  taker_fee_bps:           #{cfg[:taker_fee_bps]}"
  puts "  min_qty:                 #{cfg[:min_qty]}"
  puts "  min_notional:            #{cfg[:min_notional]}"
  puts "  status:                  #{cfg[:status]}"
  puts "  trades_maxlen:           #{cfg[:trades_maxlen]}"
  puts "  orders_maxlen:           #{cfg[:orders_maxlen]}"
  puts "  order_tombstone_ttl_sec: #{cfg[:order_tombstone_ttl_sec]}"
  puts
end
