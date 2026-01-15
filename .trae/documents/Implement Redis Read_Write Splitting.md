# Implement Redis Read/Write Splitting for Load Balancing

## Objective
Enable `RedisExchange::Client` to support separate Redis connections for read and write operations, allowing users to leverage Redis Master-Slave replication for scaling read throughput.

## Changes

### 1. Update `RedisExchange::Client#initialize`
- Add an optional `read_redis` parameter.
- If `read_redis` is provided, use it for read-only operations.
- If not provided, default `@read_redis` to the primary `@redis` connection (backward compatibility).
- Support `ENV['REDIS_READ_URL']` as a fallback default for `read_redis`.

### 2. Update Read-Only Methods to use `@read_redis`
Switch the following methods to use the read replica connection:
- **Market Data**:
    - `ticker(symbol)`
    - `order_book(symbol)`
    - `merge_depth(...)`
    - `market_config(symbol)`
    - `asset_config(asset)`
- **User Data**:
    - `balances(user_id)`
    - `order(order_id)`
    - `active_orders(...)`
- **Internal Helpers**:
    - `fetch_book_side`
    - `fetch_sorted_book_side`
    - `collect_keys` (used for inspection)

### 3. Maintain Write Operations on `@redis` (Master)
Ensure the following remain on the primary connection:
- Order Execution (`place_limit_order`, `execute_order`)
- Cancellation (`cancel_order`, `cancel_all_orders`)
- Balance/Asset Management (`deposit`, `withdraw`, `seed_market`, etc.)
- Lua Script execution

## Technical Implementation Details
- **File**: `lib/redis_exchange.rb`
- **Consistency**: Users will be advised that read operations on the replica are **eventually consistent**. Data written to the master (like a new order) may not be immediately visible in `active_orders` or `ticker` if the replica is lagging.

## Verification
- Create a test script that simulates a read-replica setup (can point to the same Redis instance for functional verification if a real replica isn't available in the dev environment, or use a separate connection object to verify the method calls).
