# Lua 脚本契约

所有脚本：返回 JSON 字符串（cjson.encode）；失败 `{"error":"CODE"}` 或 `{"status":"..."}`。开头统一检查 `system:maintenance_mode`。加载方式：Ruby 端 `LuaScript`（SCRIPT LOAD + EVALSHA，NOSCRIPT 自动重载）。

## match_order.lua（撮合核心，1026 行）

KEYS（9，顺序固定）：
1. `market:{symbol}`
2. `seq:{symbol}`
3. `book:{symbol}:BUY`
4. `book:{symbol}:SELL`
5. `volume:{symbol}:BUY`
6. `volume:{symbol}:SELL`
7. `balance:{taker_user_id}`
8. `trades:{symbol}`
9. `orders:{symbol}`

ARGV（9）：
1. symbol
2. side（BUY|SELL）
3. order_type（LIMIT|MARKET）
4. order_id
5. user_id（taker）
6. price_limit（scaled integer；市价单 0=无上限）
7. quantity（scaled integer）
8. timestamp_ms
9. user_taker_fee_bps（可选；空/越界则用 market 默认）

注意：maker 的 balance key、`user_fees:{maker}`、`fees:{asset}`、`account_ledger`、`depth:{symbol}`、queue 等都在脚本内动态拼——单实例假设。

返回（成功）：
```json
{
  "order_id": "...", "order_type": "LIMIT",
  "status": "OPEN|PARTIALLY_FILLED|FILLED|NO_LIQUIDITY",
  "requested_quantity": 0, "executed_quantity": 0,
  "remaining_quantity": 0,        // = remaining_before_post：进撮合后未成交部分（限价单即挂单量）
  "price_limit": 0,
  "taker_quote_spent": 0, "taker_quote_received": 0,
  "taker_base_received": 0, "taker_base_sold": 0,
  "taker_fee_paid": 0, "maker_fee_charged": 0,   // market 单位
  "trades": [ { taker_order_id, maker_order_id, buy_order_id, sell_order_id,
                taker_side, price, quantity, quote, taker_fee, maker_fee,
                timestamp, trade_seq } ]
}
```

## balance_op.lua（余额六原语 + 幂等）

KEYS(1)：`balance:{user_id}`。
ARGV(7)：user_id、asset、amount(正整数)、action(LOCK|UNLOCK|ADD|SUB|ADD_LOCKED|SUB_LOCKED)、reason、ts(可空)、biz_id(可空)。

- 幂等：biz_id 非空时先查 `op_biz:{user}:{asset}:{action}:{biz_id}` 缓存，命中原样返回；执行后 SET 结果 EX 86400。
- 余额不足返回 `INSUFFICIENT_FUNDS` + `bucket` 字段（available/reserved）。
- 成功返回：`{ ok, user_id, asset, action, amount, available, reserved, ts, sequence, biz_id }`。

## cancel_order.lua（撤单）

KEYS(2)：`order:{order_id}`、`seq:{symbol}`（Ruby 先读 order 拿 symbol 再拼第二个 key，多一次 RTT）。
ARGV(1)：requested order_id。

- order 不存在 → `{"status":"NOT_FOUND"}`；remaining<=0 → 原样返回终态 status。
- MAINTENANCE 市场拒撤（`MARKET_MAINTENANCE`）；HALTED/CLOSED 允许撤。
- 退款：优先 order hash 里的 `reserved_base`/`reserved_quote`（balance 单位）；老数据缺字段时 SELL 回退 remaining、BUY 回退 `floor(price*remaining/quantity_scale)`。
- 账本 reason=`CANCEL_REFUND`，biz_id=`order_cancel:{seq}:{order_id}`（未成交过的追加 `:UNT`）。
- 成功返回 `{"status":"CANCELLED","order_id":...,"symbol":...,"remaining_quantity":0}`。

## force_cancel_order.lua（维护期强撤）

KEYS(1)：`order:{order_id}`。ARGV(2)：order_id、mode(DELETE_ONLY|BEST_EFFORT_UNLOCK)。
绕过市场状态检查。BEST_EFFORT_UNLOCK 尽力退还 reserved（不足退到非负为止）。

## audit_user_balance.lua（单用户对账）

KEYS(1)：`balance:{user_id}`。ARGV：user_id、fix('1'/'0')、ts、*symbols。
扫描各市场活跃订单算出应占 reserved，与实际比；fix=1 时锁差额/放盈余（reason=AUDIT_FIX_LOCK/AUDIT_FIX_RELEASE）。返回 `{ deficits:[], fixes:[] }`。

## 精度变更三件套（配合 Maintenance Ruby 编排）

- `migrate_orders_batch.lua`：KEYS = market、book/volume 的 `:TMP` 键、orders stream；ARGV = symbol、side、new_price_scale、new_quantity_scale、ts、*prices（本批价位）。把该批价位订单按新精度重写（价格/数量换算、预留额重算、差额入账 DUST_REFUND），写入 TMP book/volume。
- `finalize_precision_update.lua`：KEYS = market + 新旧 book/volume 共 8 键；ARGV = symbol、new_price_scale、new_quantity_scale。原子换名 TMP→正式、更新 market 配置。
- `update_market_precision.lua`：早期单步实现（现流程以 batch+finalize 为准，经 `Maintenance#update_market_precision` 编排）。

## 改 Lua 的检查单

1. 头注释里记录 KEYS/ARGV 契约（仓规）。
2. 数值乘法套 `would_overflow_mul`；HINCRBY 前用 `format_int`（防科学计数法与 -0）。
3. 写余额必经 op_*（match 内）或主流程（balance_op），确保 `account_ledger` 同步。
4. 订单生命周期变更同步维护：queue、volume、book ZSET、`user_orders` 索引、orders stream 事件、tombstone、ticker。
5. 深度变化发布 `depth:{symbol}`（注意 seq 字段与 MAXLEN 两处脚本不一致）。
6. 补回归 spec。
