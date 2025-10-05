# Redis Exchange

Redis Exchange is a Ruby gem that bundles a Redis-backed central limit order book. All state lives in Redis hashes, sorted sets, and lists, while a Lua script performs atomic matching for both limit and market orders.

## Features

- Lua matching engine stored in `redis_scripts/match_order.lua`
- Ruby client (`RedisExchange::Client`) for seeding markets, managing balances, submitting limit/market orders, and querying tickers
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
```

`ticker` returns a hash of integers keyed by `:last_price`, `:last_quantity`, `:best_bid_price`, `:best_bid_volume`, `:best_ask_price`, `:best_ask_volume`, and more for quick UI snapshots.

## Development

Ensure Redis 6+ is running locally. Install gem dependencies and run specs:

```bash
bundle install
bundle exec rspec
```

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
