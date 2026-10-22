#!/usr/bin/env ruby
# frozen_string_literal: true

# Comprehensive benchmark suite for redis-exchange.
#
# script/benchmark_matching.rb measures one path only: a book built at a single
# price, one taker per resting order, average throughput, no percentiles. This
# suite covers the paths a real deployment exercises:
#
#   1. book_build   sustained non-crossing limit placement spread over N price levels
#   2. match_limit  crossing limit orders filling against the best level
#   3. market_sweep market orders sized to walk K price levels
#   4. cancel       single-order cancellation
#   5. cancel_all   bulk cancellation for one user
#   6. balance_op   lock/unlock cycle (runs on every order in production)
#   7. reads        order_book(limit: 20) + ticker
#   8. mixed        realistic blend of the above, single client
#   9. concurrent   the same blend across C clients (contention / connection churn)
#
# Each scenario reports the full latency distribution (p50/p90/p99/max),
# client-observed throughput, error counts, and Redis server-side command counts
# for the window, so Lua time can be separated from client round-trips.
#
# WARNING: this script FLUSHES the target Redis database.
#
# Usage:
#   ruby script/benchmark_suite.rb --redis-url=redis://127.0.0.1:6390/0 --json=tmp/bench.json

begin
  require 'bundler/setup'
rescue LoadError, StandardError
  # Running outside a bundled environment (e.g. gems installed globally) is fine
  # for a benchmark; fall through and require what we need directly.
  nil
end

require 'optparse'
require 'json'
require 'time'
require 'redis'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'redis_exchange'

DEFAULTS = {
  redis_url: ENV['BENCH_REDIS_URL'] || 'redis://127.0.0.1:6390/0',
  symbol: 'TRXUSDT',
  depth: 5_000,
  levels: 50,
  batch: 1_000,
  sweep_levels: 5,
  sweep_ops: 100,
  clients: 4,
  duration: 15,
  json: nil,
  only: nil,
  label: nil
}.freeze

BASE_ASSET = 'TRX'
QUOTE_ASSET = 'USDT'
PRICE_SCALE = 100                 # 2 dp  -> MID_PRICE 2500 == 25.00 USDT
QUANTITY_SCALE = 100_000_000      # 8 dp  -> LEVEL_QTY 100_000 == 0.001 TRX
MID_PRICE = 2_500                 # 25.00 USDT
TICK = 10                         # 0.10 USDT between levels
LEVEL_QTY = 100_000
SWEEP_ORDERS_PER_LEVEL = 20       # fixed book shape for the sweep scenario
SEED_LEVELS = 100
QUOTE_FUNDS = 5 * (10**15)
BASE_FUNDS = 10**12
MIX_WEIGHTS = [%w[rest 55], %w[cancel 20], %w[cross 15], %w[market 5], %w[read 5]].freeze

options = DEFAULTS.dup

OptionParser.new do |p|
  p.banner = <<~BANNER
    Usage: ruby script/benchmark_suite.rb [options]

    Full redis-exchange benchmark suite. FLUSHES the target database.

    Scenarios: book_build, match_limit, market_sweep, cancel, cancel_all,
               balance_op, reads, mixed, concurrent
  BANNER

  p.on('--redis-url=URL', 'Redis target (default: BENCH_REDIS_URL or redis://127.0.0.1:6390/0)') { |v| options[:redis_url] = v }
  p.on('--symbol=SYM', "Market symbol (default: #{DEFAULTS[:symbol]})") { |v| options[:symbol] = v }
  p.on('--depth=N', Integer, "Resting orders for book scenarios (default: #{DEFAULTS[:depth]})") { |v| options[:depth] = v }
  p.on('--levels=N', Integer, "Price levels to spread the book over (default: #{DEFAULTS[:levels]})") { |v| options[:levels] = v }
  p.on('--batch=N', Integer, 'Measured ops for the fixed-count scenarios (default: 1000)') { |v| options[:batch] = v }
  p.on('--sweep-levels=N', Integer, 'Price levels a market order walks (default: 5)') { |v| options[:sweep_levels] = v }
  p.on('--sweep-ops=N', Integer, 'Measured market orders for the sweep scenario (default: 100)') { |v| options[:sweep_ops] = v }
  p.on('--clients=N', Integer, 'Concurrent clients for the concurrent scenario (default: 4)') { |v| options[:clients] = v }
  p.on('--duration=SEC', Integer, 'Duration for mixed/concurrent (default: 15)') { |v| options[:duration] = v }
  p.on('--only=LIST', 'Comma-separated scenario names') { |v| options[:only] = v.split(',').map(&:strip) }
  p.on('--json=PATH', 'Write raw results as JSON') { |v| options[:json] = v }
  p.on('--label=TEXT', 'Free-form label recorded in the output') { |v| options[:label] = v }
  p.on('-h', '--help', 'Show this help') { puts p; exit }
end.parse!

SYMBOL = options[:symbol]
ALL_SCENARIOS = %w[book_build match_limit market_sweep cancel cancel_all balance_op reads mixed concurrent].freeze
selected = options[:only] || ALL_SCENARIOS
unknown = selected - ALL_SCENARIOS
abort("[bench] unknown scenario(s): #{unknown.join(', ')}") unless unknown.empty?

# ---------------------------------------------------------------- utilities

def new_redis(url)
  r = Redis.new(url: url)
  r.ping
  r
end

def now_ms
  Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
end

def pct(sorted, q)
  return 0.0 if sorted.empty?

  sorted[((sorted.length - 1) * q).round]
end

# Collects per-call latencies and error codes; used for every scenario.
class Recorder
  attr_reader :latencies, :errors

  def initialize
    @latencies = []
    @errors = Hash.new(0)
  end

  def observe(ms, result = nil)
    @latencies << ms
    @errors[result[:error].to_s] += 1 if result.is_a?(Hash) && result[:error]
    result
  end

  def count = @latencies.length

  def summary(elapsed_s, server = nil)
    sorted = @latencies.sort
    n = sorted.length
    mean = n.zero? ? 0.0 : (sorted.sum / n)
    {
      ops: n,
      elapsed_s: elapsed_s.round(4),
      ops_per_sec: elapsed_s.positive? ? (n / elapsed_s).round(1) : 0.0,
      latency_ms: {
        min: (sorted.first || 0.0).round(4),
        mean: mean.round(4),
        p50: pct(sorted, 0.50).round(4),
        p90: pct(sorted, 0.90).round(4),
        p99: pct(sorted, 0.99).round(4),
        max: (sorted.last || 0.0).round(4)
      },
      errors: @errors,
      server: server
    }
  end
end

def server_counters(redis)
  stats = redis.info('stats')
  mem = redis.info('memory')
  cpu = redis.info('cpu')
  {
    commands: stats['total_commands_processed'].to_i,
    cpu_user: cpu['used_cpu_user'].to_f,
    cpu_sys: cpu['used_cpu_sys'].to_f,
    memory: mem['used_memory_human']
  }
end

def server_delta(before, after, elapsed_s, ops)
  cmds = after[:commands] - before[:commands]
  {
    commands: cmds,
    commands_per_op: ops.positive? ? (cmds.to_f / ops).round(2) : 0.0,
    commands_per_sec: elapsed_s.positive? ? (cmds / elapsed_s).round(0) : 0,
    cpu_user_s: (after[:cpu_user] - before[:cpu_user]).round(3),
    cpu_sys_s: (after[:cpu_sys] - before[:cpu_sys]).round(3),
    used_memory: after[:memory]
  }
end

def measure(redis)
  rec = Recorder.new
  before = server_counters(redis)
  t0 = now_ms
  yield rec
  elapsed = (now_ms - t0) / 1000.0
  after = server_counters(redis)
  rec.summary(elapsed, server_delta(before, after, elapsed, rec.count))
end

# Time a single call and record it. Arguments must not be evaluated inside the
# observe() call: Ruby evaluates them before the call runs, which would record
# a latency near zero.
def timed(rec)
  t = now_ms
  res = yield
  rec.observe(now_ms - t, res)
  res
end

# ------------------------------------------------------------------- setup

def reset!(redis, client)
  redis.flushdb
  client.seed_market(
    symbol: SYMBOL, base_asset: BASE_ASSET, quote_asset: QUOTE_ASSET,
    price_scale: PRICE_SCALE, quantity_scale: QUANTITY_SCALE,
    maker_fee_bps: 5, taker_fee_bps: 10, min_qty: 1, min_notional: 1
  )
  # Every asset must be registered with a balance_scale that is an integer
  # multiple of the market's scale, otherwise execute_order rejects the order
  # with ASSET_NOT_CONFIGURED before the Lua matcher ever runs.
  client.seed_asset(asset: BASE_ASSET, balance_scale: QUANTITY_SCALE)
  client.seed_asset(asset: QUOTE_ASSET, balance_scale: QUANTITY_SCALE)
end

def fund!(client, users)
  users.each do |u|
    client.set_balance(user_id: u, asset: QUOTE_ASSET, available: QUOTE_FUNDS)
    client.set_balance(user_id: u, asset: BASE_ASSET, available: BASE_FUNDS)
  end
end

# Non-crossing resting orders: asks above mid, bids below, so nothing matches.
def build_book(client, depth:, levels:, user:, id_prefix:, sides: %w[BUY SELL])
  per_side = depth / sides.length
  sides.each_with_index do |side, si|
    per_side.times do |i|
      lvl = (i % levels) + 1
      price = side == 'SELL' ? MID_PRICE + (lvl * TICK) : MID_PRICE - (lvl * TICK)
      client.place_limit_order(
        symbol: SYMBOL, side: side, order_id: "#{id_prefix}-#{si}-#{i}",
        user_id: user, price: price, quantity: LEVEL_QTY
      )
    end
  end
end

# Realistic op mix, reused by mixed and concurrent.
def mix_iteration(client, rng, key_ring, live, i, seed, levels, stats)
  op = key_ring[rng.rand(key_ring.length)]
  t = now_ms
  case op
  when 'rest'
    lvl = (i % levels) + 1
    side = i.even? ? 'BUY' : 'SELL'
    price = side == 'SELL' ? MID_PRICE + (lvl * TICK) : MID_PRICE - (lvl * TICK)
    res = client.place_limit_order(
      symbol: SYMBOL, side: side, order_id: "#{seed}-r-#{i}",
      user_id: seed, price: price, quantity: LEVEL_QTY
    )
    stats['place'].observe(now_ms - t, res)
    live << "#{seed}-r-#{i}"
  when 'cross'
    res = client.place_limit_order(
      symbol: SYMBOL, side: 'BUY', order_id: "#{seed}-x-#{i}",
      user_id: seed, price: MID_PRICE + (levels * TICK) + TICK, quantity: LEVEL_QTY
    )
    stats['taker'].observe(now_ms - t, res)
  when 'market'
    res = client.place_market_order(
      symbol: SYMBOL, side: 'BUY', order_id: "#{seed}-m-#{i}",
      user_id: seed, quantity: LEVEL_QTY
    )
    stats['taker'].observe(now_ms - t, res)
  when 'cancel'
    oid = live.empty? ? nil : live.delete_at(rng.rand(live.length))
    if oid
      res = client.cancel_order(oid)
      stats['cancel'].observe(now_ms - t, res)
    end
  when 'read'
    client.order_book(SYMBOL, limit: 20)
    stats['read'].observe(now_ms - t)
    t2 = now_ms
    client.ticker(SYMBOL)
    stats['read'].observe(now_ms - t2)
  end
end

def merge_recorders(hashes)
  merged = Hash.new { |h, k| h[k] = Recorder.new }
  hashes.each do |h|
    h.each do |k, rec|
      rec.latencies.each { |l| merged[k].latencies << l }
      rec.errors.each { |ek, ev| merged[k].errors[ek] += ev }
    end
  end
  merged
end

# Run one client of the mixed workload until `deadline`. Kept in a method so
# every thread gets its own locals: a `Thread.new do ... end` block closes over
# the enclosing scope, so assigning `stats`/`live`/`rng`/`i` inside it mutates a
# single shared variable and every client would report into the same recorder.
def run_mix_client(redis_url, client_index, key_ring, deadline, levels)
  redis = new_redis(redis_url)
  client = RedisExchange::Client.new(redis: redis)
  rng = Random.new(1000 + client_index)
  stats = Hash.new { |h, k| h[k] = Recorder.new }
  live = []
  i = 0
  while now_ms < deadline
    mix_iteration(client, rng, key_ring, live, i, "c#{client_index}", levels, stats)
    i += 1
  end
  redis.close if redis.respond_to?(:close)
  [stats, i]
end

# --------------------------------------------------------------------- run

results = {}
meta = {
  label: options[:label],
  started_at: Time.now.utc.iso8601,
  ruby: RUBY_VERSION,
  host: (`uname -sr` rescue 'unknown').strip,
  cpus: (`nproc` rescue '?').strip,
  redis_url: options[:redis_url],
  symbol: SYMBOL,
  depth: options[:depth],
  levels: options[:levels],
  batch: options[:batch],
  sweep_levels: options[:sweep_levels],
  sweep_ops: options[:sweep_ops],
  clients: options[:clients],
  duration_s: options[:duration]
}

redis = new_redis(options[:redis_url])
meta[:redis_version] = redis.info('server')['redis_version']
meta[:redis_maxmemory] = redis.info('memory')['maxmemory_human']
meta[:redis_appendonly] = redis.info('persistence')['aof_enabled'].to_i == 1
puts "[bench] redis #{meta[:redis_version]} @ #{options[:redis_url]} (aof=#{meta[:redis_appendonly]})"
puts "[bench] ruby #{RUBY_VERSION} · symbol=#{SYMBOL} depth=#{options[:depth]} levels=#{options[:levels]}"
puts

client = RedisExchange::Client.new(redis: redis)

# 1. book_build -------------------------------------------------------------
if selected.include?('book_build')
  reset!(redis, client)
  fund!(client, ['maker'])
  print '[bench] book_build ... '
  results['book_build'] = measure(redis) do |rec|
    options[:depth].times do |i|
      side = i.even? ? 'BUY' : 'SELL'
      lvl = ((i / 2) % options[:levels]) + 1
      price = side == 'SELL' ? MID_PRICE + (lvl * TICK) : MID_PRICE - (lvl * TICK)
      timed(rec) do
        client.place_limit_order(
          symbol: SYMBOL, side: side, order_id: "bb-#{i}",
          user_id: 'maker', price: price, quantity: LEVEL_QTY
        )
      end
    end
  end
  results['book_build'][:book] = client.price_level_count(symbol: SYMBOL)
  puts "#{results['book_build'][:ops_per_sec]}/s"
end

# 2. match_limit ------------------------------------------------------------
if selected.include?('match_limit')
  reset!(redis, client)
  fund!(client, %w[maker taker])
  build_book(client, depth: options[:depth], levels: options[:levels], user: 'maker', id_prefix: 'ml', sides: %w[SELL])
  print '[bench] match_limit ... '
  results['match_limit'] = measure(redis) do |rec|
    options[:batch].times do |i|
      timed(rec) do
        client.place_limit_order(
          symbol: SYMBOL, side: 'BUY', order_id: "ml-t-#{i}",
          user_id: 'taker', price: MID_PRICE + (options[:levels] * TICK) + TICK,
          quantity: LEVEL_QTY
        )
      end
    end
  end
  puts "#{results['match_limit'][:ops_per_sec]}/s"
end

# 3. market_sweep -----------------------------------------------------------
if selected.include?('market_sweep')
  reset!(redis, client)
  fund!(client, %w[maker taker])
  sweep_levels = options[:sweep_levels]
  # Every measured order must actually walk `sweep_levels` levels, so the book
  # has to hold enough liquidity for the whole batch: batch * sweep_levels price
  # levels, each with SWEEP_ORDERS_PER_LEVEL resting orders.
  levels_needed = sweep_levels * options[:sweep_ops]
  levels_needed.times do |lvl|
    SWEEP_ORDERS_PER_LEVEL.times do |i|
      client.place_limit_order(
        symbol: SYMBOL, side: 'SELL', order_id: "ms-rest-#{lvl}-#{i}",
        user_id: 'maker', price: MID_PRICE + ((lvl + 1) * TICK), quantity: LEVEL_QTY
      )
    end
  end
  # Consume every order on the first sweep_levels-1 levels plus one order on the
  # next level, so the taker walks exactly `sweep_levels` levels.
  sweep_qty = (LEVEL_QTY * SWEEP_ORDERS_PER_LEVEL * (sweep_levels - 1)) + LEVEL_QTY
  book_before = client.price_level_count(symbol: SYMBOL)
  print "[bench] market_sweep(#{sweep_levels} levels, qty=#{sweep_qty}) ... "
  results['market_sweep'] = measure(redis) do |rec|
    options[:sweep_ops].times do |i|
      timed(rec) do
        client.place_market_order(
          symbol: SYMBOL, side: 'BUY', order_id: "ms-t-#{i}",
          user_id: 'taker', quantity: sweep_qty
        )
      end
    end
  end
  results['market_sweep'][:book_before] = book_before
  results['market_sweep'][:book_after] = client.price_level_count(symbol: SYMBOL)
  consumed = book_before[:asks].to_i - results['market_sweep'][:book_after][:asks].to_i
  per_sweep = options[:sweep_ops].positive? ? (consumed.to_f / options[:sweep_ops]) : 0.0
  results['market_sweep'][:levels_consumed_per_order] = per_sweep.round(2)
  # A sweep that walks N levels consumes N-1 whole levels and leaves the last one
  # partially filled, so the expected average is N-1.
  expected = sweep_levels - 1
  if per_sweep < (expected - 1.0)
    warn "[bench] market_sweep: only #{per_sweep.round(2)} levels consumed per order " \
         "(expected ~#{expected}) — thin liquidity, results understate the sweep path"
  end
  results['market_sweep'][:levels_per_order] = sweep_levels
  puts "#{results['market_sweep'][:ops_per_sec]}/s"
end

# 4. cancel -----------------------------------------------------------------
if selected.include?('cancel')
  reset!(redis, client)
  fund!(client, %w[maker])
  build_book(client, depth: options[:batch], levels: options[:levels], user: 'maker', id_prefix: 'cx', sides: %w[BUY])
  print '[bench] cancel ... '
  results['cancel'] = measure(redis) do |rec|
    options[:batch].times do |i|
      timed(rec) { client.cancel_order("cx-0-#{i}") }
    end
  end
  puts "#{results['cancel'][:ops_per_sec]}/s"
end

# 5. cancel_all -------------------------------------------------------------
if selected.include?('cancel_all')
  reset!(redis, client)
  fund!(client, %w[bulk])
  build_book(client, depth: options[:batch], levels: options[:levels], user: 'bulk', id_prefix: 'ca', sides: %w[BUY])
  print '[bench] cancel_all ... '
  results['cancel_all'] = measure(redis) do |rec|
    timed(rec) { client.cancel_all_orders('bulk') }
  end
  results['cancel_all'][:cancelled_orders] = options[:batch]
  puts "#{results['cancel_all'][:elapsed_s]}s total"
end

# 6. balance_op -------------------------------------------------------------
if selected.include?('balance_op')
  reset!(redis, client)
  fund!(client, %w[bal])
  print '[bench] balance_op ... '
  results['balance_op'] = measure(redis) do |rec|
    options[:batch].times do |_i|
      timed(rec) { client.lock_funds(user_id: 'bal', asset: QUOTE_ASSET, amount: 1_000) }
      timed(rec) { client.unlock_funds(user_id: 'bal', asset: QUOTE_ASSET, amount: 1_000) }
    end
  end
  puts "#{results['balance_op'][:ops_per_sec]}/s"
end

# 7. reads ------------------------------------------------------------------
if selected.include?('reads')
  reset!(redis, client)
  fund!(client, %w[maker])
  build_book(client, depth: options[:depth], levels: options[:levels], user: 'maker', id_prefix: 'rd')
  print '[bench] reads ... '
  results['reads'] = measure(redis) do |rec|
    options[:batch].times do |_i|
      timed(rec) { client.order_book(SYMBOL, limit: 20) }
      timed(rec) { client.ticker(SYMBOL) }
    end
  end
  puts "#{results['reads'][:ops_per_sec]}/s"
end

# 8. mixed ------------------------------------------------------------------
if selected.include?('mixed')
  reset!(redis, client)
  # A separate maker provides resting liquidity for the taker legs.
  fund!(client, %w[mixer seedmaker])
  build_book(client, depth: 2_000, levels: SEED_LEVELS, user: 'seedmaker', id_prefix: 'seed', sides: %w[SELL])

  key_ring = MIX_WEIGHTS.flat_map { |name, w| Array.new(w.to_i, name) }
  rng = Random.new(20261023)
  stats = Hash.new { |h, k| h[k] = Recorder.new }
  live = []
  before = server_counters(redis)
  t0 = now_ms
  deadline = t0 + (options[:duration] * 1000)
  i = 0
  while now_ms < deadline
    mix_iteration(client, rng, key_ring, live, i, 'mixer', SEED_LEVELS, stats)
    i += 1
  end
  elapsed = (now_ms - t0) / 1000.0
  after = server_counters(redis)
  total = stats.values.sum(&:count)
  results['mixed'] = {
    ops: total,
    iterations: i,
    elapsed_s: elapsed.round(4),
    ops_per_sec: (total / elapsed).round(1),
    iterations_per_sec: (i / elapsed).round(1),
    by_op: stats.transform_values { |r| r.summary(elapsed)[:latency_ms].merge(errors: r.errors) },
    errors: stats.values.map(&:errors).reduce({}) { |a, e| a.merge(e) { |_, x, y| x + y } },
    server: server_delta(before, after, elapsed, total),
    book: client.price_level_count(symbol: SYMBOL)
  }
  puts "[bench] mixed ... #{results['mixed'][:iterations_per_sec]}/s (#{total} ops)"
end

# 9. concurrent -------------------------------------------------------------
if selected.include?('concurrent')
  reset!(redis, client)
  fund!(client, %w[c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 seedmaker])
  build_book(client, depth: 2_000, levels: SEED_LEVELS, user: 'seedmaker', id_prefix: 'cseed', sides: %w[SELL])

  n = options[:clients]
  key_ring = MIX_WEIGHTS.flat_map { |name, w| Array.new(w.to_i, name) }
  print "[bench] concurrent(#{n} clients) ... "
  before = server_counters(redis)
  t0 = now_ms
  deadline = t0 + (options[:duration] * 1000)

  per_thread = Array.new(n) do |ci|
    Thread.new { run_mix_client(options[:redis_url], ci, key_ring, deadline, SEED_LEVELS) }
  end
  collected = per_thread.map(&:value)
  elapsed = (now_ms - t0) / 1000.0
  after = server_counters(redis)
  merged = merge_recorders(collected.map(&:first))
  total = merged.values.sum(&:count)
  iterations = collected.sum(&:last)
  results['concurrent'] = {
    clients: n,
    ops: total,
    iterations: iterations,
    elapsed_s: elapsed.round(4),
    ops_per_sec: (total / elapsed).round(1),
    iterations_per_sec: (iterations / elapsed).round(1),
    by_op: merged.transform_values { |r| r.summary(elapsed)[:latency_ms].merge(errors: r.errors) },
    errors: merged.values.map(&:errors).reduce({}) { |a, e| a.merge(e) { |_, x, y| x + y } },
    server: server_delta(before, after, elapsed, total),
    book: client.price_level_count(symbol: SYMBOL)
  }
  puts "#{results['concurrent'][:iterations_per_sec]}/s (#{total} ops)"
end

redis.close if redis.respond_to?(:close)

payload = { meta: meta, results: results }
if options[:json]
  require 'fileutils'
  FileUtils.mkdir_p(File.dirname(options[:json]))
  File.write(options[:json], JSON.pretty_generate(payload))
  puts
  puts "[bench] raw results -> #{options[:json]}"
end