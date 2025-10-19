# Redis Exchange Architecture

This document describes the Redis-centric exchange architecture used in this repository. It outlines the core data model, the matching flow, and the invariants the Lua script enforces.

## Key Concepts

- **Atomic operations** – Order placement and matching run inside a single Lua script to guarantee atomicity with respect to Redis state.
- **Deterministic queues** – Each price level keeps FIFO ordering through Redis lists; price discovery uses sorted sets keyed by price level.
- **Strict accounting** – User balances are split into `available` and `reserved` buckets per asset. The matching script is the only component allowed to mutate reserved balances to avoid race conditions.

## Data Model

### Markets

Markets are stored as hashes:

```
market:{symbol}
    base_asset        -> e.g. BTC
    quote_asset       -> e.g. USDT
    price_scale       -> integer scale (1 = whole units, 100 = cents)
    quantity_scale    -> integer scale for base asset quantities
    maker_fee_bps     -> maker fee in basis points
    taker_fee_bps     -> taker fee in basis points
    min_qty           -> minimum order quantity (scaled integer)
    min_notional      -> minimum notional (quote units)
    status            -> OPEN | HALTED | CLOSED
```

### Assets (New)

```
asset:{asset}
    balance_scale    -> integer scale used for balances and ledger (e.g., 1, 100, 1_000_000)
    status           -> ACTIVE | HALTED
    # optional display hints (not used by Lua): name, display_decimals
```

- Purpose: decouple account/ledger precision from per-market matching precision.
- All deposits/withdrawals/ledger entries must use `balance_scale` minor units for the asset.
- Markets reference assets via `base_asset` and `quote_asset`; the matching script converts market-scale deltas into asset `balance_scale` when mutating balances and writing ledger.

### Balances

Balances live in a hash per user:

```
balance:{user_id}
    {asset}:available -> funds that can be spent immediately
    {asset}:reserved  -> funds locked on active orders
```

All balances are stored as integers in the asset's minor units (`asset.balance_scale`). Matching uses market scales (`price_scale`, `quantity_scale`) and converts to asset units before applying.

### Order Books

Two sorted sets maintain price discovery:

```
book:{symbol}:buy
book:{symbol}:sell
```

Members are price levels (encoded as strings), scores are the integer price. Buys are stored with negative scores so that `ZRANGE` retrieves the highest bid first.

Each price level has a FIFO queue of order ids:

```
queue:{symbol}:{side}:{price}
```

An aggregated volume hash tracks open quantity at each level:

```
volume:{symbol}:{side}
    {price} -> remaining base quantity at this level
```

### Orders

Individual orders are tracked as hashes:

```
order:{order_id}
    user_id
    symbol
    side            -> BUY | SELL
    type            -> LIMIT | MARKET
    price           -> limit price cap (scaled; 0 for uncapped market)
    quantity        -> original quantity (scaled)
    remaining       -> open quantity (scaled)
    status          -> OPEN | PARTIALLY_FILLED | FILLED | NO_LIQUIDITY
    created_at      -> unix timestamp in ms
```

### Sequencing

Each market has a monotonically increasing sequence to break ties at the same price:

```
seq:{symbol} -> integer
```

The sequence is appended to the order hash (`sequence`) and is used purely for auditing; FIFO ordering is handled by the Redis lists.

### Trades

Matches are appended to a capped stream/list for downstream consumers:

```
trades:{symbol}
```

Each trade entry is broadcast to `trades:{symbol}` via `XADD` with fields:

```
symbol        -> market symbol (e.g., BTCUSDT)
taker_order_id
maker_order_id
buy_order_id  -> normalized convenience id (buyer side)
sell_order_id -> normalized convenience id (seller side)
taker_side    -> 'BUY' | 'SELL'
price         -> executed price (scaled integer)
quantity      -> executed base quantity (scaled integer)
quote         -> executed quote amount (scaled integer)
taker_fee     -> fee charged to taker (scaled integer)
maker_fee     -> fee charged to maker (scaled integer)
ts            -> unix timestamp in milliseconds
```

### Ticker

Per-market ticker information is stored in a hash:

```
ticker:{symbol}
    last_price       -> price of the most recent trade (scaled integer)
    last_quantity    -> quantity of the most recent trade
    last_quote       -> quote amount of the most recent trade
    last_timestamp   -> unix timestamp in ms
    best_bid_price   -> highest bid price (0 if no bids)
    best_bid_volume  -> quantity resting at best bid
    best_ask_price   -> lowest ask price (0 if no asks)
    best_ask_volume  -> quantity resting at best ask
```


## Matching Flow

1. **Validation**
   - Market must be `OPEN`.
   - The Ruby client performs a pre-check and rejects new order placement when market status is `HALTED` or `CLOSED` (returns `MARKET_HALTED` or `MARKET_CLOSED`).
   - Order quantity must satisfy the market minimum; limit orders must also meet the minimum notional.
   - The taker must have sufficient `available` balance to cover the order (quote asset for buys, base asset for sells).

2. **Execution**
   - Iterate through the book on the opposite side, starting at the best price level.
   - Stop when either the book is empty or the next maker price falls outside the taker limit (for market orders a price cap of zero means "no limit").
   - Pop maker orders FIFO from the price level queue, loading their order hash for remaining quantity and owner id.
   - Compute the trade size (minimum of taker remaining and maker remaining) and notional.
   - Apply fees: taker fee debited from the taker’s filled amount, maker fee debited from the maker’s proceeds.
   - Update balances atomically:
     - Buyer receives base asset in `available`, quote asset is decreased (reserved for taker, available for maker).
     - Seller receives quote asset in `available`, base asset reserved is released.
   - Reduce each order’s remaining quantity; if a maker order hits zero it is removed from the queue, price level aggregates, and its status is transitioned to `FILLED`.
   - Append the trade payload to `trades:{symbol}`.

3. **Resting Orders**
   - For limit orders, if the taker still has open quantity after exhausting marketable liquidity, convert the remaining stake into a resting maker order:
     - Move funds from taker `available` to `reserved` bucket.
     - Persist the order hash with status `OPEN` and push to the appropriate price level queue.
     - Update the price level volume and (if new) add the price to the sorted set.

4. **Results**
   - The script returns a JSON-encoded payload summarising:
     - Order status, remaining quantity (market orders report leftover as unfilled and close immediately), and any reserved amount
     - Trades executed during the call
     - Balance deltas applied to the taker
   - The ticker hash is refreshed with the most recent trade (if any) and current best bid/ask levels

## Numeric Precision & Scale Compatibility

- Lua runs on IEEE-754 double; keep every integer value strictly within ~9e15 to avoid precision loss.
- Market scales:
  - `price_scale` (quote minor units)
  - `quantity_scale` (base minor units)
- Asset scales:
  - `asset.balance_scale` per asset, used for balances and ledger.

### Conversion Rules

- Base conversions (quantities):
  - From market to balance units: `base_balance = base_market * (base_balance_scale / quantity_scale)`
- Quote conversions (notional and fees):
  - From market to balance units: `quote_balance = quote_market * (quote_balance_scale / price_scale)`

To guarantee integer conversions and avoid rounding, enforce:
- `base_balance_scale` must be a multiple of `quantity_scale` for any market that trades the base asset.
- `quote_balance_scale` must be a multiple of `price_scale` for any market that trades the quote asset.

If this compatibility is violated, the engine should reject seeding or order placement with `ASSET_SCALE_MISMATCH`.

### Overflow Protection (unchanged but extended)

- The script aborts with `PRECISION_OVERFLOW` when any of the following would exceed ~9e15:
  - `price * quantity` (market notional in market scales)
  - Any conversion multiplier application (e.g., `quote_market * (quote_balance_scale / price_scale)`)
- Prefer "divide first, then multiply" or precomputed integer factors to minimize intermediate products.

## Fees Deduction Policy

- Fees (both taker and maker) are deducted only after a trade is executed.
- Resting limit BUY orders reserve only the nominal quote amount: `floor(price_limit * remaining / quantity_scale)`; fees are not reserved.
- Resting limit SELL orders reserve only the base quantity.
- Market BUY orders may temporarily debit an estimated maximum quote (including fees) to ensure atomic matching, but any unused portion is refunded immediately within the same call.
- Order cancellations release only the nominal reserved amounts (no fees), returning them from `reserved` back to `available`.

## Invariants

- No double-spend: balances never go negative because all debits happen before credits and checks guard insufficiency.
- FIFO: queues guarantee chronological execution for same-price orders.
- Atomicity: Lua script wraps the entire life cycle of an order placement.

