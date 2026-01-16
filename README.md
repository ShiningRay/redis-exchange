# Redis Exchange

Redis Exchange is a Ruby gem that bundles a Redis-backed central limit order book. All state lives in Redis hashes, sorted sets, and lists, while a Lua script performs atomic matching for both limit and market orders.

## Features

- Lua matching engine stored in `redis_scripts/match_order.lua`
- Unified atomic balance operations (`redis_scripts/balance_op.lua`) supporting LOCK, UNLOCK, ADD, SUB
- Atomic cancellation scripts (`redis_scripts/cancel_order.lua`) and bulk cancellations (`redis_scripts/cancel_all_orders.lua`)
- Ruby client (`RedisExchange::Client`) for seeding markets, managing balances, submitting orders, and querying tickers
- Comprehensive maintenance tools: balance audit, ledger replay, market precision updates
- Per-market ticker hash exposing last trade plus top-of-book bid/ask
- RSpec suite covering core behaviours (matching, balance ops, audits)
- Documentation of Redis data layout in [`docs/architecture.md`](docs/architecture.md)

## Installation

Add this line to your application's `Gemfile`:

```ruby
gem 'redis_exchange', path: 'path/to/redis-exchange'
```

Then run `bundle install`. Alternatively, build and install locally:

```bash
gem build redis_exchange.gemspec
gem install redis_exchange-0.1.0.gem
```

## Usage

```ruby
require 'redis'
require 'redis_exchange'

redis    = Redis.new(host: '127.0.0.1', port: 6379)
exchange = RedisExchange::Client.new(redis: redis)

exchange.seed_market(
  symbol: 'BTCUSDT',
  base_asset: 'BTC',
  quote_asset: 'USDT',
  price_scale: 100,
  quantity_scale: 100_000_000,
  maker_fee_bps: 5,
  taker_fee_bps: 10,
  min_qty: 100_000,
  min_notional: 1_000
)

exchange.set_balance(user_id: 'alice', asset: 'USDT', available: 1_000_000)
exchange.set_balance(user_id: 'bob', asset: 'BTC', available: 100_000_000)

# Or use the new atomic balance operations:
exchange.operate_balance(user_id: 'alice', asset: 'USDT', action: 'ADD', amount: 500_000)
exchange.lock_funds(user_id: 'bob', asset: 'BTC', amount: 10_000_000)
exchange.unlock_funds(user_id: 'bob', asset: 'BTC', amount: 5_000_000)

# Bob posts a sell limit order.
exchange.place_limit_order(
  symbol: 'BTCUSDT',
  side: 'SELL',
  order_id: 'sell-1',
  user_id: 'bob',
  price: 3_000_000,
  quantity: 100_000_000
)

# Later Bob can cancel the resting order and release his BTC:
exchange.cancel_order('sell-1')

# Cancel every open order for Bob in one shot:
cancellations = exchange.cancel_all_orders('bob')
# => array of hashes describing each cancelled order

# Inspect the current order book snapshot (bids and asks arrays):
book = exchange.order_book('BTCUSDT', limit: 5)
pp book

# Alice crosses the book with a market buy capped at 31,000 USDT.
response = exchange.place_market_order(
  symbol: 'BTCUSDT',
  side: 'BUY',
  order_id: 'buy-1',
  user_id: 'alice',
  quantity: 50_000_000,
  price_cap: 3_100_000
)

puts response # JSON parsed into a Ruby hash

# Retrieve ticker information (last trade, best bid/ask).
p exchange.ticker('BTCUSDT')

# Retrieve an order snapshot by id with typed fields
pp exchange.order('sell-1')
```

### Auto-connect without providing `redis`

You can omit the `redis` parameter and the client will auto-connect using `ENV['REDIS_URL']` or fall back to `redis://127.0.0.1:6379/0`.

```ruby
# Uses ENV['REDIS_URL'] if set; otherwise connects to local Redis db 0
exchange = RedisExchange::Client.new
```

## Consuming Trade Stream

Each market emits executed trades to a Redis Stream `trades:{symbol}` inside the Lua script. You can use the built-in consumer helper to process and persist trades reliably:

```ruby
consumer = exchange.trade_consumer(symbol: 'BTCUSDT', group: 'trades-consumers', consumer: 'worker-1')

# Simple blocking loop with explicit read + ack
loop do
  entries = consumer.read(count: 100, block_ms: 2000)
  entries.each do |e|
    # e.id is the Redis Stream entry id (e.g., "1707389234567-0")
    fields = e.fields # Hash of strings: { 'taker_order_id' => '...', 'price' => '3000000', ... }

    # Persist with idempotency: use e.id as unique key in your DB
    # Convert numeric fields to integers before saving
    # On success:
    consumer.ack(e.id)
  end
end

# Or use the convenience each to drive the loop
consumer.each(count: 100, block_ms: 2000, auto_ack: true) do |e|
  # fields = e.fields
  # Persist with idempotency and type conversions as needed
  # Return :halt to break the loop if desired
  # return :halt if shutdown?
end
```

Recommended persistence design:
- Use `stream_entry_id` unique constraint for idempotency
- Store scaled integer fields as `bigint` (price, quantity, quote, fees)
- Save `executed_ts_ms` from `fields['ts']` as bigint

`ticker` returns a hash of integers keyed by `:last_price`, `:last_quantity`, `:best_bid_price`, `:best_bid_volume`, `:best_ask_price`, `:best_ask_volume`, and more for quick UI snapshots.

## Consuming Order Stream

Each market emits order lifecycle events to `orders:{symbol}` (OPEN, PARTIALLY_FILLED, FILLED, CANCELLED, NO_LIQUIDITY). Use the built-in helper to consume reliably:

```ruby
consumer = exchange.order_consumer(symbol: 'BTCUSDT', group: 'orders-consumers', consumer: 'worker-1')

# Explicit read + ack style
loop do
  entries = consumer.read(count: 100, block_ms: 2000)
  entries.each do |e|
    fields = e.fields # { 'order_id' => '...', 'status' => 'CANCELLED', 'price' => '3000000', ... }

    # Persist with idempotency: use e.id as unique key in your DB
    # Convert numeric fields to integers before saving
    consumer.ack(e.id)
  end
end

# Or use the convenience each to drive the loop
consumer.each(count: 100, block_ms: 2000, auto_ack: true) do |e|
  # fields = e.fields
  # Persist then optional halt
  # return :halt if shutdown?
end
```

See `script/orders_demo.rb` for a runnable example.

## Consuming Account Ledger

Append-only account changes are published to the `account_ledger` Redis Stream. Use the built-in consumer to reliably process changes with consumer groups and idempotent persistence:

```ruby
consumer = exchange.ledger_consumer(group: 'ledger-consumers', consumer: 'worker-1')

# Explicit read + ack style
loop do
  entries = consumer.read(count: 100, block_ms: 2000)
  entries.each do |e|
    fields = e.fields # { 'user_id' => 'u1', 'asset' => 'USDT', 'action' => 'ADD', 'amount' => '1000', 'reason' => 'DEPOSIT', 'ts' => '...', 'sequence' => '1', 'biz_id' => '...' }

    # Persist with idempotency: use e.id as unique key in your DB
    # Convert numeric fields to integers before saving
    consumer.ack(e.id)
  end
end

# Or use the convenience each to drive the loop
consumer.each(count: 100, block_ms: 2000, auto_ack: true) do |e|
  # fields = e.fields
  # Persist then optional halt
  # return :halt if shutdown?
end
```

Fields of each ledger entry:
- `user_id` (String)
- `asset` (String)
- `action` (String: `LOCK`, `UNLOCK`, `ADD`, `SUB`, `SUB_LOCKED`, `ADD_LOCKED`)
- `amount` (String integer; scaled; always positive)
- `reason` (String)
- `ts` (String integer; milliseconds)
- `sequence` (String integer; per user+asset incremental)
- `biz_id` (String; idempotency key; auto-generated if not provided)

## Development

Ensure Redis 6+ is running locally. Install gem dependencies and run specs:

```bash
bundle install
bundle exec rspec
```

## Account Ledger & Balance Helpers

Convenience helpers are provided for managing funds and direct balance operations. All changes are executed atomically via Lua and emit events to the `account_ledger` stream.

```ruby
exchange = RedisExchange::Client.new(redis: Redis.new)

# Add 100 USDT (scaled integer) - internally calls operate_balance with action=ADD
exchange.add_funds(user_id: 'u1', asset: 'USDT', amount: 100_000)

# Subtract 50 USDT - internally calls operate_balance with action=SUB
exchange.sub_funds(user_id: 'u1', asset: 'USDT', amount: 50_000)

# Subtract 10 USDT from locked (reserved) balance - internally calls operate_balance with action=SUB_LOCKED
exchange.sub_locked_funds(user_id: 'u1', asset: 'USDT', amount: 10_000)

# Lock funds (move from available to reserved)
exchange.lock_funds(user_id: 'u1', asset: 'USDT', amount: 10_000, reason: 'ORDER_RESERVE')

# Unlock funds (move from reserved to available)
exchange.unlock_funds(user_id: 'u1', asset: 'USDT', amount: 5_000, reason: 'CANCEL_REFUND')
```

Each ledger entry includes: `user_id`, `asset`, `action`, `amount`, `reason`, `ts`, `sequence`, `biz_id`.

Idempotency: `operate_balance` (and helpers like `add_funds`/`sub_funds`) accepts an optional `biz_id` to deduplicate requests. When provided, the Redis Lua script returns a cached response for the same `{user_id, asset, action, biz_id}` within 24 hours and does not append a duplicate ledger entry or re-apply the balance mutation.

```ruby
# Using biz_id to prevent duplicate submissions
biz_id = 'req-123'
exchange.operate_balance(user_id: 'u1', asset: 'USDT', action: 'ADD', amount: 50_000, reason: 'MANUAL_ADJUST', biz_id: biz_id)
# A repeated call with the same biz_id returns the same response and does not duplicate effects
exchange.operate_balance(user_id: 'u1', asset: 'USDT', action: 'ADD', amount: 50_000, reason: 'MANUAL_ADJUST', biz_id: biz_id)
```

If `biz_id` is omitted, the client auto-generates a UUID and includes it in the response as `:biz_id`; the ledger entry will also carry this generated `biz_id`. Internally generated events (e.g., matching/cancellation) attach an auto `biz_id` as well.

## Random Bot (Stress Test)

A random trading bot is included for stress testing and verification. It performs random balance operations (add/sub), limit orders, and market orders while validating ledger consistency.

```bash
# Run with default settings (100 iterations, 1 concurrent thread)
ruby script/random_bot.rb

# Run heavily concurrent load (5 threads, 1000 iterations each) with final audit
ruby script/random_bot.rb --concurrency 5 --iterations 1000 --audit

# Options:
#   --redis-url URL       Redis connection string
#   --symbol SYMBOL       Market symbol (default: BTCUSDT)
#   --iterations N        Number of operations per thread
#   --concurrency N       Number of concurrent worker threads
#   --audit               Run full balance audit and ledger replay check after completion
#   --audit-interval N    (Single-thread only) Run partial replay audit every N operations
#   --no-seed             Skip initial asset/market seeding
#   --flush               Flush DB before starting
```

## Benchmarking

Run the provided script to gauge Lua matching throughput. The script seeds a sell book and executes BUY market orders while reporting runtime and derived orders-per-second metrics. The benchmark requires a real Redis instance; set `--redis-url` (or `BENCH_REDIS_URL`) accordingly. **Warning:** the chosen database is flushed before each run.

```bash
# Against a specific Redis host
BENCH_REDIS_URL=redis://127.0.0.1:6379/15 \
  ruby script/benchmark_matching.rb --resting=10_000 --taker=10_000 --price=3_000_000
```

The script prints total time and computed orders/sec. Tune `--price`, `--quantity`, or `--symbol` to match your production scales.

## Numeric Precision

Redis executes Lua with 64-bit floating point numbers. Keep scaled prices, quantities, and their product (`price * quantity`) below roughly 9e15 to avoid rounding in `math.floor` and fee calculations. Adjust `price_scale` and `quantity_scale` to respect this bound.

## Lua Script Contract

`match_order.lua` expects eight keys (market metadata, sequence counter, book/volume hashes, taker balance hash, and the trade stream) and eight arguments (`symbol`, `side`, `order_type`, `order_id`, `user_id`, `price_limit`, `quantity`, `timestamp_ms`). `price_limit` represents the order price for limit orders or an optional cap (0 means uncapped) for market orders. The script returns a JSON blob describing execution outcome and taker cash flows; validation failures return an object with an `error` field.

## Testing Notes

- Extend the RSpec suite with additional edge cases (partial fills, insufficient balance branches, multi-level sweeps).
- Consider using `fakeredis` for unit tests that do not require a live server.
- For integration coverage, run concurrent clients to validate atomic behaviour under contention.

## Asset & Market Configuration

Before placing orders, configure asset precision and market parameters. Balances and ledger entries use per-asset minor units (`balance_scale`), while matching uses per-market scales (`price_scale`, `quantity_scale`).

```ruby
exchange = RedisExchange::Client.new(redis: Redis.new)

# Configure assets (balance scales and status)
exchange.seed_asset(asset: 'BTC',  balance_scale: 100_000_000, status: 'ACTIVE')
exchange.seed_asset(asset: 'USDT', balance_scale: 100,         status: 'ACTIVE')

# Configure market (price/quantity scales, fees, thresholds, and status)
exchange.seed_market(
  symbol: 'BTCUSDT',
  base_asset: 'BTC',
  quote_asset: 'USDT',
  price_scale: 100,
  quantity_scale: 100_000_000,
  maker_fee_bps: 5,
  taker_fee_bps: 10,
  min_qty: 100_000,
  min_notional: 1_000,
  status: 'OPEN' # OPEN | HALTED | CLOSED | MAINTENANCE
)
```

### Scale Compatibility Rules

To guarantee integer conversions without rounding:
- Base asset balance scale must be a multiple of `quantity_scale`.
- Quote asset balance scale must be a multiple of `price_scale`.

If violated, order placement returns:
- `ASSET_NOT_CONFIGURED` when the asset configuration is missing.
- `ASSET_SCALE_MISMATCH` when the asset balance scale does not evenly divide the market scale. Returned fields include `asset`, `balance_scale`, and `market_scale`.

### Market Status Semantics

- `OPEN`: normal operation; order placement and cancellation allowed.
- `HALTED`: new limit/market orders are rejected with `MARKET_HALTED`; cancellations are **allowed**.
- `CLOSED`: new limit/market orders are rejected with `MARKET_CLOSED`; cancellations are **allowed**.
- `MAINTENANCE`: all operations (including cancellation) are rejected with `MARKET_MAINTENANCE`. Used for atomic operations like snapshotting or precision updates.

### Force Cancellation (Maintenance Mode)

During maintenance (or for emergency cleanup), `force_cancel_order` can be used to remove orders regardless of market status.

```ruby
# Mode 1: Delete only (no balance changes)
exchange.maintenance.force_cancel_order(order_id: 'o-1', mode: :delete_only)

# Mode 2: Best-effort unlock (refunds reserved balance if available)
exchange.maintenance.force_cancel_order(order_id: 'o-1', mode: :best_effort_unlock)
```

### Balance Audit

To prevent accounting errors, you can audit and reconcile user reserved balances against active orders.

```bash
# Audit all users and automatically fix discrepancies (release surplus / lock deficit)
bundle exec rake audit:balances

# Dry-run mode (report only, no changes)
bundle exec rake audit:balances FIX=false

# Audit a specific user
bundle exec rake audit:balances USER_ID=user-123
```

The audit process:
1. Scans all active orders for the user(s).
2. Calculates the required reserved balance for each asset.
3. Compares with the actual `reserved` balance in Redis.
4. If `Required > Actual`: Locks available funds to cover the deficit. If available funds are insufficient, reports a deficit.
5. If `Required < Actual`: Releases the surplus reserved funds back to available.
6. Emits ledger entries for all adjustments (`AUDIT_FIX_LOCK` / `AUDIT_FIX_RELEASE`).

Example rejection when market is halted:
```ruby
exchange.seed_market(
  symbol: 'BTCUSDT', base_asset: 'BTC', quote_asset: 'USDT',
  price_scale: 100, quantity_scale: 100_000_000,
  status: 'HALTED'
)

res = exchange.place_limit_order(
  symbol: 'BTCUSDT', side: 'SELL', order_id: 'o-1', user_id: 'bob',
  price: 3_000_000, quantity: 100_000_000
)
# => { error: 'MARKET_HALTED' }
```

## License

MIT
