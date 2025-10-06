# Redis Exchange

Redis Exchange is a Ruby gem that bundles a Redis-backed central limit order book. All state lives in Redis hashes, sorted sets, and lists, while a Lua script performs atomic matching for both limit and market orders.

## Features

- Lua matching engine stored in `redis_scripts/match_order.lua`
- Atomic cancellation scripts for single orders (`redis_scripts/cancel_order.lua`) and bulk user cancellations (`redis_scripts/cancel_all_orders.lua`)
- Ruby client (`RedisExchange::Client`) for seeding markets, managing balances, submitting limit/market orders, cancelling orders, and querying tickers
- Per-market ticker hash exposing last trade plus top-of-book bid/ask
- RSpec suite covering core behaviours (resting limit orders, market order execution)
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

## Development

Ensure Redis 6+ is running locally. Install gem dependencies and run specs:

```bash
bundle install
bundle exec rspec
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

## License

MIT
