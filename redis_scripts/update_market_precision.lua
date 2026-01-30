--[[
update_market_precision.lua
Revises all orders for a market to match new precision settings.
Refunds any "dust" amounts to user balances.

KEYS:
  1. market:{symbol}
  2. book:{symbol}:BUY
  3. book:{symbol}:SELL
  4. volume:{symbol}:BUY
  5. volume:{symbol}:SELL
  6. orders:{symbol} (for events)

ARGV:
  1. symbol
  2. new_price_scale
  3. new_quantity_scale
  4. timestamp

Returns:
  JSON object { updated_orders: N, refunds: M }
]]

local cjson = cjson

local market_key = KEYS[1]
local book_buy_key = KEYS[2]
local book_sell_key = KEYS[3]
local volume_buy_key = KEYS[4]
local volume_sell_key = KEYS[5]
local orders_key = KEYS[6]

local symbol = ARGV[1]
local new_price_scale = tonumber(ARGV[2])
local new_quantity_scale = tonumber(ARGV[3])
local timestamp = tonumber(ARGV[4])

if not (symbol and new_price_scale and new_quantity_scale and timestamp) then
  return cjson.encode({ error = 'INVALID_ARGUMENTS' })
end

if new_price_scale <= 0 or new_quantity_scale <= 0 then
  return cjson.encode({ error = 'INVALID_SCALE' })
end

-- Helper: Convert HGETALL to map
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

-- Helper: Append Ledger (Copied from match_order.lua - shortened)
local function append_ledger(user_id, asset, bucket, delta, reason, ts)
  if delta == 0 then return end
  local seq = redis.call('INCR', 'ledger_seq:' .. user_id .. ':' .. asset)
  local ledger_biz_id = 'PRECISION:' .. symbol .. ':' .. ts .. ':' .. seq
  redis.call('XADD', 'account_ledger', 'MAXLEN', '~', 1000000, '*',
    'user_id', user_id,
    'asset', asset,
    'bucket', bucket,
    'amount', tostring(delta),
    'reason', reason,
    'ts', tostring(ts),
    'sequence', tostring(seq),
    'biz_id', ledger_biz_id
  )
end

-- Load Market
local market = to_map(redis.call('HGETALL', market_key))
if next(market) == nil then
  return cjson.encode({ error = 'UNKNOWN_MARKET' })
end

local base_asset = market['base_asset']
local quote_asset = market['quote_asset']
local old_price_scale = tonumber(market['price_scale'])
local old_quantity_scale = tonumber(market['quantity_scale'])
local maker_fee_bps = tonumber(market['maker_fee_bps'] or '0')

-- Load Asset Configs for Factors
local base_asset_map = to_map(redis.call('HGETALL', 'asset:' .. base_asset))
local quote_asset_map = to_map(redis.call('HGETALL', 'asset:' .. quote_asset))
local base_balance_scale = tonumber(base_asset_map['balance_scale'] or '0')
local quote_balance_scale = tonumber(quote_asset_map['balance_scale'] or '0')

-- Validate Asset Scales
local function compute_factor(balance_scale, market_scale)
  if market_scale <= 0 then return 0 end
  local div = math.floor(balance_scale / market_scale)
  if (div * market_scale) ~= balance_scale then return 0 end
  return div
end

local new_base_factor = compute_factor(base_balance_scale, new_quantity_scale)
local new_quote_factor = compute_factor(quote_balance_scale, new_price_scale)

if new_base_factor == 0 or new_quote_factor == 0 then
  return cjson.encode({ error = 'ASSET_SCALE_MISMATCH_WITH_NEW_CONFIG' })
end

-- Update Market Config
redis.call('HSET', market_key, 'price_scale', new_price_scale, 'quantity_scale', new_quantity_scale)

local updated_count = 0
local sides = { 'BUY', 'SELL' }
local queues_to_rename = {} -- { {old_key, new_key, is_tmp} }
-- Actually we use TMP keys for new queues

local function process_side(side)
  local is_buy = (side == 'BUY')
  local book_key = is_buy and book_buy_key or book_sell_key
  local volume_key = is_buy and volume_buy_key or volume_sell_key

  -- Read all levels
  local levels = redis.call('ZRANGE', book_key, 0, -1, 'WITHSCORES')

  -- Clear old book and volume
  redis.call('DEL', book_key)
  redis.call('DEL', volume_key)

  -- We will rebuild book/volume in memory then write
  local new_book = {}   -- price -> score
  local new_volume = {} -- price -> volume

  for i = 1, #levels, 2 do
    local old_price_member = levels[i]
    local old_price = as_number(old_price_member) -- This is the price string/member
    -- Note: Score is also available but we use member as source of truth for price value

    local old_queue_key = 'queue:' .. symbol .. ':' .. side .. ':' .. old_price_member

    -- Calculate New Price
    -- Logic: new_p = floor(old_p * new_scale / old_scale)
    local new_price = math.floor(old_price * new_price_scale / old_price_scale)
    local new_price_member = tostring(new_price)

    -- Iterate Orders
    local orders = redis.call('LRANGE', old_queue_key, 0, -1)
    redis.call('DEL', old_queue_key) -- Delete old queue

    local new_queue_key_tmp = 'queue:' .. symbol .. ':' .. side .. ':' .. new_price_member .. ':TMP'

    for _, order_id in ipairs(orders) do
      local order_key = 'order:' .. order_id
      local order = to_map(redis.call('HGETALL', order_key))

      if next(order) then
        updated_count = updated_count + 1
        local old_qty = as_number(order['quantity'])
        local old_rem = as_number(order['remaining'])
        local old_reserved_base = as_number(order['reserved_base'])
        local old_reserved_quote = as_number(order['reserved_quote'])
        local user_id = order['user_id']

        -- Calculate New Qty/Rem
        local new_qty = math.floor(old_qty * new_quantity_scale / old_quantity_scale)
        local new_rem = math.floor(old_rem * new_quantity_scale / old_quantity_scale)

        -- Calculate New Reserved
        local new_reserved_base = 0
        local new_reserved_quote = 0

        if side == 'SELL' then
          -- SELL: Reserve Base = rem * base_factor
          new_reserved_base = new_rem * new_base_factor
        else
          -- BUY: Reserve Quote = floor(price * rem / qty_scale) + fee
          -- fee = floor(quote * bps / 10000)
          local quote_val = math.floor((new_price * new_rem) / new_quantity_scale)
          local fee = math.floor((quote_val * maker_fee_bps) / 10000)
          local total_quote = quote_val + fee
          new_reserved_quote = total_quote * new_quote_factor
        end

        -- Refunds
        local refund_base = old_reserved_base - new_reserved_base
        local refund_quote = old_reserved_quote - new_reserved_quote

        if refund_base > 0 then
          local bal_key = 'balance:' .. user_id
          redis.call('HINCRBY', bal_key, base_asset .. ':reserved', -refund_base)
          redis.call('HINCRBY', bal_key, base_asset .. ':available', refund_base)
          append_ledger(user_id, base_asset, 'available', refund_base, 'DUST_REFUND', timestamp)
          append_ledger(user_id, base_asset, 'reserved', -refund_base, 'DUST_RELEASE', timestamp)
        end

        if refund_quote > 0 then
          local bal_key = 'balance:' .. user_id
          redis.call('HINCRBY', bal_key, quote_asset .. ':reserved', -refund_quote)
          redis.call('HINCRBY', bal_key, quote_asset .. ':available', refund_quote)
          append_ledger(user_id, quote_asset, 'available', refund_quote, 'DUST_REFUND', timestamp)
          append_ledger(user_id, quote_asset, 'reserved', -refund_quote, 'DUST_RELEASE', timestamp)
        end

        -- Update Order
        if new_rem > 0 then
          redis.call('HMSET', order_key,
            'price', new_price_member,
            'quantity', tostring(new_qty),
            'remaining', tostring(new_rem),
            'reserved_base', tostring(new_reserved_base),
            'reserved_quote', tostring(new_reserved_quote)
          )
          -- Push to new queue (TMP)
          redis.call('RPUSH', new_queue_key_tmp, order_id)

          -- Accumulate Volume
          new_volume[new_price_member] = (new_volume[new_price_member] or 0) + new_rem

          -- Mark this TMP key for renaming later (deduplicate)
          queues_to_rename[new_queue_key_tmp] = 'queue:' .. symbol .. ':' .. side .. ':' .. new_price_member
        else
          -- Filled (Dust eliminated remaining)
          redis.call('HMSET', order_key,
            'price', new_price_member,
            'quantity', tostring(new_qty),
            'remaining', '0',
            'reserved_base', '0',
            'reserved_quote', '0',
            'status', 'FILLED'
          )
          -- Remove from User Index
          local user_idx = 'user_orders:' .. user_id .. ':' .. symbol
          redis.call('ZREM', user_idx, order_id)
          -- Tombstone
          redis.call('SET', 'order_tombstone:' .. order_id, 'FILLED', 'EX', 86400)
          redis.call('DEL', order_key)
        end
      end
    end
  end

  -- Write Book and Volume
  for price_str, vol in pairs(new_volume) do
    if vol > 0 then
      local price_val = tonumber(price_str)
      local score = is_buy and -price_val or price_val
      redis.call('ZADD', book_key, score, price_str)
      redis.call('HSET', volume_key, price_str, vol)
    end
  end
end

process_side('BUY')
process_side('SELL')

-- Rename TMP queues to Real queues
for tmp_key, real_key in pairs(queues_to_rename) do
  redis.call('RENAME', tmp_key, real_key)
end

return cjson.encode({ updated_orders = updated_count })
