--[[
match_order.lua implements the exchange's atomic limit/market order matching routine.

Expected KEYS (1-9):
 1. market metadata hash (market:{symbol})
 2. sequence counter (seq:{symbol})
 3. buy book sorted set (book:{symbol}:BUY)
 4. sell book sorted set (book:{symbol}:SELL)
 5. buy side volume hash (volume:{symbol}:BUY)
 6. sell side volume hash (volume:{symbol}:SELL)
 7. taker balance hash (balance:{user_id})
 8. trade stream (trades:{symbol})
  9. order event stream (orders:{symbol})

Expected ARGV (1-8):
 1. symbol
 2. side (BUY|SELL)
 3. order type (LIMIT|MARKET)
 4. order id
 5. user id
 6. price limit (scaled integer, 0 when unrestricted)
 7. quantity (scaled integer)
 8. timestamp in milliseconds

Returns a JSON blob describing execution outcome or an error code.
The ticker hash (`ticker:{symbol}`) is also refreshed with last trade and top-of-book data.
]]

-- Redis Lua environment provides global `cjson`; no `require` is allowed.
local cjson = cjson

-- Convert a flat array (HGETALL result) into a key/value table.
local function to_map(array)
  local map = {}
  for i = 1, #array, 2 do
    map[array[i]] = array[i + 1]
  end
  return map
end

-- Coerce Redis string replies into numbers with 0 fallback.
local function as_number(value)
  if not value then
    return 0
  end
  return tonumber(value) or 0
end

-- Perform HINCRBY only when the delta is non-zero to avoid redundant writes.
local function hincrby(key, field, delta)
  if delta ~= 0 then
    redis.call('HINCRBY', key, field, delta)
  end
end

-- Append an account ledger entry for a balance change.
-- Uses per-user-asset sequence `ledger_seq:{user_id}:{asset}` and global stream `account_ledger`.
local function append_ledger(user_id, asset, bucket, delta, reason, ts)
  if delta == 0 then return end
  local now_ts = ts
  if not now_ts or now_ts <= 0 then
    local now = redis.call('TIME')
    now_ts = (tonumber(now[1]) or 0) * 1000 + math.floor((tonumber(now[2]) or 0) / 1000)
  end
  local seq = redis.call('INCR', 'ledger_seq:' .. user_id .. ':' .. asset)
  local ledger_biz_id = 'AUTO:' .. user_id .. ':' .. asset .. ':' .. bucket .. ':' .. tostring(seq)
  redis.call('XADD', 'account_ledger', 'MAXLEN', '~', 1000000, '*',
    'user_id', user_id,
    'asset', asset,
    'bucket', bucket,
    'delta', tostring(delta),
    'reason', reason or 'MATCH',
    'ts', tostring(now_ts),
    'sequence', tostring(seq),
    'biz_id', ledger_biz_id
  )
end

-- Store a trade entry so that the response can echo executions.
local function append_trade(trades, payload)
  trades[#trades + 1] = payload
end

-- Remove empty price levels from the sorted set, volume hash, and queue.
local function pop_empty_price_level(book_key, volume_key, queue_key, price_member)
  local queue_len = redis.call('LLEN', queue_key)
  local level_volume = redis.call('HGET', volume_key, price_member)

  if queue_len == 0 or not level_volume or tonumber(level_volume) <= 0 then
    redis.call('ZREM', book_key, price_member)
    redis.call('HDEL', volume_key, price_member)
    redis.call('DEL', queue_key)
  end
end

-- Redis KEYS provided by the caller. Order matters for latency and routing.
local market_key = KEYS[1]
local seq_key = KEYS[2]
local book_buy_key = KEYS[3]
local book_sell_key = KEYS[4]
local volume_buy_key = KEYS[5]
local volume_sell_key = KEYS[6]
local taker_balance_key = KEYS[7]
local trades_key = KEYS[8]
local orders_key = KEYS[9]

-- ARGV parameters describing the taker order being processed.
local symbol = ARGV[1]
local side = ARGV[2]
local order_type = string.upper(ARGV[3] or 'LIMIT')
local order_id = ARGV[4]
local user_id = ARGV[5]
local price_limit = tonumber(ARGV[6]) or 0
local quantity = tonumber(ARGV[7])
local timestamp = tonumber(ARGV[8])
local has_price_limit = price_limit > 0
local is_market = order_type == 'MARKET'
local is_buy = side == 'BUY'

if not (symbol and side and order_type and order_id and user_id and quantity and timestamp) then
  return cjson.encode({ error = 'INVALID_ARGUMENTS' })
end

if order_type ~= 'LIMIT' and order_type ~= 'MARKET' then
  return cjson.encode({ error = 'INVALID_ORDER_TYPE' })
end

if side ~= 'BUY' and side ~= 'SELL' then
  return cjson.encode({ error = 'INVALID_SIDE' })
end

if quantity <= 0 then
  return cjson.encode({ error = 'INVALID_PRICE_OR_QUANTITY' })
end

if not has_price_limit and order_type == 'LIMIT' then
  return cjson.encode({ error = 'INVALID_PRICE_OR_QUANTITY' })
end

local order_key = 'order:' .. order_id

local existing_status = redis.call('HGET', order_key, 'status')
local existing_remaining = redis.call('HGET', order_key, 'remaining')
if existing_status == 'OPEN' or existing_status == 'PARTIALLY_FILLED' then
  return cjson.encode({ error = 'DUPLICATE_ORDER_ID' })
end
if existing_remaining and tonumber(existing_remaining) > 0 then
  return cjson.encode({ error = 'DUPLICATE_ORDER_ID' })
end

local market = to_map(redis.call('HGETALL', market_key))
if next(market) == nil then
  return cjson.encode({ error = 'UNKNOWN_MARKET' })
end

if market['status'] ~= 'OPEN' then
  return cjson.encode({ error = 'MARKET_HALTED' })
end

-- Optional stream length cap from market config; default to 1,000,000 entries
local trades_maxlen = tonumber(market['trades_maxlen']) or 1000000
local orders_maxlen = tonumber(market['orders_maxlen']) or 1000000

local base_asset = market['base_asset']
local quote_asset = market['quote_asset']
local quantity_scale = tonumber(market['quantity_scale'] or '1')
local min_qty = tonumber(market['min_qty'] or '0')
local min_notional = tonumber(market['min_notional'] or '0')
local maker_fee_bps = tonumber(market['maker_fee_bps'] or '0')
local taker_fee_bps = tonumber(market['taker_fee_bps'] or '0')

-- Precision guard: Lua uses 64-bit double; keep intermediates below ~9e15
local PRECISION_BOUND = 9000000000000000 -- ~9e15
local function would_overflow_mul(a, b)
  -- both a,b are integers represented in double; compare against bound
  -- allow product equal to bound, overflow only when strictly greater
  return (a > 0 and b > 0) and (a >= PRECISION_BOUND or b >= PRECISION_BOUND or (a * b) > PRECISION_BOUND)
end

if quantity < min_qty then
  return cjson.encode({ error = 'MIN_QTY_NOT_SATISFIED' })
end

if order_type == 'LIMIT' then
  if has_price_limit and would_overflow_mul(price_limit, quantity) then
    return cjson.encode({ error = 'PRECISION_OVERFLOW' })
  end
  local notional = math.floor((price_limit * quantity) / quantity_scale)
  if notional < min_notional then
    return cjson.encode({ error = 'MIN_NOTIONAL_NOT_SATISFIED' })
  end
end

local base_available_field = base_asset .. ':available'
local base_reserved_field = base_asset .. ':reserved'
local quote_available_field = quote_asset .. ':available'
local quote_reserved_field = quote_asset .. ':reserved'

local taker_available_base = as_number(redis.call('HGET', taker_balance_key, base_available_field))
local taker_reserved_base = as_number(redis.call('HGET', taker_balance_key, base_reserved_field))
local taker_available_quote = as_number(redis.call('HGET', taker_balance_key, quote_available_field))
local taker_reserved_quote = as_number(redis.call('HGET', taker_balance_key, quote_reserved_field))

local taker_available_base_after = taker_available_base
local taker_available_quote_after = taker_available_quote

if has_price_limit and would_overflow_mul(price_limit, quantity) then
  return cjson.encode({ error = 'PRECISION_OVERFLOW' })
end
local max_quote_needed = math.floor((price_limit * quantity) / quantity_scale)
local taker_fee_estimate = math.floor((max_quote_needed * taker_fee_bps) / 10000)
local maker_fee_estimate = math.floor((max_quote_needed * maker_fee_bps) / 10000)

if is_buy then
  if is_market and not has_price_limit then
    if taker_available_quote <= 0 then
      return cjson.encode({ error = 'INSUFFICIENT_FUNDS', asset = quote_asset })
    end
  else
    local required_quote = max_quote_needed + taker_fee_estimate + maker_fee_estimate
    if taker_available_quote < required_quote then
      return cjson.encode({ error = 'INSUFFICIENT_FUNDS', asset = quote_asset })
    end
  end
else
  if taker_available_base < quantity then
    return cjson.encode({ error = 'INSUFFICIENT_FUNDS', asset = base_asset })
  end
end

local trades = {}
local remaining = quantity
local executed_quantity = 0
local taker_quote_spent = 0
local taker_quote_received = 0
local taker_base_received = 0
local taker_base_sold = 0
local maker_fees_collected = 0
local taker_fees_collected = 0

-- Accumulate collected fees in fees:{asset} for downstream accounting.
local function add_fee(asset, amount)
  if amount <= 0 then
    return
  end
  redis.call('HINCRBY', 'fees:' .. asset, 'total', amount)
end

-- Load an order hash into a Lua table for easier access.
local function load_order_map(order_key)
  return to_map(redis.call('HGETALL', order_key))
end

-- Retrieve the top-of-book price entry for the given side.
local function best_price_key_for_side(book_key, is_buy_side)
  if is_buy_side then
    return redis.call('ZRANGE', book_key, -1, -1, 'WITHSCORES')
  else
    return redis.call('ZRANGE', book_key, 0, 0, 'WITHSCORES')
  end
end

local opposite_book_key = is_buy and book_sell_key or book_buy_key
local own_book_key = is_buy and book_buy_key or book_sell_key
local opposite_volume_key = is_buy and volume_sell_key or volume_buy_key
local own_volume_key = is_buy and volume_buy_key or volume_sell_key
-- Pre-check: for market orders, ensure sufficient opposing liquidity exists to fully satisfy requested quantity.
-- This avoids partial executions when the user expects all-or-nothing for market orders.
local insufficient_liquidity_precheck = false
if is_market then
  local total_liquidity = 0
  local levels = redis.call('ZRANGE', opposite_book_key, 0, -1, 'WITHSCORES')
  for i = 1, #levels, 2 do
    local price_member = levels[i]
    local level_price = tonumber(levels[i + 1])
    if has_price_limit then
      if is_buy and level_price > price_limit then
        break
      end
      if (not is_buy) and level_price < price_limit then
        break
      end
    end
    local level_volume = as_number(redis.call('HGET', opposite_volume_key, price_member))
    total_liquidity = total_liquidity + level_volume
    if total_liquidity >= quantity then
      break
    end
  end
  if total_liquidity < quantity then
    insufficient_liquidity_precheck = true
  end
end
local function update_ticker_state(trade_list)
  local ticker_key = 'ticker:' .. symbol

  if #trade_list > 0 then
    local last_trade = trade_list[#trade_list]
    redis.call('HSET', ticker_key,
      'last_price', tostring(last_trade.price),
      'last_quantity', tostring(last_trade.quantity),
      'last_quote', tostring(last_trade.quote),
      'last_timestamp', tostring(last_trade.timestamp)
    )
  end

  local best_bid = redis.call('ZRANGE', book_buy_key, -1, -1)
  if #best_bid > 0 then
    local bid_price = best_bid[1]
    local bid_volume = redis.call('HGET', volume_buy_key, bid_price) or '0'
    redis.call('HSET', ticker_key,
      'best_bid_price', bid_price,
      'best_bid_volume', tostring(bid_volume)
    )
  else
    redis.call('HSET', ticker_key,
      'best_bid_price', '0',
      'best_bid_volume', '0'
    )
  end

  local best_ask = redis.call('ZRANGE', book_sell_key, 0, 0)
  if #best_ask > 0 then
    local ask_price = best_ask[1]
    local ask_volume = redis.call('HGET', volume_sell_key, ask_price) or '0'
    redis.call('HSET', ticker_key,
      'best_ask_price', ask_price,
      'best_ask_volume', tostring(ask_volume)
    )
  else
    redis.call('HSET', ticker_key,
      'best_ask_price', '0',
      'best_ask_volume', '0'
    )
  end
end

local opposite_side = is_buy and 'SELL' or 'BUY'

while (not insufficient_liquidity_precheck) and remaining > 0 do
  local level = best_price_key_for_side(opposite_book_key, is_buy)
  if #level == 0 then
    break
  end

  local price_member = level[1]
  local level_price = tonumber(level[2])

  if has_price_limit then
    if is_buy and level_price > price_limit then
      break
    end
    if not is_buy and level_price < price_limit then
      break
    end
  elseif not is_market then
    -- Should not happen, defensive guard for future order types.
    break
  end

  local queue_key = 'queue:' .. symbol .. ':' .. opposite_side .. ':' .. price_member
  local maker_order_id = redis.call('LINDEX', queue_key, 0)

  repeat
    if not maker_order_id then
      pop_empty_price_level(opposite_book_key, opposite_volume_key, queue_key, price_member)
      break
    end

    local maker_order_key = 'order:' .. maker_order_id
    local maker_order = load_order_map(maker_order_key)
    if next(maker_order) == nil then
      redis.call('LPOP', queue_key)
      pop_empty_price_level(opposite_book_key, opposite_volume_key, queue_key, price_member)
      break
    end

    local maker_remaining = tonumber(maker_order['remaining'] or '0')
    if maker_remaining <= 0 then
      redis.call('LPOP', queue_key)
      pop_empty_price_level(opposite_book_key, opposite_volume_key, queue_key, price_member)
      break
    end

    local trade_qty = remaining
    if maker_remaining < trade_qty then
      trade_qty = maker_remaining
    end

    local trade_price = tonumber(maker_order['price'] or level_price)
    if would_overflow_mul(trade_price, trade_qty) then
      return cjson.encode({ error = 'PRECISION_OVERFLOW' })
    end
    local trade_quote = math.floor((trade_price * trade_qty) / quantity_scale)
    local maker_side = maker_order['side']
    local maker_user_id = maker_order['user_id']

    local taker_fee = math.floor((trade_quote * taker_fee_bps) / 10000)
    local maker_fee = math.floor((trade_quote * maker_fee_bps) / 10000)

    if is_buy then
      local debit = trade_quote + taker_fee
      if taker_available_quote_after < debit then
        return cjson.encode({ error = 'INSUFFICIENT_FUNDS_DURING_MATCH', asset = quote_asset })
      end
      taker_available_quote_after = taker_available_quote_after - debit
      hincrby(taker_balance_key, quote_available_field, -debit)
      append_ledger(user_id, quote_asset, 'available', -debit, 'TAKER_SPEND', timestamp)
      hincrby(taker_balance_key, base_available_field, trade_qty)
      append_ledger(user_id, base_asset, 'available', trade_qty, 'TAKER_RECEIVE', timestamp)
      taker_quote_spent = taker_quote_spent + debit
      taker_base_received = taker_base_received + trade_qty
    else
      if taker_available_base_after < trade_qty then
        return cjson.encode({ error = 'INSUFFICIENT_FUNDS_DURING_MATCH', asset = base_asset })
      end
      taker_available_base_after = taker_available_base_after - trade_qty
      hincrby(taker_balance_key, base_available_field, -trade_qty)
      append_ledger(user_id, base_asset, 'available', -trade_qty, 'TAKER_SELL', timestamp)
      local credit = trade_quote - taker_fee
      hincrby(taker_balance_key, quote_available_field, credit)
      append_ledger(user_id, quote_asset, 'available', credit, 'TAKER_RECEIVE', timestamp)
      taker_quote_received = taker_quote_received + credit
      taker_base_sold = taker_base_sold + trade_qty
    end

    taker_fees_collected = taker_fees_collected + taker_fee
    maker_fees_collected = maker_fees_collected + maker_fee
    add_fee(quote_asset, taker_fee + maker_fee)

    -- Update maker balances.
    local maker_balance_key = 'balance:' .. maker_user_id
    if maker_side == 'SELL' then
      hincrby(maker_balance_key, base_reserved_field, -trade_qty)
      append_ledger(maker_user_id, base_asset, 'reserved', -trade_qty, 'MAKER_RELEASE', timestamp)
      local credit = trade_quote - maker_fee
      hincrby(maker_balance_key, quote_available_field, credit)
      append_ledger(maker_user_id, quote_asset, 'available', credit, 'MAKER_RECEIVE', timestamp)
    else
      local debit = trade_quote + maker_fee
      hincrby(maker_balance_key, quote_reserved_field, -debit)
      append_ledger(maker_user_id, quote_asset, 'reserved', -debit, 'MAKER_RELEASE', timestamp)
      hincrby(maker_balance_key, base_available_field, trade_qty)
      append_ledger(maker_user_id, base_asset, 'available', trade_qty, 'MAKER_RECEIVE', timestamp)
    end

    maker_remaining = maker_remaining - trade_qty
    remaining = remaining - trade_qty
    executed_quantity = executed_quantity + trade_qty

    redis.call('HSET', maker_order_key, 'remaining', maker_remaining)

    -- Update volume first before any cleanup
    redis.call('HINCRBY', opposite_volume_key, price_member, -trade_qty)
    
    if maker_remaining == 0 then
      redis.call('HSET', maker_order_key, 'status', 'FILLED')
      redis.call('LPOP', queue_key)
      pop_empty_price_level(opposite_book_key, opposite_volume_key, queue_key, price_member)
      -- Remove filled maker order from user's active index
      local maker_index_key = 'user_orders:' .. maker_user_id .. ':' .. symbol
      redis.call('ZREM', maker_index_key, maker_order_id)
      -- Publish maker FILLED event and delete terminal order hash
      redis.call('XADD', orders_key, 'MAXLEN', '~', orders_maxlen, '*',
        'order_id', maker_order_id,
        'user_id', maker_user_id,
        'symbol', symbol,
        'side', (is_buy and 'SELL' or 'BUY'),
        'type', 'LIMIT',
        'status', 'FILLED',
        'price', price_member,
        'quantity', redis.call('HGET', maker_order_key, 'quantity') or '0',
        'remaining', '0',
        'ts', tostring(timestamp),
        'sequence', tostring(redis.call('HGET', maker_order_key, 'sequence') or '')
      )
      redis.call('DEL', maker_order_key)
    else
      redis.call('HSET', maker_order_key, 'status', 'PARTIALLY_FILLED')
      -- Publish maker PARTIALLY_FILLED event
      redis.call('XADD', orders_key, 'MAXLEN', '~', orders_maxlen, '*',
        'order_id', maker_order_id,
        'user_id', maker_user_id,
        'symbol', symbol,
        'side', (is_buy and 'SELL' or 'BUY'),
        'type', 'LIMIT',
        'status', 'PARTIALLY_FILLED',
        'price', price_member,
        'quantity', redis.call('HGET', maker_order_key, 'quantity') or '0',
        'remaining', tostring(maker_remaining),
        'ts', tostring(timestamp),
        'sequence', tostring(redis.call('HGET', maker_order_key, 'sequence') or '')
      )
    end

    local trade_payload = {
      taker_order_id = order_id,
      maker_order_id = maker_order_id,
      -- normalized identifiers for convenience
      buy_order_id = is_buy and order_id or maker_order_id,
      sell_order_id = is_buy and maker_order_id or order_id,
      taker_side = is_buy and 'BUY' or 'SELL',
      price = trade_price,
      quantity = trade_qty,
      quote = trade_quote,
      taker_fee = taker_fee,
      maker_fee = maker_fee,
      timestamp = timestamp
    }
    append_trade(trades, trade_payload)
    -- Stream entry with near-length trimming to avoid unbounded growth
    -- Use MAXLEN ~ for amortized trimming; length threshold sourced from market config.
    redis.call('XADD', trades_key, 'MAXLEN', '~', trades_maxlen, '*',
      'taker_order_id', order_id,
      'maker_order_id', maker_order_id,
      'buy_order_id', is_buy and order_id or maker_order_id,
      'sell_order_id', is_buy and maker_order_id or order_id,
      'taker_side', is_buy and 'BUY' or 'SELL',
      'price', tostring(trade_price),
      'quantity', tostring(trade_qty),
      'quote', tostring(trade_quote),
      'taker_fee', tostring(taker_fee),
      'maker_fee', tostring(maker_fee),
      'symbol', symbol,
      'ts', tostring(timestamp)
    )
  until true
end

local remaining_before_post = remaining
local order_status

local seq = redis.call('INCR', seq_key)
if is_market then
  if executed_quantity == 0 then
    order_status = 'NO_LIQUIDITY'
  elseif remaining_before_post > 0 then
    order_status = 'PARTIALLY_FILLED'
  else
    order_status = 'FILLED'
  end
  remaining = 0
else
  if remaining == 0 then
    order_status = 'FILLED'
  else
    order_status = executed_quantity > 0 and 'PARTIALLY_FILLED' or 'OPEN'
    if remaining > 0 then
      if is_buy then
        local reserve_quote = math.floor((price_limit * remaining) / quantity_scale)
        if reserve_quote > 0 then
          if taker_available_quote_after < reserve_quote then
            return cjson.encode({ error = 'INSUFFICIENT_FUNDS_TO_REST', asset = quote_asset })
          end
          taker_available_quote_after = taker_available_quote_after - reserve_quote
          taker_reserved_quote = taker_reserved_quote + reserve_quote
          hincrby(taker_balance_key, quote_available_field, -reserve_quote)
          append_ledger(user_id, quote_asset, 'available', -reserve_quote, 'TAKER_RESERVE', timestamp)
          hincrby(taker_balance_key, quote_reserved_field, reserve_quote)
          append_ledger(user_id, quote_asset, 'reserved', reserve_quote, 'TAKER_RESERVE', timestamp)
        end
      else
        local reserve_qty = remaining
        if reserve_qty > 0 then
          if taker_available_base_after < reserve_qty then
            return cjson.encode({ error = 'INSUFFICIENT_FUNDS_TO_REST', asset = base_asset })
          end
          taker_available_base_after = taker_available_base_after - reserve_qty
          taker_reserved_base = taker_reserved_base + reserve_qty
          hincrby(taker_balance_key, base_available_field, -reserve_qty)
          append_ledger(user_id, base_asset, 'available', -reserve_qty, 'TAKER_RESERVE', timestamp)
          hincrby(taker_balance_key, base_reserved_field, reserve_qty)
          append_ledger(user_id, base_asset, 'reserved', reserve_qty, 'TAKER_RESERVE', timestamp)
        end
      end

      local price_member = tostring(price_limit)
      local queue_key = 'queue:' .. symbol .. ':' .. side .. ':' .. price_member
      redis.call('RPUSH', queue_key, order_id)

      if is_buy then
        redis.call('ZADD', own_book_key, -price_limit, price_member)
      else
        redis.call('ZADD', own_book_key, price_limit, price_member)
      end

      redis.call('HINCRBY', own_volume_key, price_member, remaining)
    end
  end
end

redis.call('HMSET', order_key,
  'order_id', order_id,
  'user_id', user_id,
  'symbol', symbol,
  'side', side,
  'type', order_type,
  'price', tostring(price_limit),
  'quantity', tostring(quantity),
  'remaining', tostring(remaining),
  'status', order_status,
  'created_at', tostring(timestamp),
  'sequence', tostring(seq)
)

-- Maintain per-user active orders index for the taker.
-- Index only resting LIMIT orders with remaining > 0.
local taker_index_key = 'user_orders:' .. user_id .. ':' .. symbol
if order_type == 'LIMIT' and remaining > 0 and (order_status == 'OPEN' or order_status == 'PARTIALLY_FILLED') then
  redis.call('ZADD', taker_index_key, seq, order_id)
else
  redis.call('ZREM', taker_index_key, order_id)
end

update_ticker_state(trades)

-- Publish taker order event
redis.call('XADD', orders_key, 'MAXLEN', '~', orders_maxlen, '*',
  'order_id', order_id,
  'user_id', user_id,
  'symbol', symbol,
  'side', side,
  'type', order_type,
  'status', order_status,
  'price', tostring(price_limit),
  'quantity', tostring(quantity),
  'remaining', tostring(remaining),
  'ts', tostring(timestamp),
  'sequence', tostring(seq)
)

-- Delete terminal taker orders to keep memory bounded
if order_status == 'FILLED' or order_status == 'NO_LIQUIDITY' then
  redis.call('DEL', order_key)
end

local result = {
  order_id = order_id,
  order_type = order_type,
  status = order_status,
  requested_quantity = quantity,
  executed_quantity = executed_quantity,
  remaining_quantity = remaining_before_post,
  price_limit = price_limit,
  taker_quote_spent = taker_quote_spent,
  taker_quote_received = taker_quote_received,
  taker_base_received = taker_base_received,
  taker_base_sold = taker_base_sold,
  taker_fee_paid = taker_fees_collected,
  maker_fee_charged = maker_fees_collected,
  trades = trades
}

return cjson.encode(result)
