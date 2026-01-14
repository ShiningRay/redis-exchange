--[[
finalize_precision_update.lua
Switches the market to the new precision configuration and enables the new order books.

KEYS:
  1. market:{symbol}
  2. book:{symbol}:BUY
  3. book:{symbol}:SELL
  4. volume:{symbol}:BUY
  5. volume:{symbol}:SELL
  6. book:{symbol}:BUY:TMP
  7. book:{symbol}:SELL:TMP
  8. volume:{symbol}:BUY:TMP
  9. volume:{symbol}:SELL:TMP

ARGV:
  1. symbol
  2. new_price_scale
  3. new_quantity_scale

Returns:
  JSON object { status: 'OK' }
]]

local cjson = cjson

local market_key = KEYS[1]
local book_buy_key = KEYS[2]
local book_sell_key = KEYS[3]
local volume_buy_key = KEYS[4]
local volume_sell_key = KEYS[5]
local book_buy_tmp = KEYS[6]
local book_sell_tmp = KEYS[7]
local volume_buy_tmp = KEYS[8]
local volume_sell_tmp = KEYS[9]

local symbol = ARGV[1]
local new_price_scale = ARGV[2]
local new_quantity_scale = ARGV[3]

-- Update Market Config
redis.call('HSET', market_key, 'price_scale', new_price_scale, 'quantity_scale', new_quantity_scale)

-- Replace Books
redis.call('DEL', book_buy_key)
if redis.call('EXISTS', book_buy_tmp) == 1 then
  redis.call('RENAME', book_buy_tmp, book_buy_key)
end

redis.call('DEL', book_sell_key)
if redis.call('EXISTS', book_sell_tmp) == 1 then
  redis.call('RENAME', book_sell_tmp, book_sell_key)
end

-- Replace Volumes
redis.call('DEL', volume_buy_key)
if redis.call('EXISTS', volume_buy_tmp) == 1 then
  redis.call('RENAME', volume_buy_tmp, volume_buy_key)
end

redis.call('DEL', volume_sell_key)
if redis.call('EXISTS', volume_sell_tmp) == 1 then
  redis.call('RENAME', volume_sell_tmp, volume_sell_key)
end

-- Rename all TMP queues to real queues
-- We need to scan for them because we don't know exactly which prices exist.
-- But SCAN in Lua is discouraged for large keyspaces.
-- However, we can infer the keys from the NEW books we just put in place.
-- Iterate over the new books to find active prices and rename their queues.

local function rename_queues(book_key, side)
  local prices = redis.call('ZRANGE', book_key, 0, -1)
  for _, price_member in ipairs(prices) do
    local tmp_queue = 'queue:' .. symbol .. ':' .. side .. ':' .. price_member .. ':TMP'
    local real_queue = 'queue:' .. symbol .. ':' .. side .. ':' .. price_member
    
    redis.call('DEL', real_queue) -- Should be empty as we deleted old ones in batch, but safety first
    if redis.call('EXISTS', tmp_queue) == 1 then
      redis.call('RENAME', tmp_queue, real_queue)
    end
  end
end

rename_queues(book_buy_key, 'BUY')
rename_queues(book_sell_key, 'SELL')

return cjson.encode({ status = 'OK' })
