# 维护、审计与运维工具

## Maintenance 模块（`exchange.maintenance`）

- `enable` / `disable` / `enabled?`：系统维护总闸（`system:maintenance_mode`）。开启后一切下单/撤单/余额操作返回 `SYSTEM_MAINTENANCE`。
- `enable_market(symbol)` / `disable_market(symbol)`：市场状态置 MAINTENANCE / 回 OPEN。
- `snapshot_order_book(symbol:, output_path:)`：市场级维护下原子快照订单簿；output_path 给文件则流式写 JSON（大簿友好），否则返回 Hash；结束恢复原状态。
- `snapshot_balances(output_path:, lock_system: true)`：系统级维护下快照全部余额；output_path 为目录时自动命名 `balances_{最后账本ID}.json`（配合 replay 审计起点）。
- `audit_user_balances(user_id:, fix:)`：逐用户跑 audit_user_balance.lua 对账；fix=true 自动补锁差额/释放盈余（AUDIT_FIX_LOCK / AUDIT_FIX_RELEASE）。
- `replay_ledger_audit(initial_balances:, start_id:, end_id:, actual_balances:)`：Ruby 侧 XRANGE 重放账本推期望余额，与实际比，出 discrepancies。initial_balances 用快照文件，start_id 用快照文件名里的 ledger ID。
- `force_cancel_order(order_id:, mode:)`：mode `:delete_only`（只删不动钱）/ `:best_effort_unlock`（尽力退预留）。
- `update_market_precision(symbol:, new_price_scale:, new_quantity_scale:, batch_size: 20, dry:)`：精度变更编排——置 MAINTENANCE → 逐批 migrate_orders_batch.lua（重算订单、DUST_REFUND 差额入账、写 TMP 簿）→ finalize_precision_update.lua（原子换名+改配置）→ 恢复状态。dry=true 只在 Ruby 侧模拟，返回 simulated_order_book / simulated_balance_adjustments。新 scale 必须仍与 asset balance_scale 整除兼容。

## Rake

`bundle exec rake audit:balances [USER_ID=...] [FIX=false]`——对账入口（`lib/tasks/audit.rake`）。

## script/ 工具清单

| 脚本 | 用途 |
|---|---|
| `random_bot.rb` | 随机压测：余额操作+限价+市价混跑，`--concurrency N --iterations N --audit [--audit-interval N] [--no-seed] [--flush]`，收尾全量审计+账本重放校验 |
| `benchmark_matching.rb` | 撮合吞吐基准；**flush 目标库**（`--redis-url` 或 BENCH_REDIS_URL） |
| `maintenance/adjust_precision.rb` | 精度调整交互脚本（配合 PRECISION_MAINTENANCE.md） |
| `rename_asset.rb` / `rename_market.rb` | 资产/市场改名（扫库改 key；`--users-file` 支持用户清单） |
| `export_snapshot.rb` / `export_rdb_data.sh` | 快照/数据导出 |
| `monitor_streams.rb` | 观察 trades/orders/depth/ledger 流 |
| `reset_consumer_offset.rb` | 重置消费组 offset（配合 `StreamConsumer#reset_offset`） |
| `trim_trades_streams.rb` | 手动裁剪 trades 流 |
| `fetch_all_orders.rb`、`orders_demo.rb`、`trades_demo.rb`、`demo_merge_depth.rb` 等 | 查询/演示样例 |

## Stream 消费者（Ruby）

工厂：`exchange.trade_consumer(symbol:, group:, consumer:)`（start '0'）、`order_consumer`（'0'）、`depth_consumer`（'$'）、`ledger_consumer(group:, consumer:, stream_key: 'account_ledger')`（'0'）。

基类 `StreamConsumer`：`read(count:, block_ms:, id: '>')`、`each(count:, block_ms:, auto_ack:)`（块返回 :halt 停；异常不 ack 留 pending）、`ack(id)`、`pending_summary`、`lag`、`claim_idle(min_idle_ms:, count:)`、`reset_offset(id:)`、`trim(maxlen:, approximate:)`。Entry = Struct(stream, id, fields)。

入库建议（docs/trade_persistence.md）：以 stream entry id 作唯一约束幂等；数值存 bigint；ts 存毫秒。trades 的 fee 字段是 balance 单位、价格数量是 market 单位，注意换算。

## Client 常用查询/管理速查

- 配置：`seed_asset` / `seed_market` / `set_market_status` / `set_market_fees` / `set_user_fees` / `get_user_fees` / `delete_user_fees` / `market_config` / `asset_config` / `validate_asset_scales_for_market`
- 余额：`operate_balance`（六动作 + biz_id 幂等）、`add_funds` / `sub_funds` / `sub_locked_funds` / `lock_funds` / `unlock_funds`、`set_balance`（直写，测试用）、`balances(user)` / `balance(user:, asset:)`（auto_scale 转浮点）
- 订单：`place_limit_order` / `place_market_order`（auto_scale: true 可传人类可读数）、`cancel_order` / `cancel_all_orders(user)`、`order(id)`、`active_orders(user:, symbol:, page:, per_page:, direction:)`、`active_order_count`、`all_orders` / `all_orders_for_market`、`market_active_orders`（贵，全簿扫）、`market_order_count`
- 行情：`ticker(symbol)`、`order_book(symbol, limit:)`、`price_level_count`、`merge_depth` / `merge_depth_both_sides`（见 docs/MERGE_DEPTH_USAGE.md）、`fees(asset:)`、`monitor_order_book`（keyspace 订阅，阻塞，另起线程）
- 测试辅助：`clear_books(symbol)`

## 发布

`script/release.rb` + gem build（gemspec 打包含 lib、redis_scripts、README、architecture.md 及四个运维脚本）。GitHub Actions：ruby.yml（CI）、gem-push.yml（发版）。
