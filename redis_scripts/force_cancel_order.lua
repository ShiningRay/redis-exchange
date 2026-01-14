-- force_cancel_order.lua
-- Performs force cancellation of an order, bypassing status checks.
-- Modes:
--   1. DELETE_ONLY: Remove order and cleanup queues/books/indices. Do NOT modify balances.
--   2. BEST_EFFORT_UNLOCK: Remove order, cleanup, and refund whatever reserved balance is available (up to the order's lock).
--
-- KEYS:
--   1. order hash (order:{order_id})
-- ARGV:
--   1. requested_order_id
--   2. mode ("DELETE_ONLY" or "BEST_EFFORT_UNLOCK")
--
-- Returns JSON with status.

local cjson = cjson
local order_key = KEYS[1]
local requested_id = ARGV[1]
local mode = ARGV[2]

-- Helpers
local function to_map(array)
  local map = {}
  for i = 1, #array, 2 do
    map[array[i]] = array[i + 1]
  end
  return map
end

local function as_number(value)
  return tonumber(value) or 0
end

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
    'reason', reason or 'FORCE_CANCEL',
    'ts', tostring(now_ts),
    'sequence', tostring(seq),
    'biz_id', ledger_biz_id
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

local order = to_map(redis.call('HGETALL', order_key))
if next(order) == nil then
  return cjson.encode({ status = 'NOT_FOUND', order_id = requested_id })
end

local order_id = order['order_id'] or requested_id
local symbol = order['symbol']
local side = order['side']
local price = order['price']
local remaining = as_number(order['remaining'])
local user_id = order['user_id']
local status = order['status']

-- Clean up Book / Queue / Volume
if symbol and side and price and remaining > 0 then
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
  
  refresh_ticker(symbol)
end

-- Clean up User Index
if user_id and symbol and order_id then
  local index_key = 'user_orders:' .. user_id .. ':' .. symbol
  redis.call('ZREM', index_key, order_id)
end

-- Handle Balances (Only for BEST_EFFORT_UNLOCK)
if mode == 'BEST_EFFORT_UNLOCK' and remaining > 0 and user_id then
  local market = to_map(redis.call('HGETALL', 'market:' .. symbol))
  if next(market) then
    local balance_key = 'balance:' .. user_id
    local asset_to_unlock = nil
    local amount_to_unlock = 0
    
    if side == 'SELL' then
      asset_to_unlock = market['base_asset']
      amount_to_unlock = as_number(order['reserved_base'])
      if amount_to_unlock <= 0 then amount_to_unlock = remaining end
    else
      asset_to_unlock = market['quote_asset']
      amount_to_unlock = as_number(order['reserved_quote'])
      if amount_to_unlock <= 0 then
        local quantity_scale = as_number(market['quantity_scale'])
        if quantity_scale <= 0 then quantity_scale = 1 end
        amount_to_unlock = math.floor((as_number(price) * remaining) / quantity_scale)
      end
    end

    if asset_to_unlock and amount_to_unlock > 0 then
      local current_reserved = as_number(redis.call('HGET', balance_key, asset_to_unlock .. ':reserved'))
      local final_unlock = amount_to_unlock
      if current_reserved < amount_to_unlock then
        final_unlock = current_reserved
      end
      
      if final_unlock > 0 then
        redis.call('HINCRBY', balance_key, asset_to_unlock .. ':reserved', -final_unlock)
        append_ledger(user_id, asset_to_unlock, 'reserved', -final_unlock, 'FORCE_CANCEL_RELEASE', nil)
        redis.call('HINCRBY', balance_key, asset_to_unlock .. ':available', final_unlock)
        append_ledger(user_id, asset_to_unlock, 'available', final_unlock, 'FORCE_CANCEL_REFUND', nil)
      end
    end
  end
end

-- Publish Event
if symbol then
  local now = redis.call('TIME')
  local ts_ms = (tonumber(now[1]) or 0) * 1000 + math.floor((tonumber(now[2]) or 0) / 1000)
  local seq_key = 'seq:' .. symbol
  local sequence = redis.call('INCR', seq_key)
  local orders_key = 'orders:' .. symbol
  local market_config = to_map(redis.call('HGETALL', 'market:' .. symbol))
  local orders_maxlen = tonumber(market_config['orders_maxlen']) or 1000000
  
  redis.call('XADD', orders_key, 'MAXLEN', '~', orders_maxlen, '*',
    'order_id', order_id,
    'user_id', user_id,
    'symbol', symbol,
    'side', side,
    'type', order['type'] or '',
    'status', 'CANCELLED', -- Force cancel still maps to CANCELLED state for downstream consumers? Or FORCE_CANCELLED? Let's use CANCELLED for compatibility.
    'price', tostring(price),
    'quantity', tostring(order['quantity'] or '0'),
    'remaining', '0',
    'ts', tostring(ts_ms),
    'sequence', tostring(sequence),
    'reason', 'FORCE_CANCEL'
  )
end

-- Tombstone
local tombstone_ttl = 86400 -- default
if symbol then
  local m = to_map(redis.call('HGETALL', 'market:' .. symbol))
  if m['order_tombstone_ttl_sec'] then
    tombstone_ttl = tonumber(m['order_tombstone_ttl_sec'])
  end
end
redis.call('SET', 'order_tombstone:' .. order_id, 'CANCELLED', 'EX', tombstone_ttl)

-- Delete Order
redis.call('DEL', order_key)

return cjson.encode({ status = 'OK', mode = mode })
