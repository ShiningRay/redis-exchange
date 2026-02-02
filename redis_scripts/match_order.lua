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

Expected ARGV (1-9):
  1. symbol
  2. side (BUY|SELL)
  3. order type (LIMIT|MARKET)
  4. order id
  5. user id
  6. price limit (scaled integer, 0 when unrestricted)
  7. quantity (scaled integer)
  8. timestamp in milliseconds
  9. user taker fee in basis points (optional, nil uses market default)

Returns a JSON blob describing execution outcome or an error code.
The ticker hash (`ticker:{symbol}`) is also refreshed with last trade and top-of-book data.
]]

-- Redis Lua environment provides global `cjson`; no `require` is allowed.
local cjson = cjson

-- Check for system maintenance mode
if redis.call('GET', 'system:maintenance_mode') == '1' then
  return cjson.encode({ error = 'SYSTEM_MAINTENANCE' })
end

-- Check for market maintenance mode (via status field)
local market_status = redis.call('HGET', KEYS[1], 'status')
if market_status == 'MAINTENANCE' then
  return cjson.encode({ error = 'MARKET_MAINTENANCE' })
end
if market_status ~= 'OPEN' then
  return cjson.encode({ error = 'MARKET_HALTED' })
end
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

-- Format number as integer string to avoid scientific notation (e.g. "1e+15")
-- which causes "ERR value is not an integer" in HINCRBY.
local function format_int(n)
  return string.format("%.0f", n)
end

-- Perform HINCRBY only when the delta is non-zero to avoid redundant writes.
local function hincrby(key, field, delta)
  if delta ~= 0 then
    return redis.call('HINCRBY', key, field, format_int(delta))
  end
  return tonumber(redis.call('HGET', key, field)) or 0
end

-- Append an account ledger entry for a balance change.
-- Uses per-user-asset sequence `ledger_seq:{user_id}:{asset}` and global stream `account_ledger`.
local function append_ledger(user_id, asset, action, amount, new_available, new_reserved, reason, ts, biz_id)
  if amount == 0 then return end
  local now_ts = ts
  if not now_ts or now_ts <= 0 then
    local now = redis.call('TIME')
    now_ts = (tonumber(now[1]) or 0) * 1000 + math.floor((tonumber(now[2]) or 0) / 1000)
  end
  local seq = redis.call('INCR', 'ledger_seq:' .. user_id .. ':' .. asset)
  local ledger_biz_id = biz_id
  if not ledger_biz_id then
    ledger_biz_id = 'AUTO:' .. user_id .. ':' .. asset .. ':' .. action .. ':' .. tostring(seq)
  end
  redis.call('XADD', 'account_ledger', 'MAXLEN', '~', 1000000, '*',
    'user_id', user_id,
    'asset', asset,
    'action', action,
    'amount', tostring(amount),
    'new_available', tostring(new_available),
    'new_reserved', tostring(new_reserved),
    'reason', reason or 'MATCH',
    'ts', tostring(now_ts),
    'sequence', tostring(seq),
    'biz_id', ledger_biz_id
  )
end

-- Get user-specific fee rates for a given user
local function get_user_fees(user_id)
  local fees = to_map(redis.call('HGETALL', 'user_fees:' .. user_id))
  if next(fees) == nil then
    return nil, nil
  end
  local m_bps = tonumber(fees['maker_fee_bps'])
  local t_bps = tonumber(fees['taker_fee_bps'])
  return m_bps, t_bps
end

-- Balance Primitives
local function op_lock(user_id, asset, amount, reason, ts, biz_id)
  if amount <= 0 then return end
  local new_avail = hincrby('balance:' .. user_id, asset .. ':available', -amount)
  local new_res = hincrby('balance:' .. user_id, asset .. ':reserved', amount)
  append_ledger(user_id, asset, 'LOCK', amount, new_avail, new_res, reason, ts, biz_id)
end

local function op_unlock(user_id, asset, amount, reason, ts, biz_id)
  if amount <= 0 then return end
  local new_res = hincrby('balance:' .. user_id, asset .. ':reserved', -amount)
  local new_avail = hincrby('balance:' .. user_id, asset .. ':available', amount)
  append_ledger(user_id, asset, 'UNLOCK', amount, new_avail, new_res, reason, ts, biz_id)
end

local function op_add(user_id, asset, amount, reason, ts, biz_id)
  if amount <= 0 then return end
  local new_avail = hincrby('balance:' .. user_id, asset .. ':available', amount)
  local new_res = tonumber(redis.call('HGET', 'balance:' .. user_id, asset .. ':reserved')) or 0
  append_ledger(user_id, asset, 'ADD', amount, new_avail, new_res, reason, ts, biz_id)
end

local function op_sub(user_id, asset, amount, reason, ts, biz_id)
  if amount <= 0 then return end
  local new_avail = hincrby('balance:' .. user_id, asset .. ':available', -amount)
  local new_res = tonumber(redis.call('HGET', 'balance:' .. user_id, asset .. ':reserved')) or 0
  append_ledger(user_id, asset, 'SUB', amount, new_avail, new_res, reason, ts, biz_id)
end

local function op_sub_locked(user_id, asset, amount, reason, ts, biz_id)
  if amount <= 0 then return end
  local new_res = hincrby('balance:' .. user_id, asset .. ':reserved', -amount)
  local new_avail = tonumber(redis.call('HGET', 'balance:' .. user_id, asset .. ':available')) or 0
  append_ledger(user_id, asset, 'SUB_LOCKED', amount, new_avail, new_res, reason, ts, biz_id)
end

local function publish_depth_update(symbol, side, price, delta, final_volume, ts, seq)
  redis.call('XADD', 'depth:' .. symbol, 'MAXLEN', '~', 100000, '*',
    'e', 'u',
    's', side,
    'p', tostring(price),
    'd', tostring(delta),
    'v', tostring(final_volume),
    'ts', tostring(ts),
    'seq', tostring(seq)
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

local tombstone_key = 'order_tombstone:' .. order_id
if redis.call('EXISTS', tombstone_key) == 1 then
  return cjson.encode({ error = 'DUPLICATE_ORDER_ID' })
end

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

local tombstone_ttl_sec = tonumber(market['order_tombstone_ttl_sec']) or 86400
local function mark_tombstone(oid, status)
  if not oid or oid == '' then return end
  redis.call('SET', 'order_tombstone:' .. oid, status or 'DONE', 'EX', tombstone_ttl_sec)
end

-- Redundant check removed as we checked status at start of script
-- but we need to ensure market dict has it if used elsewhere.
-- market['status'] is available.

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
local price_scale = tonumber(market['price_scale'] or '1')

-- Taker user-specific fee rate takes precedence over market default
local user_taker_fee_bps = tonumber(ARGV[9])
if user_taker_fee_bps and user_taker_fee_bps >= 0 and user_taker_fee_bps <= 10000 then
  taker_fee_bps = user_taker_fee_bps
end

-- Read asset balance scales and validate compatibility with market scales.
local base_asset_map = to_map(redis.call('HGETALL', 'asset:' .. base_asset))
local quote_asset_map = to_map(redis.call('HGETALL', 'asset:' .. quote_asset))
if next(base_asset_map) == nil or next(quote_asset_map) == nil then
  return cjson.encode({ error = 'ASSET_NOT_CONFIGURED' })
end
local base_balance_scale = tonumber(base_asset_map['balance_scale'] or '0')
local quote_balance_scale = tonumber(quote_asset_map['balance_scale'] or '0')
if base_balance_scale <= 0 or quote_balance_scale <= 0 then
  return cjson.encode({ error = 'ASSET_NOT_CONFIGURED' })
end
local function compute_factor(balance_scale, market_scale)
  if market_scale <= 0 then return 0 end
  local div = math.floor(balance_scale / market_scale)
  if div <= 0 then return 0 end
  if (div * market_scale) ~= balance_scale then
    return 0
  end
  return div
end
local base_factor = compute_factor(base_balance_scale, quantity_scale)
local quote_factor = compute_factor(quote_balance_scale, price_scale)
if base_factor == 0 or quote_factor == 0 then
  return cjson.encode({ error = 'ASSET_SCALE_MISMATCH' })
end

-- Precision guard: Lua uses 64-bit double; keep intermediates below ~9e15
local PRECISION_BOUND = 9000000000000000 -- ~9e15
local function would_overflow_mul(a, b)
  -- both a,b are integers represented in double; compare against bound
  -- allow product equal to bound, overflow only when strictly greater
  return (a > 0 and b > 0) and (a >= PRECISION_BOUND or b >= PRECISION_BOUND or (a * b) > PRECISION_BOUND)
end

local function overflow_error(context, a, b)
  return cjson.encode({
    error = 'PRECISION_OVERFLOW',
    details = context .. ': ' .. tostring(a) .. ' * ' .. tostring(b)
  })
end

if quantity < min_qty then
  return cjson.encode({ error = 'MIN_QTY_NOT_SATISFIED' })
end

if has_price_limit and would_overflow_mul(price_limit, quantity) then
  return overflow_error('price_limit * quantity', price_limit, quantity)
end

if order_type == 'LIMIT' then
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

local reserved_base_for_order = 0
local reserved_quote_for_order = 0

local max_quote_needed = math.floor((price_limit * quantity) / quantity_scale)
local taker_fee_estimate = math.floor((max_quote_needed * taker_fee_bps) / 10000)
local maker_fee_estimate = math.floor((max_quote_needed * maker_fee_bps) / 10000)

if is_buy then
  if is_market and not has_price_limit then
    -- For market BUY without explicit price, we only check non-zero quote balance presence.
    if taker_available_quote <= 0 then
      return cjson.encode({ error = 'INSUFFICIENT_FUNDS', asset = quote_asset })
    end
  else
    local required_fee
    if is_market then
      required_fee = taker_fee_estimate
    else
      required_fee = taker_fee_estimate
      if maker_fee_estimate > required_fee then
        required_fee = maker_fee_estimate
      end
    end
    local required_quote_market = max_quote_needed + required_fee
    if would_overflow_mul(required_quote_market, quote_factor) then
      return overflow_error('required_quote * quote_factor', required_quote_market, quote_factor)
    end
    local required_quote_balance = required_quote_market * quote_factor
    if taker_available_quote < required_quote_balance then
      return cjson.encode({ error = 'INSUFFICIENT_FUNDS', asset = quote_asset })
    end
  end
else
  if would_overflow_mul(quantity, base_factor) then
    return overflow_error('quantity * base_factor', quantity, base_factor)
  end
  local required_base_balance = quantity * base_factor
  if taker_available_base < required_base_balance then
    return cjson.encode({ error = 'INSUFFICIENT_FUNDS', asset = base_asset })
  end
end

local trades = {}
local remaining = quantity
local executed_quantity = 0
local executed_quote = 0
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
  redis.call('HINCRBY', 'fees:' .. asset, 'total', format_int(amount))
end

-- Load an order hash into a Lua table for easier access.
local function load_order_map(order_key)
  return to_map(redis.call('HGETALL', order_key))
end

-- Retrieve the top-of-book price entry for the given side.
local function best_price_key_for_side(book_key, is_buy_side)
  -- We store SELL book with positive scores (price), BUY book with negative scores (-price).
  -- Therefore, the best price level for both sides resides at ZRANGE index 0:
  --  - SELL book: lowest ask (smallest positive score)
  --  - BUY book: highest bid (most negative score)
  return redis.call('ZRANGE', book_key, 0, 0, 'WITHSCORES')
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
    if not is_buy then
      level_price = -level_price
    end
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
local stop_matching = false

while (not insufficient_liquidity_precheck) and remaining > 0 do
  if stop_matching then
    break
  end
  local market_seq = redis.call('INCR', seq_key)
  local level = best_price_key_for_side(opposite_book_key, is_buy)
  if #level == 0 then
    break
  end

  local price_member = level[1]
  local level_price = tonumber(level[2])
  if opposite_side == 'BUY' then
    level_price = -level_price
  end

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
      return overflow_error('trade_price * trade_qty', trade_price, trade_qty)
    end
    local trade_quote = math.floor((trade_price * trade_qty) / quantity_scale)
    local maker_side = maker_order['side']
    local maker_user_id = maker_order['user_id']
    local maker_balance_key = 'balance:' .. maker_user_id

    -- Standard trade_seq for trades
    local trade_seq = redis.call('INCR', seq_key)

    -- Taker fee uses taker's configured rate
    local taker_fee = math.floor((trade_quote * taker_fee_bps) / 10000)

    -- Maker fee uses maker's configured rate (fetch from user_fees if set)
    local maker_user_maker_fee_bps, _ = get_user_fees(maker_user_id)
    local actual_maker_fee_bps = maker_user_maker_fee_bps or maker_fee_bps
    local maker_fee = math.floor((trade_quote * actual_maker_fee_bps) / 10000)

    if is_buy then
      local debit_market = trade_quote + taker_fee
      if would_overflow_mul(debit_market, quote_factor) then
        -- Overflow detected before any writes for this match
        return overflow_error('debit_market * quote_factor', debit_market, quote_factor)
      end
      local debit_balance = debit_market * quote_factor
      if taker_available_quote_after < debit_balance then
        -- Insufficient funds detected before any writes for this match
        -- Stop matching, treat as partial fill or no liquidity if it's the first match
        stop_matching = true
        break
      end

      if would_overflow_mul(trade_qty, base_factor) then
        return overflow_error('trade_qty * base_factor', trade_qty, base_factor)
      end
      local trade_qty_balance = trade_qty * base_factor

      -- All checks passed for taker side, now verify maker side logic to ensure we don't partial write
      -- Maker checks:
      local maker_balance_key = 'balance:' .. maker_user_id
      if maker_side == 'SELL' then
        if would_overflow_mul(trade_qty, base_factor) then
          return overflow_error('trade_qty * base_factor', trade_qty, base_factor)
        end
        local trade_qty_balance_maker = trade_qty * base_factor
        local credit_market_maker = trade_quote - maker_fee
        if would_overflow_mul(credit_market_maker, quote_factor) then
          return overflow_error('credit_market_maker * quote_factor', credit_market_maker, quote_factor)
        end
        local credit_balance_maker = credit_market_maker * quote_factor

        -- Fee Checks and Accumulation
        taker_fees_collected = taker_fees_collected + taker_fee
        maker_fees_collected = maker_fees_collected + maker_fee
        local fee_total_market = taker_fee + maker_fee
        if would_overflow_mul(fee_total_market, quote_factor) then
          return overflow_error('fee_total_market * quote_factor', fee_total_market, quote_factor)
        end
        add_fee(quote_asset, fee_total_market * quote_factor)

        -- Now perform WRITES for Taker (BUY)
        taker_available_quote_after = taker_available_quote_after - debit_balance
        op_sub(user_id, quote_asset, debit_balance, 'TAKER_SPEND', timestamp,
          'TAKER_SPEND:' .. market_seq .. '_' .. trade_seq .. ':' .. order_id)

        op_add(user_id, base_asset, trade_qty_balance, 'TAKER_RECEIVE', timestamp,
          'TAKER_RECEIVE:' .. market_seq .. '_' .. trade_seq .. ':' .. order_id)

        taker_quote_spent = taker_quote_spent + debit_market
        taker_base_received = taker_base_received + trade_qty

        -- WRITES for Maker (SELL)
        op_sub_locked(maker_user_id, base_asset, trade_qty_balance_maker, 'MAKER_RELEASE', timestamp,
          'MAKER_RELEASE:' .. market_seq .. '_' .. trade_seq .. ':' .. maker_order_id)
        if redis.call('HEXISTS', maker_order_key, 'reserved_base') == 1 then
          redis.call('HINCRBY', maker_order_key, 'reserved_base', format_int(-trade_qty_balance_maker))
        end

        op_add(maker_user_id, quote_asset, credit_balance_maker, 'MAKER_RECEIVE', timestamp,
          'MAKER_RECEIVE:' .. market_seq .. '_' .. trade_seq .. ':' .. maker_order_id)
      else
        -- Maker is BUY, Taker is BUY? Impossible as opposite_side is logic.
        -- Wait, opposite_side logic:
        -- if is_buy (Taker BUY), opposite_side is SELL. maker_side should be SELL.
        -- The original code had an else block for maker_side check?
        -- Original code: if maker_side == 'SELL' ... else ...
        -- Let's check logic: if Taker is BUY, Maker MUST be SELL.
        -- The queue lookup `queue:...:opposite_side` ensures this.
        -- So `maker_side` should match `opposite_side`.
      end
    else
      -- Taker is SELL
      if would_overflow_mul(trade_qty, base_factor) then
        return overflow_error('trade_qty * base_factor', trade_qty, base_factor)
      end
      local trade_qty_balance = trade_qty * base_factor
      if taker_available_base_after < trade_qty_balance then
        stop_matching = true
        break
      end

      local credit_market = trade_quote - taker_fee
      if would_overflow_mul(credit_market, quote_factor) then
        return overflow_error('credit_market * quote_factor', credit_market, quote_factor)
      end
      local credit_balance = credit_market * quote_factor

      -- Maker checks (Maker is BUY)
      -- Maker BUY checks
      local debit_market_maker = trade_quote + maker_fee
      if would_overflow_mul(debit_market_maker, quote_factor) then
        return overflow_error('debit_market_maker * quote_factor', debit_market_maker, quote_factor)
      end
      local debit_balance_maker = debit_market_maker * quote_factor
      if would_overflow_mul(trade_qty, base_factor) then
        return overflow_error('trade_qty * base_factor', trade_qty, base_factor)
      end
      local trade_qty_balance_maker = trade_qty * base_factor

      -- Fee Checks and Accumulation
      taker_fees_collected = taker_fees_collected + taker_fee
      maker_fees_collected = maker_fees_collected + maker_fee
      local fee_total_market = taker_fee + maker_fee
      if would_overflow_mul(fee_total_market, quote_factor) then
        return overflow_error('fee_total_market * quote_factor', fee_total_market, quote_factor)
      end
      add_fee(quote_asset, fee_total_market * quote_factor)

      -- Writes for Taker (SELL)
      taker_available_base_after = taker_available_base_after - trade_qty_balance
      op_sub(user_id, base_asset, trade_qty_balance, 'TAKER_SPEND', timestamp,
        'TAKER_SPEND:' .. market_seq .. '_' .. trade_seq .. ':' .. order_id)

      op_add(user_id, quote_asset, credit_balance, 'TAKER_RECEIVE', timestamp,
        'TAKER_RECEIVE:' .. market_seq .. '_' .. trade_seq .. ':' .. order_id)

      taker_quote_received = taker_quote_received + credit_market
      taker_base_sold = taker_base_sold + trade_qty

      -- Writes for Maker (BUY)
      op_sub_locked(maker_user_id, quote_asset, debit_balance_maker, 'MAKER_RELEASE', timestamp,
        'MAKER_RELEASE:' .. market_seq .. '_' .. trade_seq .. ':' .. maker_order_id)
      if redis.call('HEXISTS', maker_order_key, 'reserved_quote') == 1 then
        redis.call('HINCRBY', maker_order_key, 'reserved_quote', format_int(-debit_balance_maker))
      end

      op_add(maker_user_id, base_asset, trade_qty_balance_maker, 'MAKER_RECEIVE', timestamp,
        'MAKER_RECEIVE:' .. market_seq .. '_' .. trade_seq .. ':' .. maker_order_id)
    end

    maker_remaining = maker_remaining - trade_qty
    remaining = remaining - trade_qty
    executed_quantity = executed_quantity + trade_qty
    executed_quote = executed_quote + trade_quote

    redis.call('HSET', maker_order_key, 'remaining', maker_remaining)
    local maker_executed_quote = redis.call('HINCRBY', maker_order_key, 'executed_quote', format_int(trade_quote))

    -- Update volume first before any cleanup
    local new_maker_vol = redis.call('HINCRBY', opposite_volume_key, price_member, format_int(-trade_qty))
    publish_depth_update(symbol, (is_buy and 'SELL' or 'BUY'), price_member, -trade_qty, new_maker_vol, timestamp, market_seq)

    if maker_remaining == 0 then
      -- Cleanup any residual reserved amounts (dust from rounding)
      local residual_base = as_number(redis.call('HGET', maker_order_key, 'reserved_base'))
      if residual_base > 0 then
        op_unlock(maker_user_id, base_asset, residual_base, 'DUST_RELEASE', timestamp,
          'DUST_RELEASE:' .. market_seq .. '_' .. trade_seq .. ':' .. maker_order_id)
      end
      local residual_quote = as_number(redis.call('HGET', maker_order_key, 'reserved_quote'))
      if residual_quote > 0 then
        op_unlock(maker_user_id, quote_asset, residual_quote, 'DUST_RELEASE', timestamp,
          'DUST_RELEASE:' .. market_seq .. '_' .. trade_seq .. ':' .. maker_order_id)
      end

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
        'executed_quote', format_int(maker_executed_quote),
        'ts', tostring(timestamp),
        'sequence', tostring(redis.call('HGET', maker_order_key, 'sequence') or '')
      )
      mark_tombstone(maker_order_id, 'FILLED')
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
        'executed_quote', format_int(maker_executed_quote),
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
      timestamp = timestamp,
      trade_seq = trade_seq
    }
    append_trade(trades, trade_payload)
    -- Stream entry with near-length trimming to avoid unbounded growth
    -- Use MAXLEN ~ for amortized trimming; length threshold sourced from market config.
    redis.call('XADD', trades_key, 'MAXLEN', '~', trades_maxlen, '*',
      'taker_order_id', order_id,
      'taker_user_id', user_id,
      'maker_order_id', maker_order_id,
      'maker_user_id', maker_user_id,
      'buy_order_id', is_buy and order_id or maker_order_id,
      'buy_user_id', is_buy and user_id or maker_user_id,
      'sell_order_id', is_buy and maker_order_id or order_id,
      'sell_user_id', is_buy and maker_user_id or user_id,
      'taker_side', is_buy and 'BUY' or 'SELL',
      'price', format_int(trade_price),
      'quantity', format_int(trade_qty),
      'quote', format_int(trade_quote),
      'taker_fee', format_int(taker_fee),
      'maker_fee', format_int(maker_fee),
      'symbol', symbol,
      'ts', tostring(timestamp),
      'sequence', tostring(trade_seq)
    )
  until true
end

local remaining_before_post = remaining
local order_status

local market_seq = redis.call('INCR', seq_key)
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
        local reserve_fee = math.floor((reserve_quote * maker_fee_bps) / 10000)
        local reserve_total = reserve_quote + reserve_fee
        if reserve_total > 0 then
          if would_overflow_mul(reserve_total, quote_factor) then
            return overflow_error('reserve_total * quote_factor', reserve_total, quote_factor)
          end
          local reserve_quote_balance = reserve_total * quote_factor
          if taker_available_quote_after < reserve_quote_balance then
            return cjson.encode({ error = 'INSUFFICIENT_FUNDS_TO_REST', asset = quote_asset })
          end
          taker_available_quote_after = taker_available_quote_after - reserve_quote_balance
          taker_reserved_quote = taker_reserved_quote + reserve_quote_balance
          reserved_quote_for_order = reserve_quote_balance
          op_lock(user_id, quote_asset, reserve_quote_balance, 'TAKER_RESERVE', timestamp,
            'order_submit:' .. market_seq .. ':' .. order_id)
        end
      else
        local reserve_qty = remaining
        if reserve_qty > 0 then
          if would_overflow_mul(reserve_qty, base_factor) then
            return overflow_error('reserve_qty * base_factor', reserve_qty, base_factor)
          end
          local reserve_qty_balance = reserve_qty * base_factor
          if taker_available_base_after < reserve_qty_balance then
            return cjson.encode({ error = 'INSUFFICIENT_FUNDS_TO_REST', asset = base_asset })
          end
          taker_available_base_after = taker_available_base_after - reserve_qty_balance
          taker_reserved_base = taker_reserved_base + reserve_qty_balance
          reserved_base_for_order = reserve_qty_balance
          op_lock(user_id, base_asset, reserve_qty_balance, 'TAKER_RESERVE', timestamp,
            'order_submit:' .. market_seq .. ':' .. order_id)
        end
      end

      local price_member = format_int(price_limit)
      local queue_key = 'queue:' .. symbol .. ':' .. side .. ':' .. price_member
      redis.call('RPUSH', queue_key, order_id)

      if is_buy then
        redis.call('ZADD', own_book_key, -price_limit, price_member)
      else
        redis.call('ZADD', own_book_key, price_limit, price_member)
      end

      redis.call('HINCRBY', own_volume_key, price_member, format_int(remaining))
      publish_depth_update(symbol, side, price_member, remaining, redis.call('HGET', own_volume_key, price_member),
        timestamp, market_seq)
    end
  end
end

redis.call('HMSET', order_key,
  'order_id', order_id,
  'user_id', user_id,
  'symbol', symbol,
  'side', side,
  'type', order_type,
  'price', format_int(price_limit),
  'quantity', format_int(quantity),
  'remaining', format_int(remaining),
  'reserved_base', format_int(reserved_base_for_order),
  'reserved_quote', format_int(reserved_quote_for_order),
  'executed_quote', format_int(executed_quote),
  'status', order_status,
  'created_at', tostring(timestamp),
  'sequence', tostring(market_seq)
)

-- Maintain per-user active orders index for the taker.
-- Index only resting LIMIT orders with remaining > 0.
local taker_index_key = 'user_orders:' .. user_id .. ':' .. symbol
if order_type == 'LIMIT' and remaining > 0 and (order_status == 'OPEN' or order_status == 'PARTIALLY_FILLED') then
  redis.call('ZADD', taker_index_key, market_seq, order_id)
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
  'price', format_int(price_limit),
  'quantity', format_int(quantity),
  'remaining', format_int(remaining),
  'executed_quote', format_int(executed_quote),
  'ts', tostring(timestamp),
  'sequence', tostring(market_seq)
)

-- Delete terminal taker orders to keep memory bounded
if order_status == 'FILLED' or order_status == 'NO_LIQUIDITY' then
  mark_tombstone(order_id, order_status)
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
