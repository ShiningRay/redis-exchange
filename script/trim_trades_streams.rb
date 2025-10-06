#!/usr/bin/env ruby
# frozen_string_literal: true

# Trim trades streams (`trades:{symbol}`) by time window using XTRIM MINID.
# Safety: computes lower bound based on pending entries across groups if requested.
# Usage examples:
#   bundle exec ruby script/trim_trades_streams.rb --symbols BTCUSDT,ETHUSDT --retain-days 7
#   bundle exec ruby script/trim_trades_streams.rb --symbols BTCUSDT --retain-ms 604800000 --respect-pending

require 'optparse'
require 'redis'

options = {
  redis_url: ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0',
  symbols: [],
  retain_ms: nil,
  retain_days: 7,
  respect_pending: true,
  groups: ['trades-consumers']
}

OptionParser.new do |parser|
  parser.banner = 'Usage: ruby script/trim_trades_streams.rb [options]'
  parser.on('--redis-url=URL', 'Redis URL (default: REDIS_URL or local)') { |v| options[:redis_url] = v }
  parser.on('--symbols=LIST', 'Comma-separated symbols (e.g., BTCUSDT,ETHUSDT)') { |v| options[:symbols] = v.split(',').map(&:strip) }
  parser.on('--retain-days=N', Integer, 'Retention in days (default: 7)') { |v| options[:retain_days] = v }
  parser.on('--retain-ms=N', Integer, 'Retention in milliseconds (overrides retain-days)') { |v| options[:retain_ms] = v }
  parser.on('--respect-pending', 'Do not trim earlier than min pending id across groups') { options[:respect_pending] = true }
  parser.on('--ignore-pending', 'Ignore pending entries when trimming') { options[:respect_pending] = false }
  parser.on('--groups=LIST', 'Comma-separated consumer groups to inspect for pending (default: trades-consumers)') { |v| options[:groups] = v.split(',').map(&:strip) }
end.parse!

if options[:symbols].empty?
  abort 'ERROR: --symbols is required'
end

retain_ms = options[:retain_ms] || (options[:retain_days].to_i * 86_400_000)
cutoff_ms = (Time.now.to_f * 1000).to_i - retain_ms
cutoff_id = format('%d-0', cutoff_ms)

redis = Redis.new(url: options[:redis_url])

def min_pending_id(redis, stream_key, groups)
  ids = []
  groups.each do |group|
    begin
      summary = redis.xpending(stream_key, group)
      # summary: [pending_count, smallest_id, greatest_id, consumers]
      if summary.is_a?(Array) && summary[1].is_a?(String)
        ids << summary[1]
      elsif summary.is_a?(Hash) && summary['smallest_entry_id']
        ids << summary['smallest_entry_id']
      end
    rescue StandardError
      # group may not exist; ignore
    end
  end
  return nil if ids.empty?
  ids.min
end

options[:symbols].each do |symbol|
  stream_key = "trades:#{symbol}"
  safe_id = cutoff_id
  if options[:respect_pending]
    pending_id = min_pending_id(redis, stream_key, options[:groups])
    safe_id = [cutoff_id, pending_id].compact.max # do not cut below earliest pending
  end
  begin
    trimmed = redis.xtrim(stream_key, 'MINID', safe_id)
    puts "[TRIM] #{stream_key} MINID #{safe_id} -> trimmed=#{trimmed}"
  rescue => e
    warn "[ERROR] trim failed for #{stream_key}: #{e.message}"
  end
end

begin
  redis.close if redis.respond_to?(:close)
rescue StandardError
end