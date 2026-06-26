#!/usr/bin/env ruby
# frozen_string_literal: true

# Renames a market symbol in Redis (e.g. BTCUSDT -> XBTUSDT).
#
# WARNING:
# - This mutates underlying Redis data. Run with --dry first (the default).
# - All active orders for the old symbol are migrated to the new symbol.
# - Historical trades/orders streams are renamed by default, preserving history.
#   Use --reset-streams if you want fresh empty streams for the new symbol.
# - This is a maintenance operation: the old market is placed under MAINTENANCE
#   mode during the rename.
#
# Usage:
#   ruby script/rename_market.rb --old-symbol BTCUSDT --new-symbol XBTUSDT --dry
#   ruby script/rename_market.rb --old-symbol BTCUSDT --new-symbol XBTUSDT --execute
#
# Affected Redis keys (examples for BTCUSDT -> XBTUSDT):
#   market:BTCUSDT                       -> market:XBTUSDT
#   book:BTCUSDT:BUY / SELL              -> book:XBTUSDT:BUY / SELL
#   volume:BTCUSDT:BUY / SELL            -> volume:XBTUSDT:BUY / SELL
#   queue:BTCUSDT:BUY/SELL:{price}       -> queue:XBTUSDT:BUY/SELL:{price}
#   seq:BTCUSDT                          -> seq:XBTUSDT
#   ticker:BTCUSDT                       -> ticker:XBTUSDT
#   trades:BTCUSDT                       -> trades:XBTUSDT   (or reset)
#   orders:BTCUSDT                       -> orders:XBTUSDT   (or reset)
#   user_orders:{user_id}:BTCUSDT        -> user_orders:{user_id}:XBTUSDT
#   order:{order_id}.symbol              -> "XBTUSDT"

require 'bundler/setup'
require 'optparse'
require 'redis'
require 'redis_exchange'

options = {
  redis_url: ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0',
  dry_run: true,
  cancel_orders: false,
  reset_streams: false,
  force: false,
  count: 1000
}

OptionParser.new do |opts|
  opts.banner = 'Rename a market symbol in Redis'

  opts.on('--old-symbol SYMBOL', 'Current market symbol (e.g. BTCUSDT)') do |v|
    options[:old_symbol] = v.to_s.strip.upcase
  end
  opts.on('--new-symbol SYMBOL', 'New market symbol (e.g. XBTUSDT)') do |v|
    options[:new_symbol] = v.to_s.strip.upcase
  end
  opts.on('--redis-url URL', "Redis URL (default: ENV['REDIS_URL'] or local)") do |v|
    options[:redis_url] = v
  end
  opts.on('--execute', 'Actually perform the rename (default is dry-run)') do
    options[:dry_run] = false
  end
  opts.on('--cancel-orders', 'Automatically cancel active orders before rename') do
    options[:cancel_orders] = true
  end
  opts.on('--reset-streams', 'Create fresh empty trades/orders streams for the new symbol') do
    options[:reset_streams] = true
  end
  opts.on('--force', 'Allow overwriting an existing new market config') do
    options[:force] = true
  end
  opts.on('--count=N', Integer, 'SCAN count hint for key iteration (default: 1000)') do |v|
    options[:count] = v.positive? ? v : 1000
  end
  opts.on('-h', '--help', 'Show this help message') do
    puts opts
    exit
  end
end.parse!

abort '[rename_market] --old-symbol is required' if options[:old_symbol].nil? || options[:old_symbol].empty?
abort '[rename_market] --new-symbol is required' if options[:new_symbol].nil? || options[:new_symbol].empty?
abort '[rename_market] old and new symbols must be different' if options[:old_symbol] == options[:new_symbol]

old_symbol = options[:old_symbol]
new_symbol = options[:new_symbol]
dry_run = options[:dry_run]

redis = Redis.new(url: options[:redis_url])
begin
  redis.ping
rescue StandardError => e
  abort "[rename_market] Failed to connect to Redis at #{options[:redis_url]}: #{e.message}"
end

client = RedisExchange::Client.new(redis: redis)

puts "[rename_market] Mode: #{dry_run ? 'DRY RUN' : 'EXECUTE'}"
puts "[rename_market] Renaming market #{old_symbol} -> #{new_symbol}"

# 1. Validate old market exists
old_market_key = "market:#{old_symbol}"
old_config = client.market_config(old_symbol)
abort "[rename_market] Market not found: #{old_market_key}" if old_config.empty?

# 2. Validate new market does not exist (unless --force)
new_market_key = "market:#{new_symbol}"
unless options[:force]
  abort "[rename_market] Market already exists: #{new_market_key}" if redis.exists?(new_market_key)
end

# 3. Check for active orders
active_orders = client.market_active_orders(symbol: old_symbol)

unless active_orders.empty?
  puts "[rename_market] Found #{active_orders.size} active order(s) for #{old_symbol}:"
  active_orders.first(10).each { |o| puts "  - #{o[:order_id]} (user=#{o[:user_id]})" }
  puts '  ...' if active_orders.size > 10

  if options[:cancel_orders]
    puts '[rename_market] Cancelling active orders before rename...'
    unless dry_run
      active_orders.each do |o|
        res = client.maintenance.force_cancel_order(order_id: o[:order_id], mode: :best_effort_unlock)
        abort "[rename_market] Failed to cancel order #{o[:order_id]}: #{res[:error]}" if res[:error]
      end
      puts "[rename_market] Cancelled #{active_orders.size} order(s)"
    end
  else
    puts '[rename_market] Active orders will be migrated to the new symbol.'
  end
end

# 4. Gather user order indexes
user_order_indexes = []
index_scanned = 0
redis.scan_each(match: "user_orders:*:#{old_symbol}", count: options[:count]) do |key|
  user_order_indexes << key
  index_scanned += 1
  if (index_scanned % 10_000).zero?
    puts "[rename_market] Scanned #{index_scanned} user_order index key(s), matched #{user_order_indexes.size}..."
  end
end
puts "[rename_market] Scanned #{index_scanned} user_order index key(s), matched #{user_order_indexes.size}"

puts "[rename_market] Migration plan:"
puts "  - Market config: #{old_market_key} -> #{new_market_key}"
puts "  - Order book keys: book/volume/queue/seq/ticker"
puts "  - User order indexes: #{user_order_indexes.size}"
puts "  - Active orders: #{active_orders.size} (#{options[:cancel_orders] ? 'will be cancelled' : 'will be migrated'})"
puts "  - Trades/orders stream: #{options[:reset_streams] ? 'reset to empty' : 'rename preserving history'}"

if dry_run
  puts '[rename_market] Dry run complete. Re-run with --execute to apply changes.'
  exit 0
end

# 5. Enter maintenance mode
puts "[rename_market] Setting #{old_symbol} to MAINTENANCE..."
client.maintenance.enable_market(old_symbol)

begin
  # 6. Rename simple keys
  simple_key_pairs = [
    ["book:#{old_symbol}:BUY", "book:#{new_symbol}:BUY"],
    ["book:#{old_symbol}:SELL", "book:#{new_symbol}:SELL"],
    ["volume:#{old_symbol}:BUY", "volume:#{new_symbol}:BUY"],
    ["volume:#{old_symbol}:SELL", "volume:#{new_symbol}:SELL"],
    ["seq:#{old_symbol}", "seq:#{new_symbol}"],
    ["ticker:#{old_symbol}", "ticker:#{new_symbol}"]
  ]

  simple_key_pairs.each do |old_key, new_key|
    if redis.exists?(old_key)
      puts "[rename_market] Renaming #{old_key} -> #{new_key}"
      redis.rename(old_key, new_key)
    end
  end

  # 7. Rename queue keys for each price level
  [RedisExchange::SIDE_BUY, RedisExchange::SIDE_SELL].each do |side|
    book_key = "book:#{new_symbol}:#{side}"
    prices = redis.zrange(book_key, 0, -1)
    prices.each do |price|
      old_queue = "queue:#{old_symbol}:#{side}:#{price}"
      new_queue = "queue:#{new_symbol}:#{side}:#{price}"
      if redis.exists?(old_queue)
        puts "[rename_market] Renaming #{old_queue} -> #{new_queue}"
        redis.rename(old_queue, new_queue)
      end
    end

    # Clean up any orphan old queues (just in case)
    orphan_scanned = 0
    redis.scan_each(match: "queue:#{old_symbol}:#{side}:*", count: options[:count]) do |old_queue|
      orphan_scanned += 1
      new_queue = old_queue.sub("queue:#{old_symbol}:#{side}:", "queue:#{new_symbol}:#{side}:")
      puts "[rename_market] Renaming orphan #{old_queue} -> #{new_queue}"
      redis.rename(old_queue, new_queue)
    end
    puts "[rename_market] Renamed #{orphan_scanned} orphan queue key(s) on #{side}" if orphan_scanned.positive?
  end

  # 8. Update symbol field in all order hashes referenced by user order indexes
  migrated_orders = 0
  user_order_indexes.each_with_index do |old_index, idx|
    order_ids = redis.zrange(old_index, 0, -1)
    order_ids.each do |order_id|
      order_key = "order:#{order_id}"
      if redis.hexists(order_key, 'symbol')
        redis.hset(order_key, 'symbol', new_symbol)
        migrated_orders += 1
      end
    end

    # Rename the index key itself. Format: user_orders:{user_id}:{symbol}
    user_id = old_index.split(':')[1]
    new_index = "user_orders:#{user_id}:#{new_symbol}"
    redis.rename(old_index, new_index)

    if ((idx + 1) % 1000).zero?
      puts "[rename_market] Migrated #{idx + 1}/#{user_order_indexes.size} user order indexes..."
    end
  end
  puts "[rename_market] Updated #{migrated_orders} order hash(es) across #{user_order_indexes.size} user index(es)"

  # 9. Rename or reset streams
  trades_old = "trades:#{old_symbol}"
  trades_new = "trades:#{new_symbol}"
  orders_old = "orders:#{old_symbol}"
  orders_new = "orders:#{new_symbol}"

  if options[:reset_streams]
    puts "[rename_market] Resetting streams for new symbol (old streams preserved)"
    redis.del(trades_new)
    redis.del(orders_new)
    # Lua will recreate the streams on the next XADD with MAXLEN from market config.
  else
    if redis.exists?(trades_old)
      puts "[rename_market] Renaming #{trades_old} -> #{trades_new}"
      redis.rename(trades_old, trades_new)
    end
    if redis.exists?(orders_old)
      puts "[rename_market] Renaming #{orders_old} -> #{orders_new}"
      redis.rename(orders_old, orders_new)
    end
  end

  # 10. Create new market config and delete old one
  puts "[rename_market] Creating #{new_market_key}..."
  mapping = {
    'base_asset' => old_config[:base_asset],
    'quote_asset' => old_config[:quote_asset],
    'price_scale' => old_config[:price_scale],
    'quantity_scale' => old_config[:quantity_scale],
    'maker_fee_bps' => old_config[:maker_fee_bps],
    'taker_fee_bps' => old_config[:taker_fee_bps],
    'min_qty' => old_config[:min_qty],
    'min_notional' => old_config[:min_notional],
    'status' => RedisExchange::MARKET_STATUS_OPEN
  }
  redis.hset(new_market_key, mapping)
  redis.del(old_market_key)

  puts "[rename_market] Rename complete."

  # 11. Audit affected users
  affected_users = user_order_indexes.map { |k| k.split(':')[1] }.uniq
  unless affected_users.empty?
    puts '[rename_market] Running balance audit for affected users...'
    affected_users.each_with_index do |user_id, idx|
      reports = client.maintenance.audit_user_balances(user_id: user_id, fix: true)
      reports.each do |r|
        puts "  [audit] user=#{r[:user_id]} deficits=#{r[:deficits].size} fixes=#{r[:fixes].size}"
      end
      if ((idx + 1) % 100).zero?
        puts "[rename_market] Audited #{idx + 1}/#{affected_users.size} user(s)..."
      end
    end
    puts "[rename_market] Audited #{affected_users.size} user(s)"
  end
ensure
  # Always try to restore new market to OPEN and old market no longer exists
  puts "[rename_market] Restoring market status..."
  client.maintenance.disable_market(new_symbol) if redis.exists?(new_market_key)
end

puts "[rename_market] #{old_symbol} has been renamed to #{new_symbol}."
puts '[rename_market] NOTE: Historical ledger entries (account_ledger) still reference the old market symbol if any exist.'
