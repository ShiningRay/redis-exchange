-- audit_user_balance.lua
-- Calculates required reserved balances from active orders and reconciles with actual user balance.
--
-- KEYS:
--   1. balance hash (balance:{user_id})
-- ARGV:
--   1. user_id
--   2. fix_mode ('1' for true, '0' for false)
--   3. timestamp (for ledger)
--   4..N. symbols (list of all market symbols to scan)
--
-- Returns JSON object:
-- {
--   "deficits": [ { "asset": "BTC", "amount": 100 } ],
--   "fixes": [ { "asset": "USDT", "action": "LOCK", "amount": 50 } ]
-- }

local cjson = cjson
local balance_key = KEYS[1]
local user_id = ARGV[1]
local fix_mode = (ARGV[2] == '1')
local ts = ARGV[3]
local symbols = {}
for i = 4, #ARGV do
  table.insert(symbols, ARGV[i])
end

-- Helpers
local function as_number(value)
  return tonumber(value) or 0
end

local function append_ledger(uid, asset, action, amount, new_available, new_reserved, reason, timestamp)
  if amount == 0 then return end
  local now_ts = timestamp
  if not now_ts or tonumber(now_ts) <= 0 then
    local now = redis.call('TIME')
    now_ts = (tonumber(now[1]) or 0) * 1000 + math.floor((tonumber(now[2]) or 0) / 1000)
  end
  local seq = redis.call('INCR', 'ledger_seq:' .. uid .. ':' .. asset)
  local ledger_biz_id = 'AUDIT:' .. uid .. ':' .. asset .. ':' .. action .. ':' .. tostring(seq)
  redis.call('XADD', 'account_ledger', 'MAXLEN', '~', 1000000, '*',
    'user_id', uid,
    'asset', asset,
    'action', action,
    'amount', tostring(amount),
    'new_available', tostring(new_available),
    'new_reserved', tostring(new_reserved),
    'reason', reason,
    'ts', tostring(now_ts),
    'sequence', tostring(seq),
    'biz_id', ledger_biz_id
  )
end

-- 1. Calculate Required Reserved
local required = {} -- asset -> amount

for _, symbol in ipairs(symbols) do
  local index_key = 'user_orders:' .. user_id .. ':' .. symbol
  -- Use ZRANGE to get all order IDs
  local order_ids = redis.call('ZRANGE', index_key, 0, -1)

  if #order_ids > 0 then
    -- Optimize: We need base/quote asset for this symbol.
    -- We can fetch it once per symbol.
    local market_key = 'market:' .. symbol
    local m = redis.call('HMGET', market_key, 'base_asset', 'quote_asset')
    local base_asset = m[1]
    local quote_asset = m[2]

    if base_asset and quote_asset then
      for _, oid in ipairs(order_ids) do
        local order_key = 'order:' .. oid
        local reserved = redis.call('HMGET', order_key, 'reserved_base', 'reserved_quote')
        local r_base = as_number(reserved[1])
        local r_quote = as_number(reserved[2])

        if r_base > 0 then
          required[base_asset] = (required[base_asset] or 0) + r_base
        end
        if r_quote > 0 then
          required[quote_asset] = (required[quote_asset] or 0) + r_quote
        end
      end
    end
  end
end

-- 2. Compare with Actual Balance & Fix
local deficits = {}
local fixes = {}

-- We iterate over all assets that have requirements OR exist in balance?
-- Ideally we should also check if we have reserved balance for assets with NO orders.
-- But iterating all fields in balance hash is expensive if it's huge?
-- Usually user balance hash has limited fields. Let's iterate all reserved fields in balance too.

local all_assets = {}
for a, _ in pairs(required) do all_assets[a] = true end

-- Also scan balance hash for any 'reserved' fields
local balance_fields = redis.call('HGETALL', balance_key)
for i = 1, #balance_fields, 2 do
  local field = balance_fields[i]
  if string.find(field, ':reserved$') then
    local asset = string.sub(field, 1, -10) -- remove ':reserved'
    all_assets[asset] = true
  end
end

for asset, _ in pairs(all_assets) do
  local req_amount = required[asset] or 0
  local actual_reserved = as_number(redis.call('HGET', balance_key, asset .. ':reserved'))
  local diff = req_amount - actual_reserved

  if diff > 0 then
    -- Deficit: Need to lock more
    local actual_available = as_number(redis.call('HGET', balance_key, asset .. ':available'))
    local to_lock = diff
    if actual_available < to_lock then
      to_lock = actual_available
    end

    if fix_mode and to_lock > 0 then
      local new_available = redis.call('HINCRBY', balance_key, asset .. ':available', -to_lock)
      local new_reserved = redis.call('HINCRBY', balance_key, asset .. ':reserved', to_lock)
      append_ledger(user_id, asset, 'LOCK', to_lock, new_available, new_reserved, 'AUDIT_FIX_LOCK', ts)

      table.insert(fixes, { asset = asset, action = 'LOCK', amount = to_lock })
    end

    local remaining_deficit = diff - to_lock
    if remaining_deficit > 0 then
      table.insert(deficits, { asset = asset, amount = remaining_deficit })
    end
  elseif diff < 0 then
    -- Surplus: Locked too much. Release to available.
    local to_release = -diff
    if fix_mode then
      local new_reserved = redis.call('HINCRBY', balance_key, asset .. ':reserved', -to_release)
      local new_available = redis.call('HINCRBY', balance_key, asset .. ':available', to_release)
      append_ledger(user_id, asset, 'UNLOCK', to_release, new_available, new_reserved, 'AUDIT_FIX_RELEASE', ts)

      table.insert(fixes, { asset = asset, action = 'RELEASE', amount = to_release })
    end
  end
end

return cjson.encode({ deficits = deficits, fixes = fixes })
