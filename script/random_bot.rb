#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'json'
require 'securerandom'
require 'redis'
require 'bigdecimal'
require_relative '../lib/redis_exchange'

# Random trading bot: performs random add_funds/sub_funds, limit & market orders,
# with random waits between operations and prints every result.
#
# Usage:
#   ruby script/random_bot.rb [--redis-url redis://127.0.0.1:6379/0] \
#     [--symbol BTCUSDT] [--iterations 100] [--sleep-min 0.2] [--sleep-max 1.5] \
#     [--users alice,bob,charlie] [--flush] [--no-seed] [--quiet]
#
# Notes:
# - Seeds BTC/USDT assets and BTCUSDT market by default unless --no-seed.
# - Uses price_scale=100 and quantity_scale=100_000_000 (1 BTC = 100_000_000 minor units).
# - Keeps operations within safe precision bounds.

options = {
  redis_url: ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0',
  symbol: 'BTCUSDT',
  iterations: 100,
  sleep_min: 0.2,
  sleep_max: 1.5,
  users: %w[alice bob charlie],
  flush: false,
  seed: true,
  color: true,
  quiet: false
}

OptionParser.new do |opts|
  opts.banner = 'Random trading bot options'
  opts.on('--redis-url URL', 'Redis URL (default: ENV REDIS_URL or local)') { |v| options[:redis_url] = v }
  opts.on('--symbol SYMBOL', 'Market symbol (default: BTCUSDT)') { |v| options[:symbol] = v }
  opts.on('--iterations N', Integer, 'Number of operations to perform (default: 100)') { |v| options[:iterations] = v }
  opts.on('--sleep-min SECONDS', Float, 'Minimum sleep seconds between operations') { |v| options[:sleep_min] = v }
  opts.on('--sleep-max SECONDS', Float, 'Maximum sleep seconds between operations') { |v| options[:sleep_max] = v }
  opts.on('--users LIST', 'Comma-separated user ids (default: alice,bob,charlie)') { |v| options[:users] = v.split(',').map(&:strip).reject(&:empty?) }
  opts.on('--flush', 'Flush the selected Redis DB before run') { options[:flush] = true }
  opts.on('--no-seed', 'Do not seed assets/market') { options[:seed] = false }
  # 新增选项：禁用彩色输出
  opts.on('--no-color', 'Disable colored output') { options[:color] = false }
  # 新增选项：静默模式（仅输出 INIT/AUDIT/ERROR 等关键信息，适合 CI）
  opts.on('--quiet', 'Suppress per-operation output (CI friendly)') { options[:quiet] = true }
  # 新增选项：显示合并深度
  opts.on('--merge-depth [BUCKET_SIZE]', Integer, 'Show merged depth with specified bucket size') { |v| options[:merge_depth] = v || 1000 }
  # 新增选项：运行结束后执行余额审计
  opts.on('--audit', 'Run balance audit after completion') { options[:audit] = true }
  # 新增选项：定期 Ledger 重放审计
  opts.on('--audit-interval N', Integer, 'Perform ledger replay audit every N operations') { |v| options[:audit_interval] = v }
  # 新增选项：并发线程数
  opts.on('--concurrency N', Integer, 'Number of concurrent worker threads (default: 1)') { |v| options[:concurrency] = v }
end.parse!

options[:concurrency] ||= 1
if options[:concurrency] > 1 && options[:audit_interval]
  puts "\e[33m[WARN]\e[0m Periodic audit (--audit-interval) is disabled in concurrency mode."
  options[:audit_interval] = nil
end

raise ArgumentError, 'sleep-max must be >= sleep-min' if options[:sleep_max] < options[:sleep_min]

# 彩色输出开关（TTY 且未禁用时启用）
$color_enabled = options[:color] && $stdout.isatty
# 静默模式开关（CI 下减少日志量）
$quiet_enabled = options[:quiet]

# 彩色输出辅助方法（需在首次使用前定义）
COLORS = {
  reset: "\e[0m",
  bold: "\e[1m",
  red: "\e[31m",
  green: "\e[32m",
  yellow: "\e[33m",
  blue: "\e[34m",
  magenta: "\e[35m",
  cyan: "\e[36m",
  bright_black: "\e[90m"
}.freeze

def c(str, *styles)
  return str unless ($color_enabled rescue false)
  codes = styles.flatten.map { |s| COLORS[s] }.compact.join
  "#{codes}#{str}#{COLORS[:reset]}"
end

def log(str)
  return if $quiet_enabled
  puts str
end

# Main setup (single threaded)
redis_main = Redis.new(url: options[:redis_url])
exchange_main = RedisExchange::Client.new(redis: redis_main)

if options[:flush]
  puts "#{c('[INIT]', :cyan)} Flushing Redis DB..."
  redis_main.flushdb
end

# Default assets & market scales
ASSET_SCALES = { 'BTC' => 100_000_000, 'USDT' => 100 }.freeze
PRICE_SCALE = 100
QUANTITY_SCALE = 100_000_000

# Audit State (Main thread only)
audit_baseline_balances = {}
audit_baseline_id = '0-0'

if options[:audit_interval] || options[:audit]
  puts "#{c('[AUDIT]', :cyan)} Initializing baseline snapshot..."
  # Capture initial state for replay audit
  audit_baseline_balances = exchange_main.maintenance.snapshot_balances
  
  # Get current ledger max id
  last_entry = redis_main.xrevrange('account_ledger', '+', '-', count: 1).first
  audit_baseline_id = last_entry ? last_entry[0] : '0-0'
  puts "#{c('[AUDIT]', :cyan)} Baseline ID: #{audit_baseline_id}"
end

# Precision-aware formatting helpers (placed before seeding for availability)
def decimals_for_scale(scale)
  s = scale.to_i
  d = 0
  while s > 1 && (s % 10).zero?
    s /= 10
    d += 1
  end
  d
end

def to_dec_str(value, scale)
  digits = decimals_for_scale(scale)
  # BigDecimal for precise formatting
  x = BigDecimal(value.to_s) / BigDecimal(scale.to_s)
  format("%.#{digits}f", x)
end

def format_price(v)
  to_dec_str(v, PRICE_SCALE)
end

def format_quantity(v)
  to_dec_str(v, QUANTITY_SCALE)
end

def format_asset_amount(asset, amount)
  scale = ASSET_SCALES[asset]
  to_dec_str(amount, scale)
end

if options[:seed]
  puts "#{c('[INIT]', :cyan)} Seeding assets and market..."
  # Seed assets
  exchange_main.seed_asset(asset: 'BTC', balance_scale: ASSET_SCALES['BTC'], status: 'ACTIVE')
  exchange_main.seed_asset(asset: 'USDT', balance_scale: ASSET_SCALES['USDT'], status: 'ACTIVE')
  # Seed market
  exchange_main.seed_market(
    symbol: options[:symbol],
    base_asset: 'BTC',
    quote_asset: 'USDT',
    price_scale: PRICE_SCALE,
    quantity_scale: QUANTITY_SCALE,
    maker_fee_bps: 5,
    taker_fee_bps: 10,
    min_qty: 1,
    min_notional: 1,
    status: 'OPEN'
  )
  # Seed initial balances per user for both assets
  options[:users].each do |u|
    # Deposit some USDT: between 5_000 and 50_000
    usdt_amount = (5_000 + rand(0..45_000)) * ASSET_SCALES['USDT']
    res1 = exchange_main.add_funds(user_id: u, asset: 'USDT', amount: usdt_amount)
    log "#{c('[DEPOSIT]', :green)} user=#{u} asset=USDT amount=#{format_asset_amount('USDT', usdt_amount)} => #{JSON.pretty_generate(res1)}"
    # Deposit some BTC: between 0.05 and 0.5 BTC
    btc_amount = (5 + rand(0..45)) * (ASSET_SCALES['BTC'] / 100) # 0.05..0.5 BTC in minor units
    res2 = exchange_main.add_funds(user_id: u, asset: 'BTC', amount: btc_amount)
    log "#{c('[DEPOSIT]', :green)} user=#{u} asset=BTC amount=#{format_asset_amount('BTC', btc_amount)} => #{JSON.pretty_generate(res2)}"
  end
end

if options[:merge_depth]
  puts "#{c('[INIT]', :cyan)} Showing initial merged depth..."
  print_merged_order_book(Time.now.strftime('%H:%M:%S'), exchange_main, options[:symbol], bucket_size: options[:merge_depth], depth_limit: 10)
  puts
end

# Balance Conservation Audit Helper

# Read an entire stream with cursor pagination; a bare `count:` cap would
# silently truncate and skew audit totals on dense runs (ledger can exceed 10k).
def scan_stream_all(redis, key, batch_size: 1000)
  entries = []
  last_id = '-'
  loop do
    batch = redis.xrange(key, last_id == '-' ? '-' : "(#{last_id}", '+', count: batch_size)
    break if batch.empty?
    entries.concat(batch)
    last_id = batch.last[0]
    break if batch.size < batch_size
  end
  entries
end

def run_balance_conservation_audit(redis, exchange, symbol, initial_balances, assets, initial_ledger_id)
  puts "#{c('[AUDIT]', :cyan, :bold)} Running balance conservation check..."
  puts
  
  # 1. Calculate final balances
  final_balances = {}
  cursor = '0'
  loop do
    cursor, keys = redis.scan(cursor, match: 'balance:*', count: 1000)
    keys.each do |key|
      fields = redis.hgetall(key)
      fields.each do |field, value|
        parts = field.split(':')
        if parts.length == 2
          asset = parts[0]
          bucket = parts[1]
          if bucket == 'available' || bucket == 'reserved'
            final_balances[asset] ||= 0
            final_balances[asset] += value.to_i
          end
        end
      end
    end
    break if cursor == '0'
  end
  
  # 2. Collect fees from trades
  fees_collected = {}
  trade_stream_key = "trades:#{symbol}"
  
  # Use XRANGE to get all entries from the trade stream
  # XRANGE returns entries in chronological order
  trade_entries = scan_stream_all(redis, trade_stream_key)
  
  # Get quote asset from market config
  market_config = redis.hgetall("market:#{symbol}")
  quote_asset = market_config['quote_asset'] || 'USDT'
  base_asset = market_config['base_asset'] || 'BTC'
  
  trade_entries.each do |entry_id, fields|
    taker_fee = fields['taker_fee'].to_i
    maker_fee = fields['maker_fee'].to_i
    
    # Check taker side to determine fee asset
    # Taker BUY: Pays fee in Base Asset (e.g. BTC)
    # Taker SELL: Pays fee in Quote Asset (e.g. USDT)
    taker_side = fields['taker_side']
    
    if taker_side == 'BUY'
      # Taker bought Base, paid fee in Base
      fees_collected[base_asset] ||= 0
      fees_collected[base_asset] += taker_fee
      
      # Maker was SELL, received Quote, paid fee in Quote
      fees_collected[quote_asset] ||= 0
      fees_collected[quote_asset] += maker_fee
    else # Taker SELL
      # Taker sold Base, received Quote, paid fee in Quote
      fees_collected[quote_asset] ||= 0
      fees_collected[quote_asset] += taker_fee
      
      # Maker was BUY, received Base, paid fee in Base
      fees_collected[base_asset] ||= 0
      fees_collected[base_asset] += maker_fee
    end
  end
  
  # 3. Collect ONLY external deposits and withdrawals from ledger (ADD/SUB only)
  # Note: Trading-related ADD/SUB operations are internal asset transfers and
  # should not be counted as external deposits/withdrawals for this audit
  # We will rely on the fact that trading conserves total balance (assets are just transferred between users)
  external_deposits = {}
  external_withdrawals = {}
  
  # Use XRANGE to get ledger entries after initial ledger ID
  ledger_entries = scan_stream_all(redis, 'account_ledger')
  
  processed_count = 0
  skipped_count = 0
  initial_parts = initial_ledger_id.split('-').map(&:to_i)
  ledger_entries.each do |entry_id, fields|
    # Skip entries that were already accounted for in initial balances.
    # Compare full stream IDs (ms-seq) so same-second entries are judged exactly.
    entry_parts = entry_id.split('-').map(&:to_i)

    if (entry_parts <=> initial_parts) <= 0
      skipped_count += 1
      next
    end
    
    processed_count += 1
    action = fields['action']
    asset = fields['asset']
    amount = fields['amount'].to_i
    reason = fields['reason'] || ''
    
    # Only count external deposits/withdrawals (DEPOSIT, WITHDRAWAL reasons)
    # Trading operations have different reasons or are part of the same transaction
    case action
    when 'ADD'
      if reason == 'DEPOSIT' || reason == 'add_funds'
        external_deposits[asset] ||= 0
        external_deposits[asset] += amount
      end
    when 'SUB'
      if reason == 'WITHDRAWAL' || reason == 'sub_funds'
        external_withdrawals[asset] ||= 0
        external_withdrawals[asset] += amount
      end
    when 'LOCK', 'UNLOCK', 'SUB_LOCKED', 'ADD_LOCKED'
      # Internal balance transfers - skip
    end
  end
  
  # 4. Run audit for all assets
  # Formula: Initial + External Deposits - External Withdrawals - Fees = Final
  # Trading operations should conserve total balance (assets are transferred, not created/destroyed)
  all_assets = (initial_balances.keys + final_balances.keys + fees_collected.keys + external_deposits.keys + external_withdrawals.keys).uniq
  
  discrepancies = []
  all_assets.each do |asset|
    initial = initial_balances[asset] || 0
    final = final_balances[asset] || 0
    fees = fees_collected[asset] || 0
    deposit = external_deposits[asset] || 0
    withdrawal = external_withdrawals[asset] || 0
    
    # Formula: Initial + External Deposits - External Withdrawals - Fees = Final
    expected = initial + deposit - withdrawal - fees
    diff = final - expected
    
    puts "#{c('Asset:', :yellow)} #{asset}"
    puts "  Initial:     #{format_asset_amount(asset, initial)}"
    if fees > 0
      puts "  - Fees:      #{format_asset_amount(asset, fees)} (collected from trades)"
    end
    if deposit > 0
      puts "  + Deposits:  #{format_asset_amount(asset, deposit)}"
    end
    if withdrawal > 0
      puts "  - Withdrawals: #{format_asset_amount(asset, withdrawal)}"
    end
    puts "  = Expected:   #{format_asset_amount(asset, expected)}"
    puts "  Actual:      #{format_asset_amount(asset, final)}"
    
    if diff == 0
      puts "  Diff:        #{format_asset_amount(asset, diff)} #{c('✅', :green)}"
    else
      puts "  Diff:        #{format_asset_amount(asset, diff)} #{c('❌', :red)}"
      discrepancies << { asset: asset, diff: diff, expected: expected, actual: final }
    end
    puts
  end
  
  if discrepancies.empty?
    puts "#{c('✅', :green)} Balance conservation check PASSED! All assets balanced."
  else
    puts "#{c('❌', :red, :bold)} Balance conservation check FAILED! #{discrepancies.size} discrepancy(ies) found."
  end
  
  { success: discrepancies.empty?, discrepancies: discrepancies }
end

# Capture initial balances for conservation audit
initial_balances_by_asset = {}
initial_ledger_id = nil
if options[:audit]
  puts "#{c('[INIT]', :cyan)} Capturing initial balance snapshot for conservation audit..."
  
  # Capture the latest ledger ID at this point
  last_entry = redis_main.xrevrange('account_ledger', '+', '-', count: 1).first
  initial_ledger_id = last_entry ? last_entry[0] : '0-0'
  puts "#{c('[INIT]', :cyan)} Initial ledger ID: #{initial_ledger_id}"
  
  # Scan all balance keys
  cursor = '0'
  loop do
    cursor, keys = redis_main.scan(cursor, match: 'balance:*', count: 1000)
    keys.each do |key|
      fields = redis_main.hgetall(key)
      fields.each do |field, value|
        parts = field.split(':')
        if parts.length == 2
          asset = parts[0]
          bucket = parts[1]
          if bucket == 'available' || bucket == 'reserved'
            initial_balances_by_asset[asset] ||= 0
            initial_balances_by_asset[asset] += value.to_i
          end
        end
      end
    end
    break if cursor == '0'
  end
  
  puts "#{c('[INIT]', :cyan)} Initial balances captured for #{initial_balances_by_asset.size} asset(s)"
  initial_balances_by_asset.each do |asset, amount|
    puts "  #{asset}: #{format_asset_amount(asset, amount)}"
  end
  puts
end

# Helpers for random values respecting scales
rand_price = lambda do
  p = rand(2_900_000..3_100_000) # around 29k..31k USDT
  p - (p % PRICE_SCALE)
end

rand_quantity = lambda do
  # 0.05..0.5 BTC in minor units
  step = QUANTITY_SCALE / 100 # 0.01 BTC
  n_steps = rand(5..50) # 0.05..0.5 BTC
  n_steps * step
end

rand_usdt_amount = lambda do
  # 1000..50_000 USDT in minor units
  amt = rand(1_000..50_000) * ASSET_SCALES['USDT']
  amt
end

rand_btc_amount = lambda do
  # 0.01..0.2 BTC in minor units
  step = ASSET_SCALES['BTC'] / 100 # 0.01 BTC
  rand(1..20) * step
end

ops = %i[limit_order market_order add_funds sub_funds cancel_one]

weights = {
  limit_order: 40,
  market_order: 30,
  add_funds: 2,
  sub_funds: 2,
  cancel_one: 10
}

pick_op = lambda do
  bag = ops.flat_map { |op| [op] * weights[op] }
  bag.sample
end

# Helper: pretty print trade results
def print_trade_results(ts, res, thread_id)
  return if $quiet_enabled
  return if res.nil?
  return if res[:error]
  status = res[:status].to_s
  return unless %w[OPEN PARTIALLY_FILLED FILLED].include?(status)

  trades = Array(res[:trades])
  prefix = "[#{ts}] [T#{thread_id}]"

  if trades.empty?
    puts "#{prefix} #{c('TRADES', :yellow)} none (executed_quantity=#{format_quantity(res[:executed_quantity] || 0)})"
    return
  end

  puts "#{prefix} #{c('TRADES', :yellow)} count=#{trades.size} executed_quantity=#{format_quantity(res[:executed_quantity])} taker_quote_spent=#{format_price(res[:taker_quote_spent])} taker_quote_received=#{format_price(res[:taker_quote_received])} taker_base_received=#{format_quantity(res[:taker_base_received])} taker_base_sold=#{format_quantity(res[:taker_base_sold])} taker_fee_paid=#{format_price(res[:taker_fee_paid])} maker_fee_charged=#{format_price(res[:maker_fee_charged])}"
  trades.each_with_index do |t, idx|
    puts "#{prefix} #{c("TRADE[#{idx + 1}]", :yellow)} taker_side=#{c(t[:taker_side], (t[:taker_side] == 'BUY' ? :green : :red))} buy_id=#{t[:buy_order_id]} sell_id=#{t[:sell_order_id]} price=#{format_price(t[:price])} qty=#{format_quantity(t[:quantity])} quote=#{format_price(t[:quote])} taker_fee=#{format_price(t[:taker_fee])} maker_fee=#{format_price(t[:maker_fee])} ts=#{t[:timestamp]}"
  end
end

# Helper: print current order book depth table (top N levels per side)
def print_order_book(ts, exchange, symbol, depth_limit: 10)
  ob = exchange.order_book(symbol, limit: depth_limit)
  bids = Array(ob[:bids])
  asks = Array(ob[:asks])

  # Precompute formatted strings
  bid_prices = bids.map { |r| format_price(r[:price]) }
  bid_vols   = bids.map { |r| format_quantity(r[:volume]) }
  ask_prices = asks.map { |r| format_price(r[:price]) }
  ask_vols   = asks.map { |r| format_quantity(r[:volume]) }

  # Compute column widths based on formatted values
  bid_price_w = (["price"] + bid_prices).map(&:size).max || 5
  bid_vol_w   = (["volume"] + bid_vols).map(&:size).max || 6
  ask_price_w = (["price"] + ask_prices).map(&:size).max || 5
  ask_vol_w   = (["volume"] + ask_vols).map(&:size).max || 6

  puts "[#{ts}] #{c('ORDER BOOK', :cyan)} (top #{depth_limit})"
  header_left  = "BIDS".ljust(bid_price_w + bid_vol_w + 7)
  header_right = "ASKS".ljust(ask_price_w + ask_vol_w + 7)
  puts "#{header_left}| #{header_right}"
  sub_left  = "price".rjust(bid_price_w) + "  " + "volume".rjust(bid_vol_w)
  sub_right = "price".rjust(ask_price_w) + "  " + "volume".rjust(ask_vol_w)
  puts "#{sub_left.ljust(bid_price_w + bid_vol_w + 3)}   | #{sub_right}"

  rows = [bids.size, asks.size].max
  rows.times do |i|
    lb = bids[i]
    rb = asks[i]
    left = if lb
      lb_price = format_price(lb[:price]).rjust(bid_price_w)
      lb_vol = format_quantity(lb[:volume]).rjust(bid_vol_w)
      "#{lb_price}  #{lb_vol}"
    else
      "".ljust(bid_price_w + bid_vol_w + 2)
    end
    right = if rb
      rb_price = format_price(rb[:price]).rjust(ask_price_w)
      rb_vol = format_quantity(rb[:volume]).rjust(ask_vol_w)
      "#{rb_price}  #{rb_vol}"
    else
      ""
    end
    puts "#{left.ljust(bid_price_w + bid_vol_w + 3)}   | #{right}"
  end
end

# Helper: print merged order book depth table
def print_merged_order_book(ts, exchange, symbol, bucket_size:, depth_limit: 10)
  merged_ob = exchange.merge_depth_both_sides(symbol, bucket_size, bucket_size, limit: depth_limit)
  bids = Array(merged_ob[:bids])
  asks = Array(merged_ob[:asks])

  # Precompute formatted strings
  bid_prices = bids.map { |r| format_price(r[:price]) }
  bid_vols   = bids.map { |r| format_quantity(r[:volume]) }
  bid_levels = bids.map { |r| r[:original_levels].to_s }
  ask_prices = asks.map { |r| format_price(r[:price]) }
  ask_vols   = asks.map { |r| format_quantity(r[:volume]) }
  ask_levels = asks.map { |r| r[:original_levels].to_s }

  # Compute column widths based on formatted values
  bid_price_w = (["price"] + bid_prices).map(&:size).max || 5
  bid_vol_w   = (["volume"] + bid_vols).map(&:size).max || 6
  bid_levels_w = (["levels"] + bid_levels).map(&:size).max || 6
  ask_price_w = (["price"] + ask_prices).map(&:size).max || 5
  ask_vol_w   = (["volume"] + ask_vols).map(&:size).max || 6
  ask_levels_w = (["levels"] + ask_levels).map(&:size).max || 6

  puts "[#{ts}] #{c('MERGED ORDER BOOK', :magenta)} (bucket_size=#{format_price(bucket_size)}, top #{depth_limit})"
  header_left  = "BIDS".ljust(bid_price_w + bid_vol_w + bid_levels_w + 10)
  header_right = "ASKS".ljust(ask_price_w + ask_vol_w + ask_levels_w + 10)
  puts "#{header_left}| #{header_right}"
  sub_left  = "price".rjust(bid_price_w) + "  " + "volume".rjust(bid_vol_w) + "  " + "levels".rjust(bid_levels_w)
  sub_right = "price".rjust(ask_price_w) + "  " + "volume".rjust(ask_vol_w) + "  " + "levels".rjust(ask_levels_w)
  puts "#{sub_left.ljust(bid_price_w + bid_vol_w + bid_levels_w + 6)}   | #{sub_right}"

  rows = [bids.size, asks.size].max
  rows.times do |i|
    lb = bids[i]
    rb = asks[i]
    left = if lb
      lb_price = format_price(lb[:price]).rjust(bid_price_w)
      lb_vol = format_quantity(lb[:volume]).rjust(bid_vol_w)
      lb_levels = lb[:original_levels].to_s.rjust(bid_levels_w)
      "#{lb_price}  #{lb_vol}  #{lb_levels}"
    else
      "".ljust(bid_price_w + bid_vol_w + bid_levels_w + 4)
    end
    right = if rb
      rb_price = format_price(rb[:price]).rjust(ask_price_w)
      rb_vol = format_quantity(rb[:volume]).rjust(ask_vol_w)
      rb_levels = rb[:original_levels].to_s.rjust(ask_levels_w)
      "#{rb_price}  #{rb_vol}  #{rb_levels}"
    else
      "".ljust(ask_price_w + ask_vol_w + ask_levels_w + 4)
    end
    puts "#{left.ljust(bid_price_w + bid_vol_w + bid_levels_w + 6)}   | #{right}"
  end
end

# Worker logic
run_worker = lambda do |thread_id, iterations, shared_options|
  # Each thread gets its own Redis connection
  local_redis = Redis.new(url: shared_options[:redis_url])
  local_exchange = RedisExchange::Client.new(redis: local_redis)
  local_placed_order_ids = []
  
  order_seq = 0
  
  iterations.times do |i|
    op = pick_op.call
    user = shared_options[:users].sample
    ts = Time.now.strftime('%H:%M:%S')
    prefix = "[#{ts}] [T#{thread_id}]"
    
    begin
      case op
      when :limit_order
        side = %w[BUY SELL].sample
        price = rand_price.call
        quantity = rand_quantity.call
        order_id = "bot-T#{thread_id}-lim-#{order_seq += 1}"
        
        res = local_exchange.place_limit_order(
          symbol: shared_options[:symbol],
          side: side,
          order_id: order_id,
          user_id: user,
          price: price,
          quantity: quantity
        )
        local_placed_order_ids << order_id if res[:status] == 'OPEN' || res[:status] == 'PARTIALLY_FILLED'
        log "#{prefix} #{c('LIMIT', :blue)} #{c(side, (side == 'BUY' ? :green : :red))} user=#{user} price=#{format_price(price)} qty=#{format_quantity(quantity)} id=#{order_id} => #{JSON.pretty_generate(res)}"
        print_trade_results(ts, res, thread_id)

        if !$quiet_enabled && %w[OPEN PARTIALLY_FILLED FILLED].include?(res[:status].to_s)
          if shared_options[:merge_depth]
            print_merged_order_book(ts, local_exchange, shared_options[:symbol], bucket_size: shared_options[:merge_depth], depth_limit: 10)
          else
            print_order_book(ts, local_exchange, shared_options[:symbol], depth_limit: 10)
          end
        end

      when :market_order
        side = %w[BUY SELL].sample
        quantity = rand_quantity.call
        price_cap = [0, rand_price.call].sample
        order_id = "bot-T#{thread_id}-mkt-#{order_seq += 1}"
        
        res = local_exchange.place_market_order(
          symbol: shared_options[:symbol],
          side: side,
          order_id: order_id,
          user_id: user,
          quantity: quantity,
          price_cap: price_cap
        )
        cap_str = price_cap.to_i > 0 ? format_price(price_cap) : 'none'
        log "#{prefix} #{c('MARKET', :blue)} #{c(side, (side == 'BUY' ? :green : :red))} user=#{user} qty=#{format_quantity(quantity)} cap=#{cap_str} id=#{order_id} => #{JSON.pretty_generate(res)}"
        print_trade_results(ts, res, thread_id)

        if !$quiet_enabled && %w[OPEN PARTIALLY_FILLED FILLED].include?(res[:status].to_s)
          if shared_options[:merge_depth]
            print_merged_order_book(ts, local_exchange, shared_options[:symbol], bucket_size: shared_options[:merge_depth], depth_limit: 10)
          else
            print_order_book(ts, local_exchange, shared_options[:symbol], depth_limit: 10)
          end
        end

      when :add_funds
        asset = %w[USDT BTC].sample
        amount = asset == 'USDT' ? rand_usdt_amount.call : rand_btc_amount.call
        res = local_exchange.add_funds(user_id: user, asset: asset, amount: amount)
        log "#{prefix} #{c('DEPOSIT', :green)} user=#{user} asset=#{asset} amount=#{format_asset_amount(asset, amount)} => #{JSON.pretty_generate(res)}"
        
      when :sub_funds
        asset = %w[USDT BTC].sample
        amount = asset == 'USDT' ? rand_usdt_amount.call : rand_btc_amount.call
        res = local_exchange.sub_funds(user_id: user, asset: asset, amount: amount)
        log "#{prefix} #{c('WITHDRAW', :magenta)} user=#{user} asset=#{asset} amount=#{format_asset_amount(asset, amount)} => #{JSON.pretty_generate(res)}"
        
      when :cancel_one
        if local_placed_order_ids.empty?
          log "#{prefix} #{c('CANCEL', :yellow)} skip (no known resting orders)"
        else
          target = local_placed_order_ids.sample
          res = local_exchange.cancel_order(target)
          log "#{prefix} #{c('CANCEL', :yellow)} id=#{target} => #{JSON.pretty_generate(res)}"
          if res[:status] == 'CANCELLED' || res[:error] == 'NOT_FOUND'
            local_placed_order_ids.delete(target)
          end
        end
      end
    rescue => e
      puts "#{prefix} #{c('ERROR', :bold, :red)} op=#{op} user=#{user} msg=#{e.class}: #{e.message}"
    end
    
    # Audit interval check is ONLY valid for single thread (concurrency=1)
    if shared_options[:audit_interval] && shared_options[:concurrency] == 1 && ((i + 1) % shared_options[:audit_interval]).zero?
      # Logic duplicated from previous implementation but wrapped for single thread worker
      # Since we are inside the worker block, we use local_exchange/redis
      puts
      puts "#{c('[AUDIT]', :cyan)} Running periodic ledger replay check (iteration #{i + 1})..."
      current_last_entry = local_redis.xrevrange('account_ledger', '+', '-', count: 1).first
      current_end_id = current_last_entry ? current_last_entry[0] : '0-0'
      current_actual_balances = local_exchange.maintenance.snapshot_balances
      
      audit_res = local_exchange.maintenance.replay_ledger_audit(
        initial_balances: audit_baseline_balances,
        start_id: audit_baseline_id,
        end_id: current_end_id,
        actual_balances: current_actual_balances
      )
      
      if audit_res[:success]
        puts "#{c('[AUDIT]', :green)} Check passed! Replayed from #{audit_baseline_id} to #{current_end_id}."
        audit_baseline_balances = audit_res[:expected_balances]
        audit_baseline_id = current_end_id
      else
        puts "#{c('[AUDIT]', :red, :bold)} Check FAILED!"
        audit_res[:discrepancies].each do |d|
          puts "  User #{d[:user_id]} #{d[:asset]} #{d[:bucket]}: Expected #{d[:expected]}, Actual #{d[:actual]}"
        end
        exit 1
      end
      puts
    end
    
    delay = rand(shared_options[:sleep_min]..shared_options[:sleep_max])
    sleep(delay)
  end
  
  local_redis.close
end

puts "#{c('[INIT]', :cyan)} Starting #{options[:concurrency]} worker threads..."

threads = []
options[:concurrency].times do |t_idx|
  threads << Thread.new do
    run_worker.call(t_idx + 1, options[:iterations], options)
  end
end

threads.each(&:join)

if options[:audit]
  puts
  puts c('[AUDIT]', :cyan, :bold) + " Starting post-run ledger replay check..."
  audit_failures = 0

  # 1. Capture current end state
  current_last_entry = redis_main.xrevrange('account_ledger', '+', '-', count: 1).first
  current_end_id = current_last_entry ? current_last_entry[0] : '0-0'

  # 2. Capture current actual balances
  current_actual_balances = exchange_main.maintenance.snapshot_balances

  # 3. Run replay
  audit_res = exchange_main.maintenance.replay_ledger_audit(
    initial_balances: audit_baseline_balances,
    start_id: audit_baseline_id,
    end_id: current_end_id,
    actual_balances: current_actual_balances
  )

  if audit_res[:success]
    puts "#{c('✅', :green)} Ledger replay check passed! (Range: #{audit_baseline_id} -> #{current_end_id})"
  else
    audit_failures += 1
    puts "#{c('❌', :red)} Ledger replay check FAILED!"
    audit_res[:discrepancies].each do |d|
      puts "  User #{d[:user_id]} #{d[:asset]} #{d[:bucket]}: Expected #{d[:expected]}, Actual #{d[:actual]}"
    end
    # We don't exit here, we continue to the static balance audit below
  end

  puts
  puts c('[AUDIT]', :cyan, :bold) + " Starting post-run balance audit (Static Check)..."
  begin
    reports = exchange_main.maintenance.audit_user_balances(fix: true)
    
    if reports.empty?
      puts "#{c('✅', :green)} No discrepancies found."
    else
      puts "#{c('⚠️', :yellow)} Found #{reports.size} user(s) with discrepancies:"
      
      reports.each do |r|
        puts "\nUser: #{r[:user_id]}"
        
        unless r[:deficits].empty?
          puts "  Deficits (Insufficient Funds):"
          r[:deficits].each do |d|
            puts "    - #{d[:asset]}: #{d[:amount]} (Missing)"
          end
        end
        
        unless r[:fixes].empty?
          puts "  Adjustments Applied:"
          r[:fixes].each do |f|
            action_icon = f[:action] == 'LOCK' ? '🔒' : '🔓'
            color = f[:action] == 'LOCK' ? :red : :green
            puts "    #{action_icon} #{c(f[:action], color)} #{f[:asset]}: #{f[:amount]}"
          end
        end
      end
    end
  rescue => e
    audit_failures += 1
    puts "#{c('❌', :red)} Audit failed: #{e.message}"
  end

  puts
  conservation_res = run_balance_conservation_audit(redis_main, exchange_main, options[:symbol], initial_balances_by_asset, ASSET_SCALES.keys, initial_ledger_id)
  audit_failures += 1 unless conservation_res && conservation_res[:success]

  exit 1 if audit_failures.positive?
end

puts c('[DONE]', :green)
