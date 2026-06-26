#!/usr/bin/env ruby
# frozen_string_literal: true

# Renames an asset code in Redis (e.g. BTC -> XBT).
#
# WARNING:
# - This mutates underlying Redis data. Run with --dry first (the default).
# - Historical stream entries (account_ledger, trades:{symbol}) CANNOT be renamed.
#   Downstream consumers must handle old_asset -> new_asset mapping if needed.
# - Active orders in markets that reference the old asset must be cancelled first.
#
# Usage:
#   ruby script/rename_asset.rb --old-asset BTC --new-asset XBT --dry
#   ruby script/rename_asset.rb --old-asset BTC --new-asset XBT --execute
#
# Affected Redis keys/fields:
#   asset:{old}                     -> asset:{new}
#   market:{symbol}.base_asset      -> updated if == old
#   market:{symbol}.quote_asset     -> updated if == old
#   balance:{user_id}.{old}:available -> {new}:available
#   balance:{user_id}.{old}:reserved  -> {new}:reserved
#   fees:{old}                      -> fees:{new}
#   ledger_seq:{user_id}:{old}      -> ledger_seq:{user_id}:{new}

require 'bundler/setup'
require 'optparse'
require 'redis'
require 'redis_exchange'

options = {
  redis_url: ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0',
  dry_run: true,
  cancel_orders: false,
  skip_ledger_seq: false,
  force: false,
  count: 1000
}

OptionParser.new do |opts|
  opts.banner = 'Rename an asset code in Redis'

  opts.on('--old-asset ASSET', 'Current asset code (e.g. BTC)') do |v|
    options[:old_asset] = v.to_s.strip.upcase
  end
  opts.on('--new-asset ASSET', 'New asset code (e.g. XBT)') do |v|
    options[:new_asset] = v.to_s.strip.upcase
  end
  opts.on('--redis-url URL', "Redis URL (default: ENV['REDIS_URL'] or local)") do |v|
    options[:redis_url] = v
  end
  opts.on('--execute', 'Actually perform the rename (default is dry-run)') do
    options[:dry_run] = false
  end
  opts.on('--cancel-orders', 'Automatically cancel active orders in affected markets') do
    options[:cancel_orders] = true
  end
  opts.on('--skip-ledger-seq', 'Do not rename ledger_seq:{user_id}:{old} keys') do
    options[:skip_ledger_seq] = true
  end
  opts.on('--force', 'Allow overwriting an existing new asset config') do
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

abort '[rename_asset] --old-asset is required' if options[:old_asset].nil? || options[:old_asset].empty?
abort '[rename_asset] --new-asset is required' if options[:new_asset].nil? || options[:new_asset].empty?
abort '[rename_asset] old and new asset codes must be different' if options[:old_asset] == options[:new_asset]

old_asset = options[:old_asset]
new_asset = options[:new_asset]
dry_run = options[:dry_run]

redis = Redis.new(url: options[:redis_url])
begin
  redis.ping
rescue StandardError => e
  abort "[rename_asset] Failed to connect to Redis at #{options[:redis_url]}: #{e.message}"
end

client = RedisExchange::Client.new(redis: redis)

puts "[rename_asset] Mode: #{dry_run ? 'DRY RUN' : 'EXECUTE'}"
puts "[rename_asset] Renaming #{old_asset} -> #{new_asset}"

# 1. Validate old asset exists
old_config = client.asset_config(old_asset)
abort "[rename_asset] Asset config not found: asset:#{old_asset}" if old_config.empty?

# 2. Validate new asset does not exist (unless --force)
unless options[:force]
  new_config = client.asset_config(new_asset)
  abort "[rename_asset] Asset config already exists: asset:#{new_asset} (use --force to overwrite)" unless new_config.empty?
end

# 3. Find markets referencing the old asset
affected_markets = []
market_scanned = 0
redis.scan_each(match: 'market:*', count: options[:count]) do |key|
  market_scanned += 1
  symbol = key.sub('market:', '')
  cfg = client.market_config(symbol)
  if cfg[:base_asset] == old_asset || cfg[:quote_asset] == old_asset
    affected_markets << symbol
  end
end
puts "[rename_asset] Scanned #{market_scanned} market key(s), found #{affected_markets.size} affected"

puts "[rename_asset] Affected markets: #{affected_markets.empty? ? 'none' : affected_markets.join(', ')}"

# 4. Check for active orders in affected markets
active_orders = []
affected_markets.each do |symbol|
  client.market_active_orders(symbol: symbol).each do |order|
    active_orders << { order_id: order[:order_id], symbol: symbol, user_id: order[:user_id] }
  end
end

unless active_orders.empty?
  puts "[rename_asset] Found #{active_orders.size} active order(s) in affected markets:"
  active_orders.first(10).each { |o| puts "  - #{o[:order_id]} (#{o[:symbol]}, user=#{o[:user_id]})" }
  puts '  ...' if active_orders.size > 10

  if options[:cancel_orders]
    puts '[rename_asset] Cancelling active orders...'
    unless dry_run
      active_orders.each do |o|
        res = client.maintenance.force_cancel_order(order_id: o[:order_id], mode: :best_effort_unlock)
        if res[:error]
          abort "[rename_asset] Failed to cancel order #{o[:order_id]}: #{res[:error]}"
        end
      end
      puts "[rename_asset] Cancelled #{active_orders.size} order(s)"
    end
  else
    abort '[rename_asset] Please cancel all active orders first, or re-run with --cancel-orders'
  end
end

# 5. Build migration plan
plan = {
  asset_config: { from: "asset:#{old_asset}", to: "asset:#{new_asset}" },
  markets: affected_markets,
  balance_users: [],
  fee_key: { from: "fees:#{old_asset}", to: "fees:#{new_asset}" },
  ledger_seq_keys: []
}

balance_scanned = 0
redis.scan_each(match: 'balance:*', count: options[:count]) do |key|
  balance_scanned += 1
  if redis.hexists(key, "#{old_asset}:available") || redis.hexists(key, "#{old_asset}:reserved")
    user_id = key.sub('balance:', '')
    plan[:balance_users] << user_id
  end
  if (balance_scanned % 10_000).zero?
    puts "[rename_asset] Scanned #{balance_scanned} balance key(s), matched #{plan[:balance_users].size} user(s)..."
  end
end
puts "[rename_asset] Scanned #{balance_scanned} balance key(s), matched #{plan[:balance_users].size} user(s)"

if redis.exists?("fees:#{old_asset}")
  plan[:fee_key][:exists] = true
end

ledger_scanned = 0
unless options[:skip_ledger_seq]
  redis.scan_each(match: "ledger_seq:*:#{old_asset}", count: options[:count]) do |key|
    ledger_scanned += 1
    plan[:ledger_seq_keys] << key
  end
end
puts "[rename_asset] Scanned #{ledger_scanned} ledger_seq key(s), matched #{plan[:ledger_seq_keys].size}"

puts '[rename_asset] Migration plan:'
puts "  - Asset config: asset:#{old_asset} -> asset:#{new_asset}"
puts "  - Markets to update: #{affected_markets.size}"
puts "  - User balances to update: #{plan[:balance_users].size}"
puts "  - Fees key to rename: #{plan[:fee_key][:exists] ? 'yes' : 'no'}"
puts "  - Ledger seq keys to rename: #{plan[:ledger_seq_keys].size}"

if dry_run
  puts '[rename_asset] Dry run complete. Re-run with --execute to apply changes.'
  exit 0
end

# 6. Enter maintenance mode
puts '[rename_asset] Enabling system maintenance mode...'
client.maintenance.enable

begin
  # 6.1 Migrate asset config
  puts '[rename_asset] Migrating asset config...'
  redis.hset("asset:#{new_asset}", old_config.transform_keys(&:to_s).transform_values(&:to_s))
  redis.del("asset:#{old_asset}")

  # 6.2 Update affected markets
  unless affected_markets.empty?
    puts '[rename_asset] Updating market configs...'
    affected_markets.each do |symbol|
      cfg = client.market_config(symbol)
      updates = {}
      updates['base_asset'] = new_asset if cfg[:base_asset] == old_asset
      updates['quote_asset'] = new_asset if cfg[:quote_asset] == old_asset
      redis.hset("market:#{symbol}", updates) unless updates.empty?
    end
  end

  # 6.3 Migrate user balances
  unless plan[:balance_users].empty?
    puts '[rename_asset] Migrating user balances...'
    plan[:balance_users].each_with_index do |user_id, idx|
      key = "balance:#{user_id}"
      avail = redis.hget(key, "#{old_asset}:available").to_i
      resv = redis.hget(key, "#{old_asset}:reserved").to_i

      redis.pipelined do |p|
        p.hset(key, "#{new_asset}:available", avail, "#{new_asset}:reserved", resv)
        p.hdel(key, "#{old_asset}:available", "#{old_asset}:reserved")
      end

      if ((idx + 1) % 1000).zero?
        puts "[rename_asset] Migrated #{idx + 1}/#{plan[:balance_users].size} user balances..."
      end
    end
    puts "[rename_asset] Migrated #{plan[:balance_users].size} user balance(s)"
  end

  # 6.4 Rename fees key
  if plan[:fee_key][:exists]
    puts '[rename_asset] Renaming fees key...'
    redis.rename("fees:#{old_asset}", "fees:#{new_asset}")
  end

  # 6.5 Rename ledger_seq keys
  unless options[:skip_ledger_seq] || plan[:ledger_seq_keys].empty?
    puts '[rename_asset] Renaming ledger_seq keys...'
    plan[:ledger_seq_keys].each_with_index do |old_key, idx|
      new_key = old_key.sub(/:#{old_asset}$/, ":#{new_asset}")
      redis.rename(old_key, new_key)
      if ((idx + 1) % 1000).zero?
        puts "[rename_asset] Renamed #{idx + 1}/#{plan[:ledger_seq_keys].size} ledger_seq keys..."
      end
    end
    puts "[rename_asset] Renamed #{plan[:ledger_seq_keys].size} ledger_seq key(s)"
  end

  puts '[rename_asset] Rename complete.'

  # 7. Run balance audit for affected users
  unless plan[:balance_users].empty?
    puts '[rename_asset] Running balance audit...'
    plan[:balance_users].each_with_index do |user_id, idx|
      reports = client.maintenance.audit_user_balances(user_id: user_id, fix: true)
      reports.each do |r|
        puts "  [audit] user=#{r[:user_id]} deficits=#{r[:deficits].size} fixes=#{r[:fixes].size}"
      end
      if ((idx + 1) % 100).zero?
        puts "[rename_asset] Audited #{idx + 1}/#{plan[:balance_users].size} user(s)..."
      end
    end
    puts "[rename_asset] Audited #{plan[:balance_users].size} user(s)"
  end
ensure
  puts '[rename_asset] Disabling system maintenance mode...'
  client.maintenance.disable
end

puts "[rename_asset] #{old_asset} has been renamed to #{new_asset}."
puts '[rename_asset] NOTE: Historical account_ledger and trades:{symbol} stream entries still reference the old asset code.'
