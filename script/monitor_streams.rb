#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/redis_exchange'
require_relative '../lib/redis_exchange/ledger_stream_consumer'
require_relative '../lib/redis_exchange/order_stream_consumer'
require_relative '../lib/redis_exchange/trade_stream_consumer'

redis = Redis.new(url: ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0')
exchange = RedisExchange::Client.new(redis: redis)

puts "=== Stream Monitor ==="
puts "Time: #{Time.now}"
puts

# 1. Account Ledger (Global)
ledger_group = 'monitor_group'
ledger_consumer_name = "monitor-#{Process.pid}"
ledger = RedisExchange::LedgerStreamConsumer.new(
  redis: redis,
  group: ledger_group,
  consumer: ledger_consumer_name
)

# Ensure group exists (read-only monitoring might want to avoid creating groups, 
# but XINFO requires the group to exist to show lag for IT. 
# Here we just check if it exists or use XINFO STREAM directly for global length)

# Check Ledger Stream Length
begin
  len = redis.xlen('account_ledger')
  puts "Stream: account_ledger"
  puts "  Total Length: #{len}"
  
  # List all groups
  groups = redis.xinfo(:groups, 'account_ledger') rescue []
  if groups.empty?
    puts "  No consumer groups found."
  else
    puts "  Consumer Groups:"
    groups.each do |g|
      puts "    - Name: #{g['name']}"
      puts "      Pending (Un-ACKed): #{g['pending']}"
      puts "      Lag (Backlog): #{g['lag'] || '0'}"
    end
  end
rescue Redis::CommandError => e
  puts "Stream: account_ledger - #{e.message}"
end
puts "-" * 40

# 2. Market Streams
markets = []
redis.scan_each(match: 'market:*') do |key|
  markets << key.sub('market:', '')
end

markets.each do |symbol|
  puts "Market: #{symbol}"
  
  ['orders', 'trades'].each do |type|
    stream_key = "#{type}:#{symbol}"
    begin
      len = redis.xlen(stream_key)
      puts "  Stream: #{stream_key}"
      puts "    Total Length: #{len}"
      
      groups = redis.xinfo(:groups, stream_key) rescue []
      if groups.empty?
        puts "    No consumer groups found."
      else
        puts "    Consumer Groups:"
        groups.each do |g|
          puts "      - Name: #{g['name']}"
          puts "        Pending (Un-ACKed): #{g['pending']}"
          puts "        Lag (Backlog): #{g['lag'] || '0'}"
        end
      end
    rescue Redis::CommandError => e
      puts "  Stream: #{stream_key} - #{e.message} (Empty or not initialized)"
    end
  end
  puts "-" * 40
end
