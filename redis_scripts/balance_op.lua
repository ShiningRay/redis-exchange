-- balance_op.lua
-- Atomically adjusts user balance based on specific actions and records ledger entries.
--
-- KEYS:
--   1. balance hash (balance:{user_id})
-- ARGV:
--   1. user_id
--   2. asset
--   3. amount (positive integer/string)
--   4. action (LOCK, UNLOCK, ADD, SUB, SUB_LOCKED, ADD_LOCKED)
--   5. reason
--   6. timestamp (optional)
--   7. biz_id (optional, for idempotency)
--
-- Returns JSON with new balances or error.

local cjson = cjson

if redis.call('GET', 'system:maintenance_mode') == '1' then
  return cjson.encode({ error = 'SYSTEM_MAINTENANCE' })
end

local function as_number(value)
  return tonumber(value) or 0
end

local balance_key = KEYS[1]
local user_id = ARGV[1]
local asset = ARGV[2]
local amount = as_number(ARGV[3])
local action = ARGV[4]
local reason = ARGV[5] or 'MANUAL'
local ts_arg = ARGV[6]
local biz_id = ARGV[7]

if not (balance_key and user_id and asset and action) then
  return cjson.encode({ error = 'INVALID_ARGUMENTS' })
end

if amount <= 0 then
  return cjson.encode({ error = 'INVALID_AMOUNT' })
end

-- Idempotency check
local resp_key = nil
if biz_id and biz_id ~= '' then
  resp_key = 'op_biz:' .. user_id .. ':' .. asset .. ':' .. action .. ':' .. biz_id
  local cached = redis.call('GET', resp_key)
  if cached then
    return cached
  end
end

local avail_field = asset .. ':available'
local reserved_field = asset .. ':reserved'

local avail_bal = as_number(redis.call('HGET', balance_key, avail_field))
local reserved_bal = as_number(redis.call('HGET', balance_key, reserved_field))

local new_avail = avail_bal
local new_reserved = reserved_bal

if action == 'LOCK' then
  if avail_bal < amount then
    return cjson.encode({ error = 'INSUFFICIENT_FUNDS', asset = asset, bucket = 'available' })
  end
  new_avail = avail_bal - amount
  new_reserved = reserved_bal + amount
  redis.call('HINCRBY', balance_key, avail_field, -amount)
  redis.call('HINCRBY', balance_key, reserved_field, amount)
elseif action == 'UNLOCK' then
  if reserved_bal < amount then
    return cjson.encode({ error = 'INSUFFICIENT_FUNDS', asset = asset, bucket = 'reserved' })
  end
  new_reserved = reserved_bal - amount
  new_avail = avail_bal + amount
  redis.call('HINCRBY', balance_key, reserved_field, -amount)
  redis.call('HINCRBY', balance_key, avail_field, amount)
elseif action == 'ADD' then
  new_avail = avail_bal + amount
  redis.call('HINCRBY', balance_key, avail_field, amount)
elseif action == 'SUB' then
  if avail_bal < amount then
    return cjson.encode({ error = 'INSUFFICIENT_FUNDS', asset = asset, bucket = 'available' })
  end
  new_avail = avail_bal - amount
  redis.call('HINCRBY', balance_key, avail_field, -amount)
elseif action == 'SUB_LOCKED' then
  if reserved_bal < amount then
    return cjson.encode({ error = 'INSUFFICIENT_FUNDS', asset = asset, bucket = 'reserved' })
  end
  new_reserved = reserved_bal - amount
  redis.call('HINCRBY', balance_key, reserved_field, -amount)
elseif action == 'ADD_LOCKED' then
  new_reserved = reserved_bal + amount
  redis.call('HINCRBY', balance_key, reserved_field, amount)
else
  return cjson.encode({ error = 'INVALID_ACTION' })
end

-- Ledger Recording
local ts
if ts_arg and ts_arg ~= '' then
  ts = tonumber(ts_arg) or 0
else
  local now = redis.call('TIME')
  ts = (tonumber(now[1]) or 0) * 1000 + math.floor((tonumber(now[2]) or 0) / 1000)
end

local seq = redis.call('INCR', 'ledger_seq:' .. user_id .. ':' .. asset)
local ledger_biz_id = biz_id
if not ledger_biz_id or ledger_biz_id == '' then
  ledger_biz_id = 'AUTO:' .. user_id .. ':' .. asset .. ':' .. action .. ':' .. tostring(seq)
end

redis.call('XADD', 'account_ledger', 'MAXLEN', '~', 1000000, '*',
  'user_id', user_id,
  'asset', asset,
  'action', action,
  'amount', tostring(amount),
  'new_available', tostring(new_avail),
  'new_reserved', tostring(new_reserved),
  'reason', reason,
  'ts', tostring(ts),
  'sequence', tostring(seq),
  'biz_id', ledger_biz_id
)

local result = {
  ok = true,
  user_id = user_id,
  asset = asset,
  action = action,
  amount = amount,
  available = new_avail,
  reserved = new_reserved,
  ts = ts,
  sequence = seq,
  biz_id = ledger_biz_id
}

local result_json = cjson.encode(result)

if resp_key then
  redis.call('SET', resp_key, result_json, 'EX', 86400)
end

return result_json
