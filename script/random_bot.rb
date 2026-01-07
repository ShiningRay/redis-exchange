#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'json'
require 'securerandom'
require 'redis'
require 'bigdecimal'
require_relative '../lib/redis_exchange'

# Random trading bot: performs random deposits/withdrawals, limit & market orders,
# with random waits between operations and prints every result.
#
# Usage:
#   ruby script/random_bot.rb [--redis-url redis://127.0.0.1:6379/0] \
#     [--symbol BTCUSDT] [--iterations 100] [--sleep-min 0.2] [--sleep-max 1.5] \
#     [--users alice,bob,charlie] [--flush] [--no-seed]
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
  color: true
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
  # 新增选项：显示合并深度
  opts.on('--merge-depth [BUCKET_SIZE]', Integer, 'Show merged depth with specified bucket size') { |v| options[:merge_depth] = v || 1000 }
end.parse!

raise ArgumentError, 'sleep-max must be >= sleep-min' if options[:sleep_max] < options[:sleep_min]

# 彩色输出开关（TTY 且未禁用时启用）
$color_enabled = options[:color] && $stdout.isatty

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

redis = Redis.new(url: options[:redis_url])
exchange = RedisExchange::Client.new(redis: redis)

if options[:flush]
  puts "#{c('[INIT]', :cyan)} Flushing Redis DB..."
  redis.flushdb
end

# Default assets & market scales
ASSET_SCALES = { 'BTC' => 100_000_000, 'USDT' => 100 }.freeze
PRICE_SCALE = 100
QUANTITY_SCALE = 100_000_000

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

# 彩色输出辅助方法（已上移至前面，避免未定义时被调用）
# COLORS / c(str, *styles)

if options[:seed]
  puts "#{c('[INIT]', :cyan)} Seeding assets and market..."
  # Seed assets
  exchange.seed_asset(asset: 'BTC', balance_scale: ASSET_SCALES['BTC'], status: 'ACTIVE')
  exchange.seed_asset(asset: 'USDT', balance_scale: ASSET_SCALES['USDT'], status: 'ACTIVE')
  # Seed market
  exchange.seed_market(
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
    res1 = exchange.deposit(user_id: u, asset: 'USDT', amount: usdt_amount)
    puts "#{c('[DEPOSIT]', :green)} user=#{u} asset=USDT amount=#{format_asset_amount('USDT', usdt_amount)} => #{JSON.pretty_generate(res1)}"
    # Deposit some BTC: between 0.05 and 0.5 BTC
    btc_amount = (5 + rand(0..45)) * (ASSET_SCALES['BTC'] / 100) # 0.05..0.5 BTC in minor units
    res2 = exchange.deposit(user_id: u, asset: 'BTC', amount: btc_amount)
    puts "#{c('[DEPOSIT]', :green)} user=#{u} asset=BTC amount=#{format_asset_amount('BTC', btc_amount)} => #{JSON.pretty_generate(res2)}"
  end
end

order_seq = 0
placed_order_ids = []

# Helper: pretty print trade results upon successful order placement
def print_trade_results(ts, res)
  return if res.nil?
  return if res[:error]
  status = res[:status].to_s
  return unless %w[OPEN PARTIALLY_FILLED FILLED].include?(status)

  trades = Array(res[:trades])
  if trades.empty?
    puts "[#{ts}] #{c('TRADES', :yellow)} none (executed_quantity=#{format_quantity(res[:executed_quantity] || 0)})"
    return
  end

  puts "[#{ts}] #{c('TRADES', :yellow)} count=#{trades.size} executed_quantity=#{format_quantity(res[:executed_quantity])} taker_quote_spent=#{format_price(res[:taker_quote_spent])} taker_quote_received=#{format_price(res[:taker_quote_received])} taker_base_received=#{format_quantity(res[:taker_base_received])} taker_base_sold=#{format_quantity(res[:taker_base_sold])} taker_fee_paid=#{format_price(res[:taker_fee_paid])} maker_fee_charged=#{format_price(res[:maker_fee_charged])}"
  trades.each_with_index do |t, idx|
    puts "[#{ts}] #{c("TRADE[#{idx + 1}]", :yellow)} taker_side=#{c(t[:taker_side], (t[:taker_side] == 'BUY' ? :green : :red))} buy_id=#{t[:buy_order_id]} sell_id=#{t[:sell_order_id]} price=#{format_price(t[:price])} qty=#{format_quantity(t[:quantity])} quote=#{format_price(t[:quote])} taker_fee=#{format_price(t[:taker_fee])} maker_fee=#{format_price(t[:maker_fee])} ts=#{t[:timestamp]}"
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

ops = %i[limit_order market_order deposit withdraw cancel_one]

weights = {
  limit_order: 40,
  market_order: 30,
  deposit: 2,
  withdraw: 2,
  cancel_one: 10
}

pick_op = lambda do
  bag = ops.flat_map { |op| [op] * weights[op] }
  bag.sample
end

# 如果启用了合并深度显示，先显示一次初始状态
if options[:merge_depth]
  puts "#{c('[INIT]', :cyan)} 显示初始合并深度状态..."
  print_merged_order_book(Time.now.strftime('%H:%M:%S'), exchange, options[:symbol], bucket_size: options[:merge_depth], depth_limit: 10)
  puts
end

options[:iterations].times do |i|
  op = pick_op.call
  user = options[:users].sample
  ts = Time.now.strftime('%H:%M:%S')

  begin
    case op
    when :limit_order
      side = %w[BUY SELL].sample
      price = rand_price.call
      quantity = rand_quantity.call
      order_id = "bot-lim-#{order_seq += 1}"
      res = exchange.place_limit_order(
        symbol: options[:symbol],
        side: side,
        order_id: order_id,
        user_id: user,
        price: price,
        quantity: quantity
      )
      placed_order_ids << order_id if res[:status] == 'OPEN' || res[:status] == 'PARTIALLY_FILLED'
      puts "[#{ts}] #{c('LIMIT', :blue)} #{c(side, (side == 'BUY' ? :green : :red))} user=#{user} price=#{format_price(price)} qty=#{format_quantity(quantity)} id=#{order_id} => #{JSON.pretty_generate(res)}"
      if res.nil?
        puts "Empty result"
      elsif res[:error].nil?
        # Print trade results (if any)
        print_trade_results(ts, res)
        # Print current order book depth on successful placement
        if %w[OPEN PARTIALLY_FILLED FILLED].include?(res[:status].to_s)
          if options[:merge_depth]
            print_merged_order_book(ts, exchange, options[:symbol], bucket_size: options[:merge_depth], depth_limit: 10)
          else
            print_order_book(ts, exchange, options[:symbol], depth_limit: 10)
          end
        else
          puts res[:status]
        end
      else
        puts res
      end
    when :market_order
      side = %w[BUY SELL].sample
      quantity = rand_quantity.call
      price_cap = [0, rand_price.call].sample # sometimes uncapped
      order_id = "bot-mkt-#{order_seq += 1}"
      res = exchange.place_market_order(
        symbol: options[:symbol],
        side: side,
        order_id: order_id,
        user_id: user,
        quantity: quantity,
        price_cap: price_cap
      )
      cap_str = price_cap.to_i > 0 ? format_price(price_cap) : 'none'
      puts "[#{ts}] #{c('MARKET', :blue)} #{c(side, (side == 'BUY' ? :green : :red))} user=#{user} qty=#{format_quantity(quantity)} cap=#{cap_str} id=#{order_id} => #{JSON.pretty_generate(res)}"
      if res.nil?
        puts "Empty result"
      elsif res[:error].nil?
        # Print trade results (if any)
        print_trade_results(ts, res)
        # Print current order book depth on successful placement
        if %w[OPEN PARTIALLY_FILLED FILLED].include?(res[:status].to_s)
          if options[:merge_depth]
            print_merged_order_book(ts, exchange, options[:symbol], bucket_size: options[:merge_depth], depth_limit: 10)
          else
            print_order_book(ts, exchange, options[:symbol], depth_limit: 10)
          end
        else
          puts res[:status]
        end
      else
        puts res
      end

    when :deposit
      asset = %w[USDT BTC].sample
      amount = asset == 'USDT' ? rand_usdt_amount.call : rand_btc_amount.call
      res = exchange.deposit(user_id: user, asset: asset, amount: amount)
      puts "[#{ts}] #{c('DEPOSIT', :green)} user=#{user} asset=#{asset} amount=#{format_asset_amount(asset, amount)} => #{JSON.pretty_generate(res)}"

    when :withdraw
      asset = %w[USDT BTC].sample
      amount = asset == 'USDT' ? rand_usdt_amount.call : rand_btc_amount.call
      res = exchange.withdraw(user_id: user, asset: asset, amount: amount)
      puts "[#{ts}] #{c('WITHDRAW', :magenta)} user=#{user} asset=#{asset} amount=#{format_asset_amount(asset, amount)} => #{JSON.pretty_generate(res)}"

    when :cancel_one
      if placed_order_ids.empty?
        puts "[#{ts}] #{c('CANCEL', :yellow)} skip (no known resting orders)"
      else
        target = placed_order_ids.sample
        res = exchange.cancel_order(target)
        puts "[#{ts}] #{c('CANCEL', :yellow)} id=#{target} => #{JSON.pretty_generate(res)}"
        # Remove from list if cancelled or not found
        if res[:status] == 'CANCELLED' || res[:error] == 'NOT_FOUND'
          placed_order_ids.delete(target)
        end
      end
    end
  rescue => e
    puts "[#{ts}] #{c('ERROR', :bold, :red)} op=#{op} user=#{user} msg=#{e.class}: #{e.message}"
    puts e.backtrace.take(3).join("\n")
  end

  delay = rand(options[:sleep_min]..options[:sleep_max])
  sleep(delay)
end

puts c('[DONE]', :green)