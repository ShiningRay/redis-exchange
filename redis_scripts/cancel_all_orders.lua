-- cancel_all_orders.lua cancels every open or partially filled order for a user.
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
  local maker_fee_bps = as_number(market['maker_fee_bps'])

  local balance_key = 'balance:' .. user_id

  if side == 'SELL' then
    redis.call('HINCRBY', balance_key, base_asset .. ':reserved', -remaining)
    redis.call('HINCRBY', balance_key, base_asset .. ':available', remaining)
  else
    local notional = math.floor((as_number(price) * remaining) / quantity_scale)
    local fee = math.floor((notional * maker_fee_bps) / 10000)
    local total = notional + fee
    if total > 0 then
      redis.call('HINCRBY', balance_key, quote_asset .. ':reserved', -total)
      redis.call('HINCRBY', balance_key, quote_asset .. ':available', total)
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
local cursor = '0'

repeat
  local scan_result = redis.call('SCAN', cursor, 'MATCH', 'order:*', 'COUNT', 200)
  cursor = scan_result[1]
  local keys = scan_result[2]

  for i = 1, #keys do
    local key = keys[i]
    local owner = redis.call('HGET', key, 'user_id')
    if owner == user_id then
      local status = redis.call('HGET', key, 'status')
      if (not status) or status == 'OPEN' or status == 'PARTIALLY_FILLED' then
        local response = cancel_order(key, string.sub(key, 7), touched_symbols)
        if response then
          results[#results + 1] = response
        end
      end
    end
  end
until cursor == '0'

for symbol, _ in pairs(touched_symbols) do
  refresh_ticker(symbol)
end

return cjson.encode(results)
