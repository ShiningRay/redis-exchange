--[[
migrate_orders_batch.lua
Process a batch of price levels for precision update.
Reads orders from old queues, converts them, and appends to TMP queues/books.

KEYS:
  1. market:{symbol}
  2. book:{symbol}:{side}:TMP
  3. volume:{symbol}:{side}:TMP
  4. orders:{symbol} (for events)

ARGV:
  1. symbol
  2. side (BUY/SELL)
  3. new_price_scale
  4. new_quantity_scale
  5. timestamp
  6...N. price_members (strings) to process

Returns:
  JSON object { processed_orders: N, processed_levels: M }
]]

local cjson = cjson

local market_key = KEYS[1]
local book_tmp_key = KEYS[2]
local volume_tmp_key = KEYS[3]
local orders_key = KEYS[4]

local symbol = ARGV[1]
local side = ARGV[2]
local new_price_scale = tonumber(ARGV[3])
local new_quantity_scale = tonumber(ARGV[4])
local timestamp = tonumber(ARGV[5])

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

local function append_ledger(user_id, asset, bucket, delta, reason, ts)
  if delta == 0 then return end
  local seq = redis.call('INCR', 'ledger_seq:' .. user_id .. ':' .. asset)
  local ledger_biz_id = 'PRECISION:' .. symbol .. ':' .. ts .. ':' .. seq
  redis.call('XADD', 'account_ledger', 'MAXLEN', '~', 1000000, '*',
    'user_id', user_id,
    'asset', asset,
    'bucket', bucket,
    'delta', tostring(delta),
    'reason', reason,
    'ts', tostring(ts),
    'sequence', tostring(seq),
    'biz_id', ledger_biz_id
  )
end

-- Load Market Config (for old scales)
local market = to_map(redis.call('HGETALL', market_key))
if next(market) == nil then
  return cjson.encode({ error = 'UNKNOWN_MARKET' })
end

local base_asset = market['base_asset']
local quote_asset = market['quote_asset']
local old_price_scale = tonumber(market['price_scale'])
local old_quantity_scale = tonumber(market['quantity_scale'])
local maker_fee_bps = tonumber(market['maker_fee_bps'] or '0')

-- Load Asset Factors
local base_asset_map = to_map(redis.call('HGETALL', 'asset:' .. base_asset))
local quote_asset_map = to_map(redis.call('HGETALL', 'asset:' .. quote_asset))
local base_balance_scale = tonumber(base_asset_map['balance_scale'] or '0')
local quote_balance_scale = tonumber(quote_asset_map['balance_scale'] or '0')

local function compute_factor(balance_scale, market_scale)
  if market_scale <= 0 then return 0 end
  local div = math.floor(balance_scale / market_scale)
  if (div * market_scale) ~= balance_scale then return 0 end
  return div
end

local new_base_factor = compute_factor(base_balance_scale, new_quantity_scale)
local new_quote_factor = compute_factor(quote_balance_scale, new_price_scale)

if new_base_factor == 0 or new_quote_factor == 0 then
  return cjson.encode({ error = 'ASSET_SCALE_MISMATCH' })
end

local processed_orders_count = 0
local processed_levels_count = 0
local is_buy = (side == 'BUY')

-- Iterate over provided price members
for i = 6, #ARGV do
  local old_price_member = ARGV[i]
  local old_price = as_number(old_price_member)
  local old_queue_key = 'queue:' .. symbol .. ':' .. side .. ':' .. old_price_member
  
  -- Calculate New Price
  local new_price = math.floor(old_price * new_price_scale / old_price_scale)
  local new_price_member = tostring(new_price)
  local new_queue_key_tmp = 'queue:' .. symbol .. ':' .. side .. ':' .. new_price_member .. ':TMP'
  
  local orders = redis.call('LRANGE', old_queue_key, 0, -1)
  -- Note: We do NOT delete the old queue here. 
  -- We leave old data intact until finalize step to be safe, 
  -- OR we can delete it now to save space?
  -- Safety first: If script fails midway, we want to be able to retry.
  -- But if we don't delete, re-running this batch will duplicate data in TMP.
  -- Assumption: The caller handles idempotency or we clear TMP before starting.
  -- Actually, let's delete the old queue key as we process it. 
  -- If we crash, we are in a halfway state anyway (Maintenance Mode).
  redis.call('DEL', old_queue_key)
  
  for _, order_id in ipairs(orders) do
    local order_key = 'order:' .. order_id
    local order = to_map(redis.call('HGETALL', order_key))
    
    if next(order) then
      processed_orders_count = processed_orders_count + 1
      local old_qty = as_number(order['quantity'])
      local old_rem = as_number(order['remaining'])
      local old_reserved_base = as_number(order['reserved_base'])
      local old_reserved_quote = as_number(order['reserved_quote'])
      local user_id = order['user_id']
      
      local new_qty = math.floor(old_qty * new_quantity_scale / old_quantity_scale)
      local new_rem = math.floor(old_rem * new_quantity_scale / old_quantity_scale)
      
      local new_reserved_base = 0
      local new_reserved_quote = 0
      
      if side == 'SELL' then
        new_reserved_base = new_rem * new_base_factor
      else
        local quote_val = math.floor((new_price * new_rem) / new_quantity_scale)
        local fee = math.floor((quote_val * maker_fee_bps) / 10000)
        local total_quote = quote_val + fee
        new_reserved_quote = total_quote * new_quote_factor
      end
      
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
      
      if new_rem > 0 then
        redis.call('HMSET', order_key,
          'price', new_price_member,
          'quantity', tostring(new_qty),
          'remaining', tostring(new_rem),
          'reserved_base', tostring(new_reserved_base),
          'reserved_quote', tostring(new_reserved_quote)
        )
        redis.call('RPUSH', new_queue_key_tmp, order_id)
        
        -- Accumulate Volume in TMP
        redis.call('HINCRBY', volume_tmp_key, new_price_member, new_rem)
        
        -- Add to TMP Book
        local score = is_buy and -new_price or new_price
        redis.call('ZADD', book_tmp_key, score, new_price_member)
      else
        redis.call('HMSET', order_key,
          'price', new_price_member,
          'quantity', tostring(new_qty),
          'remaining', '0',
          'reserved_base', '0',
          'reserved_quote', '0',
          'status', 'FILLED'
        )
        redis.call('ZREM', 'user_orders:' .. user_id .. ':' .. symbol, order_id)
        redis.call('SET', 'order_tombstone:' .. order_id, 'FILLED', 'EX', 86400)
        redis.call('DEL', order_key)
      end
    end
  end
  processed_levels_count = processed_levels_count + 1
end

return cjson.encode({ processed_orders = processed_orders_count, processed_levels = processed_levels_count })
