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

**Requirements:** Ruby >= 3.0 (CI verifies 3.2, 3.4 and 4.0), Redis >= 6.

Add this line to your application's `Gemfile`:

```ruby
gem 'redis_exchange', path: 'path/to/redis-exchange'
```

Then run `bundle install`. Alternatively, build and install locally:

```bash
gem build redis_exchange.gemspec
gem install redis_exchange-0.1.0.gem
```

### TypeScript / Node.js

A TypeScript client (`redis-exchange` on npm, same Lua scripts and Redis key contract) lives in this repository under `src/`:

```bash
npm install        # install deps at the repo root
npm run build      # emit dist/
npm test           # vitest smoke suite against a disposable Redis DB
```

```ts
import { Client } from 'redis-exchange';

const client = new Client({ redisUrl: 'redis://127.0.0.1:6379/0' });
await client.seedMarket({ symbol: 'BTCUSDT', baseAsset: 'BTC', quoteAsset: 'USDT', priceScale: 100, quantityScale: 100_000_000 });
await client.addFunds({ userId: 'alice', asset: 'USDT', amount: 1_000_000 });
const result = await client.placeLimitOrder({
  symbol: 'BTCUSDT',
  side: 'BUY',
  orderId: 'ord-1',
  userId: 'alice',
  price: 30_000 * 100,
  quantity: 100_000_000,
});
```

Numeric conventions match the Ruby gem exactly: amounts are integer minor units in the asset's `balance_scale`, prices/quantities use the market's `price_scale`/`quantity_scale` multipliers, and all values must stay below 9e15 to fit Lua doubles.

Stream consumers are included as well, mirroring the Ruby gem's `StreamConsumer` base plus the order/trade/depth/ledger specializations:

```ts
import { Client } from 'redis-exchange';

const client = new Client({ redisUrl: 'redis://127.0.0.1:6379/0' });
const trades = await client.tradeConsumer({ symbol: 'BTCUSDT', group: 'trades-writer', consumer: `worker-${process.pid}` });
await trades.each(
  async (entry) => {
    console.log(entry.id, entry.fields);
  },
  { autoAck: true },
);
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

# Monitor real-time order book changes
# Note: This method blocks execution. Run in a separate thread.
exchange.monitor_order_book(symbol: 'BTCUSDT') do |event, side|
  # event: 'zadd' (new order/price level), 'zrem' (level removed), etc.
  # side: 'BUY' or 'SELL'
  puts "Book update: #{side} #{event}"
end
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

# CI shape: dense ops without sleeps, quiet logs; exits non-zero if any audit fails
ruby script/random_bot.rb --flush --concurrency 5 --iterations 1000 \
  --sleep-min 0 --sleep-max 0 --quiet --audit

# Options:
#   --redis-url URL       Redis connection string
#   --symbol SYMBOL       Market symbol (default: BTCUSDT)
#   --iterations N        Number of operations per thread
#   --concurrency N       Number of concurrent worker threads
#   --audit               Run full balance audit and ledger replay check after completion;
#                         exits with status 1 if any check fails
#   --audit-interval N    (Single-thread only) Run partial replay audit every N operations
#   --quiet               Suppress per-operation output (INIT/AUDIT/ERROR only)
#   --no-seed             Skip initial asset/market seeding
#   --flush               Flush DB before starting
```

## Benchmarking

Two scripts are provided. Both need a real Redis instance and **flush the target database** on start; point them at a throwaway instance (`docker run -d -p 6390:6379 redis:8-alpine redis-server --save '' --appendonly no`).

### Full suite — `script/benchmark_suite.rb`

Covers the paths a real deployment exercises: book building across price levels, crossing limit orders, market orders that walk N levels, single and bulk cancellation, balance lock/unlock, book/ticker reads, a realistic mixed workload, and multi-client contention. Every scenario reports p50/p90/p99/max latency, client throughput, error codes, and the Redis command count per operation.

```bash
ruby script/benchmark_suite.rb --redis-url=redis://127.0.0.1:6390/0 \
  --depth=10000 --batch=2000 --levels=100 --sweep-levels=5 --sweep-ops=100 \
  --duration=30 --clients=4 --json=tmp/bench.json
```

Run `--only=book_build,concurrent` to select scenarios, or `--help` for all flags. The script also seeds `asset:*` keys — without them every order is rejected with `ASSET_NOT_CONFIGURED` before the Lua matcher runs, and a benchmark would silently measure the rejection path.

Latest measured results and analysis: [`docs/benchmarks/2026-10-23-benchmark-suite.md`](docs/benchmarks/2026-10-23-benchmark-suite.md).

### Single-scenario smoke test — `script/benchmark_matching.rb`

A minimal throughput probe: seeds a sell book at one price and fires BUY market orders at it.

```bash
BENCH_REDIS_URL=redis://127.0.0.1:6379/15 \
  ruby script/benchmark_matching.rb --resting=10_000 --taker=10_000 --price=3_000_000
```

It prints total time and computed orders/sec, but it does **not** seed `asset:*` and does not check results, so on its own it measures the pre-flight rejection path rather than matching — use the full suite for numbers you intend to quote. Tune `--price`, `--quantity`, or `--symbol` to match your production scales.

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

## Error Codes

All error responses are returned as a Hash with an `error` key:

```ruby
{ error: 'ERROR_CODE' }
```

### System/Market Status Errors

| Error Code | Description |
|-----------|-------------|
| `SYSTEM_MAINTENANCE` | System-wide maintenance mode enabled |
| `MARKET_MAINTENANCE` | Market is in maintenance mode |
| `MARKET_HALTED` | Market is halted (orders rejected, cancellations allowed) |
| `MARKET_CLOSED` | Market is closed (orders rejected, cancellations allowed) |

### Argument Validation Errors

| Error Code | Description |
|-----------|-------------|
| `INVALID_ARGUMENTS` | Invalid number or type of arguments provided |
| `INVALID_ORDER_TYPE` | Invalid order type (must be LIMIT or MARKET) |
| `INVALID_SIDE` | Invalid order side (must be BUY or SELL) |
| `INVALID_PRICE_OR_QUANTITY` | Invalid price or quantity value |
| `INVALID_AMOUNT` | Invalid amount for balance operation |
| `INVALID_ACTION` | Invalid balance action type |
| `INVALID_ORDER` | Invalid order state or data |

### Order Errors

| Error Code | Description |
|-----------|-------------|
| `DUPLICATE_ORDER_ID` | Order ID already exists |
| `UNKNOWN_MARKET` | Market configuration not found |

### Asset Errors

| Error Code | Description |
|-----------|-------------|
| `ASSET_NOT_CONFIGURED` | Asset configuration not found |
| `ASSET_SCALE_MISMATCH` | Asset balance scale incompatible with market configuration |
| `ASSET_SCALE_MISMATCH_WITH_NEW_CONFIG` | Asset scale mismatch during precision update |

### Trading Rule Errors

| Error Code | Description |
|-----------|-------------|
| `MIN_QTY_NOT_SATISFIED` | Order quantity below minimum required |
| `MIN_NOTIONAL_NOT_SATISFIED` | Order notional value below minimum required |
| `PRECISION_OVERFLOW` | Precision overflow in calculation |

### Balance Errors

| Error Code | Description | Additional Fields |
|-----------|-------------|-------------------|
| `INSUFFICIENT_FUNDS` | Insufficient funds for operation | `asset`, `bucket` |
| `INSUFFICIENT_FUNDS_TO_REST` | Insufficient funds to place order | `asset` |

## License

MIT
