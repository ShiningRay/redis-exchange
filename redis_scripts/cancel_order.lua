-- cancel_order.lua performs atomic cancellation of a resting limit order.
--
-- KEYS:
--   1. order hash (order:{order_id})
-- ARGV:
--   1. requested order_id (for error responses)
--
-- Returns JSON with `status`, `order_id`, and `symbol` when available.

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
    'reason', reason or 'CANCEL',
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

local order_key = KEYS[1]
local requested_id = ARGV[1]

local order = to_map(redis.call('HGETALL', order_key))
if next(order) == nil then
  return cjson.encode({ status = 'NOT_FOUND', order_id = requested_id })
end

local order_id = order['order_id'] or requested_id
local symbol = order['symbol']
local side = order['side']
local price = order['price']
local remaining = as_number(order['remaining'])
local status = order['status'] or 'UNKNOWN'
local user_id = order['user_id']

if remaining <= 0 then
  return cjson.encode({ status = status, order_id = order_id, symbol = symbol or '' })
end

if not (symbol and side and price and user_id) then
  return cjson.encode({ status = 'INVALID_ORDER', order_id = order_id })
end

local market = to_map(redis.call('HGETALL', 'market:' .. symbol))
if next(market) == nil then
  return cjson.encode({ status = 'UNKNOWN_MARKET', order_id = order_id })
end

local base_asset = market['base_asset']
local quote_asset = market['quote_asset']
local quantity_scale = as_number(market['quantity_scale'])
if quantity_scale <= 0 then
  quantity_scale = 1
end
local maker_fee_bps = as_number(market['maker_fee_bps'])

local balance_key = 'balance:' .. user_id

if side == 'SELL' then
  redis.call('HINCRBY', balance_key, base_asset .. ':reserved', -remaining)
  append_ledger(user_id, base_asset, 'reserved', -remaining, 'CANCEL_RELEASE', nil)
  redis.call('HINCRBY', balance_key, base_asset .. ':available', remaining)
  append_ledger(user_id, base_asset, 'available', remaining, 'CANCEL_REFUND', nil)
else
  local notional = math.floor((as_number(price) * remaining) / quantity_scale)
  -- Fees are deducted only upon trade execution; do not include fees in cancellation refunds
  if notional > 0 then
    redis.call('HINCRBY', balance_key, quote_asset .. ':reserved', -notional)
    append_ledger(user_id, quote_asset, 'reserved', -notional, 'CANCEL_RELEASE', nil)
    redis.call('HINCRBY', balance_key, quote_asset .. ':available', notional)
    append_ledger(user_id, quote_asset, 'available', notional, 'CANCEL_REFUND', nil)
  end
end

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

-- Publish order cancellation event to orders stream and delete final order hash
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

refresh_ticker(symbol)

return cjson.encode({
  status = 'CANCELLED',
  order_id = order_id,
  symbol = symbol,
  remaining_quantity = 0
})
