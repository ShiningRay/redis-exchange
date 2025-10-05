# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Redis Exchange Overview

Redis Exchange is a Ruby gem implementing a Redis-backed central limit order book (CLOB). The matching engine is entirely implemented in Lua scripts to ensure atomicity, with Redis data structures providing the persistent state. All prices, quantities, and balances are stored as scaled integers to avoid floating-point precision issues.

## Core Architecture

### Lua-First Design
- **Atomic operations**: All order matching happens inside single Lua scripts (match_order.lua)
- **Three core scripts**: 
  - `redis_scripts/match_order.lua` - Main matching engine
  - `redis_scripts/cancel_order.lua` - Single order cancellation
  - `redis_scripts/cancel_all_orders.lua` - Bulk user order cancellation
- **Ruby client layer**: `RedisExchange::Client` provides high-level API over the Lua scripts

### Data Model (Redis Keys)
- Markets: `market:{symbol}` - hash containing metadata (scales, fees, minimums)
- Balances: `balance:{user_id}` - hash with `{asset}:available` and `{asset}:reserved` fields  
- Order books: `book:{symbol}:{BUY|SELL}` - sorted sets for price discovery
- Price queues: `queue:{symbol}:{side}:{price}` - FIFO lists of order IDs at each price level
- Volume tracking: `volume:{symbol}:{side}` - hash mapping price -> remaining quantity
- Orders: `order:{order_id}` - individual order details
- Trades: `trades:{symbol}` - stream/list of executed trades
- Tickers: `ticker:{symbol}` - hash with last trade and best bid/ask

### Numeric Precision Rules
- All values stored as scaled integers (price_scale, quantity_scale from market metadata)
- Keep `price * quantity` products below ~9e15 to avoid Lua double precision issues
- Example: BTCUSDT with price_scale=100 (cents), quantity_scale=100_000_000 (satoshis)

## Development Commands

### Dependencies and Setup
```bash
bundle install                    # Install gem dependencies
```

### Testing
```bash
bundle exec rspec                 # Run full test suite
bundle exec rspec spec/redis_exchange_spec.rb  # Run specific test file

# Test with custom Redis (default uses database 15):
SPEC_REDIS_URL=redis://127.0.0.1:6379/0 bundle exec rspec
```

### Benchmarking
```bash
# Basic benchmark (uses in-memory shim):
ruby script/benchmark_matching.rb --resting=1000 --taker=1000

# Against real Redis instance:
BENCH_REDIS_URL=redis://127.0.0.1:6379/15 \
  ruby script/benchmark_matching.rb --resting=10000 --taker=10000 --price=3000000

# See all benchmark options:
ruby script/benchmark_matching.rb --help
```

### Building and Installation
```bash
gem build redis_exchange.gemspec
gem install redis_exchange-0.1.0.gem
```

## Key Components

### RedisExchange::Client API
- `seed_market()` - Create/update market configuration
- `set_balance()` - Set user asset balances
- `place_limit_order()` - Submit limit orders (price required)
- `place_market_order()` - Submit market orders (optional price_cap)  
- `cancel_order(order_id)` - Cancel single order
- `cancel_all_orders(user_id)` - Cancel all user orders
- `ticker(symbol)` - Get market snapshot (last trade + top of book)
- `order_book(symbol, limit:)` - Get current bid/ask levels
- `balances(user_id)` - Get user balance breakdown

### Lua Script Contract
The `match_order.lua` expects:
- **8 KEYS**: market metadata, sequence, buy/sell books, buy/sell volumes, user balance, trades
- **8 ARGV**: symbol, side, order_type, order_id, user_id, price_limit, quantity, timestamp_ms
- **Returns**: JSON blob with execution results or error details

## Testing Approach

### Test Database
- Tests use Redis database 15 by default (configurable via `SPEC_REDIS_URL`)
- Each test flushes the database for isolation
- Tests verify both Redis state and Ruby client responses

### Key Test Patterns
- **Resting orders**: Verify limit orders enter the book correctly
- **Market execution**: Test market orders against existing liquidity
- **Cancellations**: Both single and bulk cancellation flows
- **Balance accounting**: Verify available/reserved balance transitions
- **Error conditions**: Insufficient funds, duplicate order IDs, invalid parameters

### Extending Tests
- Add edge cases for partial fills and multi-level sweeps
- Test concurrent access patterns to validate atomicity
- Consider using `fakeredis` for pure unit tests

## Development Environment

### Redis Requirements
- Redis 6+ required (for Lua script features)
- Default connection: `redis://127.0.0.1:6379/15`
- Benchmark warning: Target database is flushed before runs

### Ruby Version
- Minimum Ruby 3.0 (specified in gemspec)
- Dependencies: `redis` gem >= 5.0, `rspec` >= 3.12 for development

## File Structure Context

- `lib/redis_exchange.rb` - Main client implementation with Lua script loading
- `lib/redis_exchange/version.rb` - Gem version constant
- `redis_scripts/` - All Lua matching logic  
- `docs/architecture.md` - Detailed Redis data model documentation
- `spec/` - RSpec test suite with full coverage of core behaviors
- `script/benchmark_matching.rb` - Performance testing tool

## Common Development Patterns

### Market Setup
```ruby
exchange.seed_market(
  symbol: 'BTCUSDT',
  base_asset: 'BTC', quote_asset: 'USDT',
  price_scale: 100, quantity_scale: 100_000_000,
  maker_fee_bps: 5, taker_fee_bps: 10
)
```

### Balance Management
```ruby
exchange.set_balance(user_id: 'alice', asset: 'USDT', available: 1_000_000)
```

### Order Flow
```ruby
# Limit order (goes to book if no match)
exchange.place_limit_order(symbol: 'BTCUSDT', side: 'SELL', 
  order_id: 'sell-1', user_id: 'bob', price: 3_000_000, quantity: 100_000_000)

# Market order (executes immediately or gets rejected)  
exchange.place_market_order(symbol: 'BTCUSDT', side: 'BUY',
  order_id: 'buy-1', user_id: 'alice', quantity: 50_000_000, price_cap: 3_100_000)
```