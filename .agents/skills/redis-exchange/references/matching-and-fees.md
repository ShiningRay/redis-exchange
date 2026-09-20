# 撮合流程、费用与精度

## 下单总流程（Ruby execute_order → match_order.lua）

Ruby 预检（快速失败，省 RTT）：系统维护 → DUPLICATE_ORDER_ID（order + tombstone EXISTS）→ side/type ArgumentError → 数值合法（INVALID_PRICE_OR_QUANTITY）→ PRECISION_OVERFLOW 预检（pl、qty、pl*qty 对 9e15）→ UNKNOWN_MARKET → 市场状态 → asset scale 兼容（ASSET_NOT_CONFIGURED / ASSET_SCALE_MISMATCH）→ 读 user taker 费率作 ARGV[9] → EVALSHA。

Lua 再全量复核一遍（幂等防御，勿只依赖 Ruby 预检）。

## 撮合主循环

1. 市价单先做流动性预检：遍历对手 book（按价格上限过滤），累计 volume；不足整单数量 → `NO_LIQUIDITY` 整单拒绝，零成交（all-or-nothing）。
2. 每轮 `INCR seq:{symbol}` 取 market_seq；`ZRANGE 对手book 0 0` 取最优价（BUY book 负 score，同取 index 0）。
3. 价格越界（买 > limit / 卖 < limit）即停；市价无上限（price_limit=0）不停。
4. `LINDEX queue 0` 取队首 maker；maker hash 缺失/remaining<=0 → LPOP 清理，继续。
5. trade_qty = min(taker remaining, maker remaining)；trade_quote = `floor(trade_price * trade_qty / quantity_scale)`（注意：除的是 quantity_scale，把 market 单位积转成 quote 缩放额）。
6. 双边扣账（见下），maker remaining 归零则 FILLED：DUST_RELEASE 释放残余预留、LPOP、清空价位（`pop_empty_price_level`）、ZREM user_orders、发 orders stream FILLED 事件、tombstone、DEL order hash；否则 PARTIALLY_FILLED + 事件。
7. 每笔成交 XADD trades stream + 记录进响应 trades[]。

## 费用数学（关键）

**收方扣费**：买方扣收到的 base，卖方扣收到的 quote。费率取各自角色的配置（taker 用 taker bps、maker 用该 maker 的 maker bps）。

market 单位估算（响应/累计用）：
```
taker_fee_base  = floor(trade_qty   * bps / 10000)
taker_fee_quote = floor(trade_quote * bps / 10000)
```
balance 单位实扣（防溢出的分段法，`compute_fee_from_balance`）：
```
q = floor(amount_balance / 10000); r = amount_balance - q*10000
fee = q*bps + floor(r*bps / 10000)
```

BUY taker × SELL maker（is_buy 分支）：
- taker：`op_sub` quote 全额 debit_balance（=trade_quote×quote_factor）；`op_add` base `trade_qty_balance - taker_fee_base_balance`
- maker：`op_sub_locked` base trade_qty_balance（释放全部锁定量）；`op_add` quote `trade_quote_balance - maker_fee_quote_balance`
- 费用入账 `fees:{asset}`：taker 费入 base asset 桶、maker 费入 quote asset 桶

SELL taker × BUY maker 镜像：taker `op_sub` base / `op_add` quote 净额；maker `op_sub_locked` quote / `op_add` base 净额。

taker 中途余额不够 → `stop_matching` 跳出（非错误，返回部分成交状态）。

## 挂单（resting，仅 LIMIT）

撮合后 remaining>0：
- BUY：预留 `floor(price_limit * remaining / quantity_scale) × quote_factor`（无费用缓冲），`op_lock` quote，reason=TAKER_RESERVE，biz_id=`order_submit:{market_seq}:{order_id}`。余额不够 → `INSUFFICIENT_FUNDS_TO_REST`。
- SELL：预留 `remaining × base_factor`，op_lock base。
- RPUSH 进 `queue:{symbol}:{side}:{price}`，ZADD book（BUY 负 score），HINCRBY volume，发深度增量。
- 写 order hash（status OPEN 或 PARTIALLY_FILLED），ZADD `user_orders:{user}:{symbol}` score=market_seq。

MARKET 单不挂单：remaining 清零，executed_quantity==0 时 status=NO_LIQUIDITY。

终态（MARKET 单、FILLED、NO_LIQUIDITY）即删 order hash + tombstone；taker 事件照发 orders stream。

## 状态机

订单：OPEN → PARTIALLY_FILLED → FILLED；限价可 → CANCELLED；市价可 → NO_LIQUIDITY。终态 hash 一律删除，只留 tombstone（24h 默认）。

## 精度守卫清单

- `PRECISION_BOUND = 9e15`；`would_overflow_mul(a,b)`：a 或 b >= 界、或积 > 界（等于放行）。
- 检查点：pl*qty（下单）、trade_price*trade_qty、各 `×factor` 换算、费用分段 q*bps、reserve_total*factor。
- `format_int`（`%.0f`）防科学计数法与 "-0" 直写 HINCRBY。
- notional = `floor(pl * qty / quantity_scale)`；LIMIT 单须 >= min_notional；所有单 qty >= min_qty。
- 换算因子：`base_factor = base_balance_scale / quantity_scale`、`quote_factor = quote_balance_scale / price_scale`，必须整除。

## 已知坑（读码得出，改动相关逻辑时自查）

1. maker balance key 在 Lua 内动态拼（`balance:{maker_user_id}`）——cluster 不兼容；cancel_order.lua 头注亦自认单实例设计。
2. 深度流与账本流的 MAXLEN 及 depth 的 seq 字段在 match/cancel 两脚本不一致（见 data-model.md）。
3. `compute_fee_from_balance` 的分段法与 `floor(x*bps/10000)` 直接法在极大数下结果可差 1（分段法更准，用于实扣；直接法用于估算上报）。两法并存是有意的，勿"统一"。
4. trades stream 的 taker_fee/maker_fee 是 balance 单位且带 *_fee_asset 字段；响应 JSON 里的 taker_fee_paid/maker_fee_charged 是 market 单位。同名不同纲，消费侧勿混。
5. cancel_order.lua 对缺 reserved_quote 的老订单有回退估算，只覆盖"很老的数据"，新逻辑勿依赖。
6. Ruby `active_orders` 防御性过滤 status/remaining——索引可能滞后于真实状态（清理只发生在终态迁移成功时）。
7. replay_ledger_audit 兼容老格式（bucket+delta）；新账目一律 action+amount。
