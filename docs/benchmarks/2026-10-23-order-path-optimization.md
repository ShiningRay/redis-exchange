# 订单路径优化：去掉冗余往返、缓存配置、批量读盘口

日期：2026-10-23 · 基线报告：[`2026-10-23-benchmark-suite.md`](2026-10-23-benchmark-suite.md)

## 1. 结论摘要

| 场景 | before | after | 变化 | 命令/笔 | p50 |
|---|---:|---:|---:|---:|---:|
| `book_build` | 943.4/s | 1,706.7/s | **+80.9%** | 40.00 → 35.00 | 1.04 → 0.57 ms |
| `match_limit` | 764.3/s | 1,287.8/s | **+68.5%** | 74.03 → 69.03 | 1.30 → 0.76 ms |
| `reads` | 482.9/s | 1,933.8/s | **+300.5%** | 21.50 → 2.50 | 2.79 → 0.49 ms |
| `mixed`（加权混合） | 854.5/s | 1,646.8/s | **+92.7%** | 42.06 → 36.36 | — |

混合负载按键细分（p50 / p99，ms）：

| 操作 | p50 before | p50 after | p99 before | p99 after |
|---|---:|---:|---:|---:|
| `place` | 1.12 | **0.56** | 1.85 | **0.96** |
| `taker` | 1.30 | **0.74** | 1.99 | **1.26** |
| `cancel` | 0.38 | 0.42 | 0.70 | 0.75 |
| `read` | 1.86 | **0.57** | 5.73 | **1.64** |

所有场景 `errors = 0`。`cancel` 基本没变（它的路径本来就只有一次 HGET + 一次 EVAL，没有可省的）。

## 2. 先更正基线报告里的一个归因错误

基线报告写「挂单 40 条命令，只有 1 条是 EVAL，其余是 Ruby 层前置校验」。**这个拆分是错的。**

用 `MONITOR` 抓一笔挂单的真实命令序列后可以看清：

```
客户端发出（7 条）：HELLO / CLIENT SETINFO x4 / GET system:maintenance_mode /
                    EXISTS order:mon-2 order_tombstone:mon-2 /
                    HGETALL market:TRXUSDT / HGETALL asset:TRX / HGETALL asset:USDT /
                    HGETALL user_fees:maker / EVALSHA ...
Lua 内部（32 条）：HGET x9, ZRANGE x3, XADD x3, INCR x3, HINCRBY x3,
                  HGETALL x3, ZADD x2, HSET x2, RPUSH, HMSET, GET, EXISTS
```

`total_commands_processed` **把 Lua 内部的 `redis.call` 也计入**，所以 40 ≈ 6 条业务命令 + 1 条 EVAL + 32 条脚本内部调用。

含义很重要：**item 3（撮合 74 条命令）不是客户端能 pipeline 掉的问题** —— 那 68 条都在 Lua 内部，服务端本来就是一个原子调用。真正的收益只能来自 item 1（客户端往返）和 item 2（读盘口）。下面的数字也印证了这一点：`match_limit` 从 74.03 只降到 69.03，正好是省掉的 5 条客户端命令。

## 3. 改了什么

### 3.1 去掉重复的订单号查重（Ruby + TypeScript）

`match_order.lua` 开头已经做了完整判重（tombstone + order hash 状态/剩余量，返回 `DUPLICATE_ORDER_ID`）。客户端层的 `EXISTS` 每次下单白付一个往返，已删除。错误码与行为不变，由 [`spec/order_path_cache_spec.rb`](../../spec/order_path_cache_spec.rb) 与 [`spec-js/order_path_cache.spec.ts`](../../spec-js/order_path_cache.spec.ts) 覆盖。

### 3.2 配置缓存（Ruby + TypeScript）

市场、两个资产、用户费率这四张 hash 只有管理端写入才会变，但过去**每笔订单都重读**。现在：

| 路径 | 改动前 | 改动后 |
|---|---|---|
| 缓存命中 | 每单 4 次 HGETALL | 0 |
| 缓存未命中 | 4 次串行 HGETALL | 1 次 HGETALL（市场）+ 1 次 pipelined（两个资产 + 费率） |

- 默认 TTL 5 秒：Ruby `RedisExchange::DEFAULT_CONFIG_CACHE_TTL`、`Client#config_cache_ttl=`；TS `Client#configCacheTtlMs`。
- **设成 0 表示完全禁用**（既不写也不读缓存），用于排障或多实例强一致场景。
- 所有会改这些 hash 的方法都会立即失效缓存：`seed_market` / `set_market_status` / `set_market_fees` / `seed_asset` / `set_user_fees` / `delete_user_fees`（TS 同名对应）。
- 也暴露了 `clear_config_cache!` / `clearConfigCache()`，供绕过本客户端直接改 Redis 的场景手动清理。
- **未命中未知市场不入缓存**，新建市场立刻可见；市场状态仍每次由 Lua 读，所以 HALTED 是即时生效的，不受 TTL 影响。

### 3.3 读盘口改批量取量（仅 Ruby）

`order_book(limit: 20)` 原来是 `ZRANGE` + **每个价位一次 `HGET`**，20 档就是 20 个往返（买卖两侧共 40+）。改为一次 `HMGET volume:{symbol}:{side} <p1> <p2> ...`：

| | before | after |
|---|---|---|
| 命令/次（买卖各 20 档） | 42 | 4 |
| 端到端往返（loopback） | 42 | 2 |
| p50 | 2.79 ms | 0.49 ms |

> TypeScript 客户端目前没有 `order_book` 方法，所以这一项只落在 Ruby 侧。如果要把读盘口补进 TS 客户端，应该直接用批量版本实现。

### 3.4 TypeScript 侧的实测

用同一份构建做 A/B（`configCacheTtlMs` 0 vs 5000，同一 Redis、同一数据）：

```
uncached (TTL=0):        38.10 commands/order
cached   (TTL=5000):     34.05 commands/order
saved per order:          4.05 commands
first order after setUserFees: 39 commands   ← 缓存被失效，重新回填
```

## 4. 正确性

| 检查 | Ruby | TypeScript |
|---|---|---|
| 重复订单号仍返回 `DUPLICATE_ORDER_ID` | ✅ | ✅ |
| `set_market_status(HALTED)` 后立即拒单 | ✅ | ✅ |
| `seed_asset` 改尺度后立即 `ASSET_SCALE_MISMATCH` | ✅ | ✅ |
| `set_user_fees` 后重新读费率 | ✅ | ✅ |
| TTL=0 时每单都重读 | ✅ | ✅ |
| 全部测试 | 189 examples / 10 failures（与改动前完全相同的 10 个既有失败） | 23 tests / 0 failures |

那 10 个失败（`export_rdb_data`、`rename_asset`、`rename_market`）在**未改动的 main 上同样失败**，与本改动无关。

## 5. 复现

```bash
docker run -d --name bench-redis -p 6390:6379 redis:8-alpine \
  redis-server --save '' --appendonly no

# 优化后
ruby script/benchmark_suite.rb --redis-url=redis://127.0.0.1:6390/0 \
  --depth=10000 --batch=2000 --levels=100 \
  --duration=20 --clients=1 --only=book_build,match_limit,reads,mixed

# 对比（在 main 上同样跑一遍即可）
git stash && ruby script/benchmark_suite.rb ... ; git stash pop
```

命令行数用 `MONITOR` 或 `INFO stats` 的 `total_commands_processed` 差值核对，注意后者包含 Lua 内部调用。

## 6. 还能再往下的地方

按收益排序：

1. **Lua 内部 32 条命令里，`HGETALL market:*` 和两张 `HGETALL asset:*` 是客户端刚读过的**。把配置通过 ARGV 传进脚本可以再省 3 条，但市场状态必须保持实时读取（HALTED 要立刻生效），因此只能传资产尺度、费率这类真正不可变的部分。
2. **`cancel` 每次一次 `HGET order:* symbol` 再 EVAL**，符号可以用 `{symbol}` hash tag 从客户端传入，省一个往返。
3. **撮合的 68 条 Lua 内部调用**：trades / orders / depth 三个 stream 的 `XADD` 是必需的，但 `MAXLEN ~` 的近似裁剪在大流量下会带来额外工作，可以改成分片裁剪或异步回收。
4. **读盘口的 4 条命令**还可以合成一个 Lua 快照脚本（1 次 EVAL + 2 条内部调用），但要权衡脚本缓存与可维护性。

## 7. 局限

- 数字来自单机 loopback、无持久化；真实跨机部署里客户端往返更贵，所以**减少往返的收益会比这里更大**，而减少 Lua 内部命令的收益占比会更小。
- 缓存引入最多 5 秒的配置陈旧窗口。市场状态不受影响（每次由 Lua 判定），但**资产尺度和用户费率**在多实例部署下最多滞后 TTL。需要强一致时把 TTL 设为 0 或改用 `clear_config_cache!`。
