# Redis 数据模型（key 全量布局）

来源：`docs/architecture.md` + Lua/Ruby 实际代码。字段以代码为准（文档偶有滞后，见文末「文档漂移」）。

## 配置类

### `market:{symbol}` (HASH)
`base_asset`、`quote_asset`、`price_scale`、`quantity_scale`、`maker_fee_bps`、`taker_fee_bps`、`min_qty`、`min_notional`、`status`(OPEN|HALTED|CLOSED|MAINTENANCE)、可选 `trades_maxlen`、`orders_maxlen`、`order_tombstone_ttl_sec`（默认 86400）。

### `asset:{asset}` (HASH)
`balance_scale`（余额/账本单位）、`status`(ACTIVE|HALTED)。可选展示字段 name/display_decimals（Lua 不用）。

### `user_fees:{user_id}` (HASH)
`maker_fee_bps`、`taker_fee_bps`（0..10000）。存在即覆盖 market 默认费率（各自角色用各自费率）。

### `system:maintenance_mode` (STRING)
`'1'` = 系统级维护，所有 Lua 脚本与 Ruby 下单/撤单入口直接拒绝 `SYSTEM_MAINTENANCE`。

## 余额与账本

### `balance:{user_id}` (HASH)
字段 `{asset}:available`、`{asset}:reserved`，整数，单位为该 asset 的 `balance_scale`。

### `ledger_seq:{user_id}:{asset}` (STRING)
每用户每资产账本序号，INCR 递增，写入每条账目的 `sequence`。

### `account_ledger` (STREAM，MAXLEN ~ 1000 万)
全局账本。字段：`user_id`、`asset`、`action`(LOCK|UNLOCK|ADD|SUB|ADD_LOCKED|SUB_LOCKED)、`amount`(恒正)、`new_available`、`new_reserved`、`reason`、`ts`(ms)、`sequence`、`biz_id`。
注意 cancel_order.lua 里 MAXLEN 写的是 100 万（不一致，改时留意统一）。

### `op_biz:{user_id}:{asset}:{action}:{biz_id}` (STRING, EX 86400)
balance_op.lua 幂等缓存：同 biz_id 重放直接返回缓存响应，不重复变余额/入账。

### `fees:{asset}` (HASH)
`total`：累计收取的手续费（balance 单位），撮合时 HINCRBY。

## 订单簿

- `book:{symbol}:BUY` / `book:{symbol}:SELL` (ZSET)：member=价格串（scaled integer），score=价格；**BUY 为负 score**。两侧最优价都在 `ZRANGE 0 0`；BUY 最高价在 `ZRANGE -1 -1`。
- `queue:{symbol}:{side}:{price}` (LIST)：该价位 FIFO 订单队列，撮合 RPUSH 进、LINDEX 0 取队首、LPOP 出。
- `volume:{symbol}:{side}` (HASH)：`{price} -> 该价位挂量`（market 数量单位）。
- `seq:{symbol}` (STRING)：市场单调递增序号，用于事件 sequence 与 user_orders 索引 score。
- 精度迁移期临时键：`book:{symbol}:{side}:TMP`、`volume:{symbol}:{side}:TMP`。

## 订单

### `order:{order_id}` (HASH)
`order_id`、`user_id`、`symbol`、`side`、`type`、`price`、`quantity`、`remaining`、`reserved_base`、`reserved_quote`（balance 单位）、`executed_quote`、`trade_count`、`status`(OPEN|PARTIALLY_FILLED|FILLED|CANCELLED|NO_LIQUIDITY)、`created_at`(ms)、`sequence`。
终态即删（见 SKILL.md 规则 6）。

### `order_tombstone:{order_id}` (STRING, EX ttl)
值为终态 status（FILLED/CANCELLED/NO_LIQUIDITY…），防 ID 复用；下单预检 `EXISTS` 命中即 `DUPLICATE_ORDER_ID`。

### `user_orders:{user_id}:{symbol}` (ZSET)
用户×市场活跃订单索引，score=市场 seq。挂单 ZADD；FILLED/撤单 ZREM。Ruby `active_orders`/`cancel_all_orders` 依赖它。

## 流（Streams）

### `trades:{symbol}` (MAXLEN ~ `trades_maxlen`，默认 100 万)
成交流水。字段：`taker_order_id`、`taker_user_id`、`maker_order_id`、`maker_user_id`、`buy_order_id`、`buy_user_id`、`sell_order_id`、`sell_user_id`、`taker_side`、`price`、`quantity`、`quote`（皆 market 缩放整数）、`taker_fee`、`maker_fee`（**balance 单位**）、`taker_fee_asset`、`maker_fee_asset`、`symbol`、`ts`、`sequence`(=trade_seq)。

### `orders:{symbol}` (MAXLEN ~ `orders_maxlen`，默认 100 万)
订单生命周期事件（OPEN/PARTIALLY_FILLED/FILLED/CANCELLED/NO_LIQUIDITY）。字段：`order_id`、`user_id`、`symbol`、`side`、`type`、`status`、`price`、`quantity`、`remaining`、`executed_quote`、`trade_count`、`ts`、`sequence`。

### `depth:{symbol}` (公开深度增量流)
字段：`e`(='u')、`s`(BUY|SELL)、`p`(价位)、`d`(带符号增量)、`v`(该价位最终量)、`ts`，match_order.lua 版另有 `seq`，cancel_order.lua 版无（不一致）。
MAXLEN：match 写 10 万，cancel 写 100 万（不一致）。

### `ticker:{symbol}` (HASH)
`last_price`、`last_quantity`、`last_quote`、`last_timestamp`、`best_bid_price`、`best_bid_volume`、`best_ask_price`、`best_ask_volume`。撮合与撤单后刷新。

## 文档漂移（以代码为准）

- `docs/architecture.md` trades 字段表缺 `taker_fee_asset`/`maker_fee_asset`，写的 `trade_seq` 实际字段名是 `sequence`。
- README 账本字段表缺 `new_available`/`new_reserved`。
- architecture.md 订单 hash 字段表缺 `reserved_base`/`reserved_quote`/`executed_quote`/`trade_count`。
- 改动上述结构时应顺手更新 `docs/architecture.md`（仓规）。
