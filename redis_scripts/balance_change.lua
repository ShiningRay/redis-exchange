-- balance_change.lua adjusts a user's balance bucket and appends an account ledger entry.
--
-- KEYS:
--   1. balance hash (balance:{user_id})
-- ARGV:
--   1. user_id
--   2. asset (e.g., USDT, BTC)
--   3. bucket ("available" | "reserved")
--   4. delta (integer; positive for credit, negative for debit)
--   5. reason (string; e.g., MANUAL_ADJUST)
--   6. timestamp in ms (optional; when missing, computed via TIME)
--   7. biz_id (optional; idempotency key to avoid duplicate requests)
--
-- Returns JSON with new value or error.

local cjson = cjson

-- Check for system maintenance mode
if redis.call('GET', 'system:maintenance_mode') == '1' then
  return cjson.encode({ error = 'SYSTEM_MAINTENANCE' })
end

local function as_number(value)
  if not value then return 0 end
  local num = tonumber(value)
  if not num then return 0 end
  return num
end

local balance_key = KEYS[1]
local user_id = ARGV[1]
local asset = ARGV[2]
local bucket = ARGV[3]
local delta = tonumber(ARGV[4] or '0') or 0
local reason = ARGV[5] or 'MANUAL_ADJUST'
local ts_arg = ARGV[6]
local biz_id = ARGV[7]

if not (balance_key and user_id and asset and bucket) then
  return cjson.encode({ error = 'INVALID_ARGUMENTS' })
end

if bucket ~= 'available' and bucket ~= 'reserved' then
  return cjson.encode({ error = 'INVALID_BUCKET' })
end

-- Idempotency: if a cached response exists for this biz_id, return it.
local resp_key = nil
if biz_id and biz_id ~= '' then
  resp_key = 'balance_biz:' .. user_id .. ':' .. asset .. ':' .. bucket .. ':' .. biz_id
  local cached = redis.call('GET', resp_key)
  if cached then
    return cached
  end
end

local field = asset .. ':' .. bucket
local before = as_number(redis.call('HGET', balance_key, field))
local after = before + delta
if after < 0 then
  return cjson.encode({ error = 'INSUFFICIENT_FUNDS', asset = asset, bucket = bucket })
end

if delta ~= 0 then
  redis.call('HINCRBY', balance_key, field, delta)
end

local ts
if ts_arg and ts_arg ~= '' then
  ts = tonumber(ts_arg) or 0
else
  local now = redis.call('TIME')
  ts = (tonumber(now[1]) or 0) * 1000 + math.floor((tonumber(now[2]) or 0) / 1000)
end

local seq = redis.call('INCR', 'ledger_seq:' .. user_id .. ':' .. asset)
local ledger_stream_key = 'account_ledger'
local ledger_maxlen = 1000000

-- Determine the biz_id to attach to the ledger entry
local ledger_biz_id = biz_id
if not ledger_biz_id or ledger_biz_id == '' then
  ledger_biz_id = 'AUTO:' .. user_id .. ':' .. asset .. ':' .. bucket .. ':' .. tostring(seq)
end

redis.call('XADD', ledger_stream_key, 'MAXLEN', '~', ledger_maxlen, '*',
  'user_id', user_id,
  'asset', asset,
  'bucket', bucket,
  'delta', tostring(delta),
  'reason', reason,
  'ts', tostring(ts),
  'sequence', tostring(seq),
  'biz_id', ledger_biz_id
)
local result_json = cjson.encode({ ok = true, user_id = user_id, asset = asset, bucket = bucket, delta = delta, value =
after, ts = ts, sequence = seq, biz_id = ledger_biz_id })

-- Cache the result for idempotency if biz_id provided (24h TTL)
if resp_key then
  redis.call('SET', resp_key, result_json, 'EX', 86400)
end

return result_json
