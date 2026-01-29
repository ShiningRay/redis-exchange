#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/redis_exchange'
require_relative '../lib/redis_exchange/stream_consumer'

if ARGV.length < 2
  puts "Usage: ruby script/reset_consumer_offset.rb <STREAM_KEY> <GROUP_NAME> [OFFSET]"
  puts "  OFFSET: '0' (default) for beginning, '$' for end, or specific ID"
  puts "Example: ruby script/reset_consumer_offset.rb orders:BTCUSDT orders-consumers 0"
  exit 1
end

stream_key = ARGV[0]
group_name = ARGV[1]
offset = ARGV[2] || '0'

redis = Redis.new(url: ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0')

puts "Resetting offset for group '#{group_name}' on stream '#{stream_key}' to '#{offset}'..."

begin
  # Check if stream exists first
  unless redis.exists(stream_key) > 0
    puts "Warning: Stream '#{stream_key}' does not exist."
  end

  # We use StreamConsumer directly to leverage the new method
  # Note: consumer name doesn't matter for resetting offset, just need a placeholder
  consumer = RedisExchange::StreamConsumer.new(
    redis: redis,
    stream_key: stream_key,
    group: group_name,
    consumer: 'temp-admin'
  )
  
  consumer.reset_offset(id: offset)
  puts "Success! Group '#{group_name}' is now at offset '#{offset}'."
rescue Redis::CommandError => e
  puts "Error: #{e.message}"
  exit 1
end
