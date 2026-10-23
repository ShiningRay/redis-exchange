---
name: redis-exchange
description: >-
  redis-exchange（Redis 单实例 + Lua 撮合引擎 + 账户流水 Ruby gem）项目开发指南。
  在本仓库改动撮合、订单、余额、账本、Lua 脚本、stream 消费、维护工具或编写 spec 时使用；
  也适用于回答撮合引擎行为、Redis key 设计、精度/费用规则、错误码、审计对账等问题。
  只要任务落在 lib/、redis_scripts/、spec/、script/、docs/ 且涉及交易或余额语义即应触发——
  即使用户只说"改个下单逻辑""查个余额对不上""加个手续费规则"。
---

# redis-exchange 项目指南

Redis 单实例上的中央限价订单簿（CLOB）+ 双桶（available/reserved）账户系统。
全部撮合与资金变动在 Lua 脚本内原子完成；Ruby `RedisExchange::Client` 是薄封装，只做预检与查询。
gem `redis_exchange` 0.2.16.x；Ruby >= 3.0（CI 验 3.2/3.4/4.0，仓内 .ruby-version 4.0.7）；redis-rb >= 5；Redis >= 6。

## 代码地图

| 路径 | 职责 |
|---|---|
| `lib/redis_exchange.rb` | Client 门面：下单/撤单/余额/查询/消费者工厂；全部常量与错误码在此定义 |
| `lib/redis_exchange/maintenance.rb` | 维护模块：余额审计、快照、强撤、精度调整、系统维护开关 |
| `lib/redis_exchange/stream_consumer.rb` | Redis Streams 消费组基类（read/ack/each/claim/trim/reset） |
| `redis_scripts/match_order.lua` | 撮合核心：限价/市价、费用、账本、深度流、ticker、挂单 |
| `redis_scripts/balance_op.lua` | 原子余额六原语 + biz_id 幂等缓存 |
| `redis_scripts/cancel_order.lua` | 原子撤单 + 退款 + ticker 刷新 |
| `redis_scripts/force_cancel_order.lua` | 维护期强撤（DELETE_ONLY / BEST_EFFORT_UNLOCK） |
| `redis_scripts/audit_user_balance.lua` | 单用户 reserved 对账（可自动修复） |
| `redis_scripts/migrate_orders_batch.lua`、`finalize_precision_update.lua`、`update_market_precision.lua` | 精度变更脚本 |
| `spec/` | RSpec，依赖真实 Redis；`spec/support/redis_exchange_setup.rb` 自动 seed BTC/USDT 市场 |
| `script/` | random_bot 压测、benchmark、rename_asset/rename_market、快照导出等运维脚本 |
| `docs/architecture.md` | Redis key 布局权威文档（新增 key 前必改） |

## 硬规则（改码前必对）

1. **三套尺度，整数存储**。asset `balance_scale`（余额/账本单位）、market `price_scale` / `quantity_scale`（撮合单位）。换算必须整除：`base_balance_scale` 是 `quantity_scale` 的整数倍、`quote_balance_scale` 是 `price_scale` 的整数倍，否则 `ASSET_SCALE_MISMATCH`。所有数值是 scaled integer，无浮点。
2. **Lua double 上界 9e15**（`PRECISION_BOUND = 9e15`，允许等于、超过才报）。任何乘积（price*quantity、amount*factor）必须套 `would_overflow_mul` 守卫再算；中间值优先"先除后乘"。违例返回 `PRECISION_OVERFLOW`。
3. **错误协议**：Lua 一律返回 JSON，业务失败形如 `{"error":"CODE"}`；Ruby 端 `JSON.parse(raw, symbolize_names: true)`。业务失败路径不抛异常；`ArgumentError` 仅限 Ruby 层参数类型错。错误码全表见 README「Error Codes」与 `lib/redis_exchange.rb` 常量区。
4. **BUY 侧 book 用负 score**（`book:{symbol}:BUY`，member=价格串，score=-price）。两侧最优价都取 `ZRANGE key 0 0`。Ruby 侧读簿方向翻转见 `fetch_sorted_book_side`。
5. **资金变动必须走账本**。余额变动只经 op_* 原语（内部 `append_ledger` 写 `account_ledger` stream，`ledger_seq:{user}:{asset}` 逐条递增，带 biz_id）。撮合脚本是业务上唯一动 reserved 的入口（balance_op 的 LOCK/UNLOCK 属运维原语）。
6. **终态订单即删**：FILLED / CANCELLED / NO_LIQUIDITY 及所有 MARKET 单，删除 `order:{id}` 并写 `order_tombstone:{id}`（TTL 默认 86400s，market 字段 `order_tombstone_ttl_sec` 可配）防 ID 复用。`user_orders:{user}:{symbol}` ZSET（score=市场 seq）是活跃订单唯一索引，Lua 在挂单时 ZADD、终态/撤单时 ZREM——改订单生命周期必须同步维护此索引。
7. **费用收方扣**（receive-side）：买方手续费扣收到的 base，卖方扣收到的 quote；BUY 挂单只预留 notional，不留费用缓冲。费率优先级 `user_fees:{user}` > market 默认；bps 范围 0..10000，taker 用 taker 费率、maker 用各自 maker 费率。
8. **新增 Redis key 先改 `docs/architecture.md`**（仓规）；Lua 改动必须补回归 spec（撮合、撤单、余额对账路径至少各一）。
9. **单实例假设**：Lua 内动态拼 key（maker 的 `balance:{maker_user}`、`user_fees:`、`fees:`、`account_ledger`、`depth:`、queue）——Redis Cluster 不兼容。勿引入 cluster 改写除非用户明示。
10. **市价单 all-or-nothing 预检**：对手盘流动性（含价格上限过滤）不足以满足全部数量时，直接整单 `NO_LIQUIDITY`，不做部分成交。改动撮合逻辑前确认是否保留此语义。
11. **幂等分两层**：balance_op.lua 用 `op_biz:{user}:{asset}:{action}:{biz_id}` 缓存响应 24h（同 biz_id 重放返回缓存，不重复入账）；match/cancel 内部账本不带该缓存，靠脚本原子性保证。外部充值/提现调用务必传 biz_id。
12. **市场状态语义**：OPEN 全放行；HALTED/CLOSED 拒新单、允许撤单；MAINTENANCE 拒一切（含撤单），供快照/精度调整等原子运维。系统级另有 `system:maintenance_mode` 总闸。

## 常用命令

```bash
bundle install
bundle exec rspec                                    # 全量（真实 Redis，默认 db15，spec 自动 flushdb + seed）
bundle exec rspec spec/redis_exchange/atomic_match_spec.rb          # 单文件
SPEC_REDIS_URL=redis://127.0.0.1:6379/15 bundle exec rspec          # 换目标库
ruby script/random_bot.rb --concurrency 5 --iterations 1000 --audit # 压测 + 收尾审计
BENCH_REDIS_URL=redis://127.0.0.1:6379/15 ruby script/benchmark_matching.rb \
  --resting=10_000 --taker=10_000 --price=3_000_000                 # 基准（会 flush 目标库）
bundle exec rake audit:balances FIX=false USER_ID=u1                # 余额对账 dry-run
gem build redis_exchange.gemspec && gem install redis_exchange-<ver>.gem
```

## 按任务读参考

| 任务 | 先读 |
|---|---|
| 撮合流程、费用数学、精度守卫、挂单/预留、状态机 | `references/matching-and-fees.md` |
| Redis key 全量布局、字段、TTL/MAXLEN | `references/data-model.md` |
| 改 Lua（KEYS/ARGV 契约、返回结构、各脚本行为） | `references/lua-contracts.md` |
| 维护/审计/快照/精度调整/改名脚本/压测工具/stream 消费 | `references/operations.md` |

## 测试规约

- spec 依赖真实 Redis（>= 6）；默认连 `SPEC_REDIS_URL || REDIS_URL || redis://127.0.0.1:6379/15`，`spec/redis_exchange/` 下自动 include setup：每例前 `flushdb` 并 seed BTC(1e8)/USDT(100) 资产与 BTCUSDT 市场（maker 5bps / taker 10bps）。
- spec 目录镜像 Ruby 命名空间；描述用祈使句（`it "rejects HALTED markets"`）。
- 关键既有 spec：`atomic_match_spec`、`partial_fill_spec`、`cancel_order_ledger_spec`、`balance_op_spec`、`account_ledger_spec`、`precision_bounds_spec`、`large_integer_precision_spec`、`user_fees_spec`、`maintenance_audit_spec`、`update_precision_spec`。
