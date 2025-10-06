-- cancel_all_orders.lua cancels every open or partially filled order for a user,
-- using per-user, per-symbol active order indexes to avoid scanning all orders.
--
-- ARGV:
--   1. user_id
--
-- Returns JSON array where each element mirrors cancel_order.lua payload.

-- Redis Lua environment provides global `cjson`; no `require` is allowed.
local cjson = cjson

local function to_map(array)
  local map = {}
  for i = 1, #array, 2 do
    map[array[i]] = array[i + 1]
  end
  return map
end

local function as_number(value)
  if not value then
    return 0
  end
  local num = tonumber(value)
  if not num then
    return 0
  end
  return num
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
  redis.call('XADD', 'account_ledger', 'MAXLEN', '~', 1000000, '*',
    'user_id', user_id,
    'asset', asset,
    'bucket', bucket,
    'delta', tostring(delta),
    'reason', reason or 'CANCEL_ALL',
    'ts', tostring(now_ts),
    'sequence', tostring(seq)
  )
end

local function refresh_ticker(symbol)
  local ticker_key = 'ticker:' .. symbol
  local best_bid_member = redis.call('ZRANGE', 'book:' .. symbol .. ':BUY', -1, -1)
  local best_bid_price = best_bid_member[1] or '0'
  local best_bid_volume = '0'
  if best_bid_member[1] then
    best_bid_volume = redis.call('HGET', 'volume:' .. symbol .. ':BUY', best_bid_price) or '0'
  end

  local best_ask_member = redis.call('ZRANGE', 'book:' .. symbol .. ':SELL', 0, 0)
  local best_ask_price = best_ask_member[1] or '0'
  local best_ask_volume = '0'
  if best_ask_member[1] then
    best_ask_volume = redis.call('HGET', 'volume:' .. symbol .. ':SELL', best_ask_price) or '0'
  end

  redis.call('HSET', ticker_key,
    'best_bid_price', best_bid_price,
    'best_bid_volume', tostring(best_bid_volume),
    'best_ask_price', best_ask_price,
    'best_ask_volume', tostring(best_ask_volume)
  )
end

local function release_reserved(market, side, user_id, price, remaining)
  local base_asset = market['base_asset']
  local quote_asset = market['quote_asset']
  local quantity_scale = as_number(market['quantity_scale'])
  if quantity_scale <= 0 then
    quantity_scale = 1
  end
  -- Fees are deducted only upon trade execution; do not include fees in cancellation refunds

  local balance_key = 'balance:' .. user_id

  if side == 'SELL' then
    redis.call('HINCRBY', balance_key, base_asset .. ':reserved', -remaining)
    append_ledger(user_id, base_asset, 'reserved', -remaining, 'CANCEL_ALL_RELEASE', nil)
    redis.call('HINCRBY', balance_key, base_asset .. ':available', remaining)
    append_ledger(user_id, base_asset, 'available', remaining, 'CANCEL_ALL_REFUND', nil)
  else
    local notional = math.floor((as_number(price) * remaining) / quantity_scale)
    if notional > 0 then
      redis.call('HINCRBY', balance_key, quote_asset .. ':reserved', -notional)
      append_ledger(user_id, quote_asset, 'reserved', -notional, 'CANCEL_ALL_RELEASE', nil)
      redis.call('HINCRBY', balance_key, quote_asset .. ':available', notional)
      append_ledger(user_id, quote_asset, 'available', notional, 'CANCEL_ALL_REFUND', nil)
    end
  end
end

local function cancel_order(order_key, requested_id, touched_symbols)
  local order = to_map(redis.call('HGETALL', order_key))
  if next(order) == nil then
    return nil
  end

  local order_id = order['order_id'] or requested_id
  local symbol = order['symbol']
  local side = order['side']
  local price = order['price']
  local remaining = as_number(order['remaining'])
  local status = order['status'] or 'UNKNOWN'
  local user_id = order['user_id']

  if remaining <= 0 then
    return nil
  end

  if not (symbol and side and price and user_id) then
    return nil
  end

  local market = to_map(redis.call('HGETALL', 'market:' .. symbol))
  if next(market) == nil then
    return nil
  end

  release_reserved(market, side, user_id, price, remaining)

  local price_member = tostring(price)
  local queue_key = 'queue:' .. symbol .. ':' .. side .. ':' .. price_member
  redis.call('LREM', queue_key, 0, order_id)

  local volume_key = 'volume:' .. symbol .. ':' .. side
  local remaining_volume = redis.call('HINCRBY', volume_key, price_member, -remaining)
  if remaining_volume <= 0 then
    redis.call('HDEL', volume_key, price_member)
    redis.call('DEL', queue_key)
    local book_key = 'book:' .. symbol .. ':' .. side
    redis.call('ZREM', book_key, price_member)
  end

  redis.call('HMSET', order_key,
    'status', 'CANCELLED',
    'remaining', '0'
  )

  -- Remove from user's active orders index
  if user_id and symbol and order_id then
    local index_key = 'user_orders:' .. user_id .. ':' .. symbol
    redis.call('ZREM', index_key, order_id)
  end

  -- Publish order cancellation event to orders stream and delete terminal order hash
  do
    local now = redis.call('TIME')
    local ts_ms = (tonumber(now[1]) or 0) * 1000 + math.floor((tonumber(now[2]) or 0) / 1000)
    local seq_key = 'seq:' .. symbol
    local sequence = redis.call('INCR', seq_key)
    local orders_key = 'orders:' .. symbol
    local order_type = order['type'] or ''
    local quantity = order['quantity'] or '0'

    local orders_maxlen = tonumber(market['orders_maxlen']) or 1000000
    redis.call('XADD', orders_key, 'MAXLEN', '~', orders_maxlen, '*',
      'order_id', order_id,
      'user_id', user_id,
      'symbol', symbol,
      'side', side,
      'type', order_type,
      'status', 'CANCELLED',
      'price', tostring(price),
      'quantity', tostring(quantity),
      'remaining', '0',
      'ts', tostring(ts_ms),
      'sequence', tostring(sequence)
    )

    -- Delete terminal order hash to keep storage lean
    redis.call('DEL', order_key)
  end

  touched_symbols[symbol] = true

  return {
    status = 'CANCELLED',
    order_id = order_id,
    symbol = symbol,
    remaining_quantity = 0
  }
end

local user_id = ARGV[1]
if not user_id or user_id == '' then
  return cjson.encode({ error = 'INVALID_USER_ID' })
end

local results = {}
local touched_symbols = {}

-- Iterate user's active order indexes: user_orders:{user_id}:*
local cursor = '0'
repeat
  local index_scan = redis.call('SCAN', cursor, 'MATCH', 'user_orders:' .. user_id .. ':*', 'COUNT', 100)
  cursor = index_scan[1]
  local index_keys = index_scan[2]

  for i = 1, #index_keys do
    local index_key = index_keys[i]
    -- derive symbol from key: user_orders:{user_id}:{symbol}
    local symbol = string.sub(index_key, string.len('user_orders:' .. user_id .. ':') + 1)
    -- fetch all order ids in this index
    local order_ids = redis.call('ZRANGE', index_key, 0, -1)
    for j = 1, #order_ids do
      local oid = order_ids[j]
      local order_key = 'order:' .. oid
      -- confirm status is cancelable
      local status = redis.call('HGET', order_key, 'status')
      local remaining = as_number(redis.call('HGET', order_key, 'remaining'))
      if remaining > 0 and (not status or status == 'OPEN' or status == 'PARTIALLY_FILLED') then
        local response = cancel_order(order_key, oid, touched_symbols)
        if response then
          results[#results + 1] = response
        end
      else
        -- not active; ensure it's not in index to avoid stale entries
        redis.call('ZREM', index_key, oid)
      end
    end
  end
until cursor == '0'

for symbol, _ in pairs(touched_symbols) do
  refresh_ticker(symbol)
end

return cjson.encode(results)
