# redis-exchange 性能基准报告

日期：2026-10-23 · 脚本：`script/benchmark_suite.rb`

## 1. 结论摘要

在本机（Intel i7-7700HQ、单进程 Redis 8.10.2、loopback、无持久化）上的实测结果：

- **挂单 ~1,000 单/秒，撮合成交 ~800 单/秒，撤单 ~2,100 单/秒**，单笔 p99 均在 2ms 以内。
- **穿 5 个价位的市价单只有 96 单/秒（p50 10.3ms）**，因为一笔要吃掉约 81 笔挂单。
- **吞吐在 2 个客户端时就基本到顶**（912 → 1,240 单/秒），8 个客户端只再涨到 1,389 单/秒，而 p50 从 1.02ms 涨到 5.11ms —— 瓶颈是单线程 Redis，不是 Ruby 客户端。
- **每笔挂单要发 40 条 Redis 命令，其中只有 1 条是 EVAL。** 撮合成交 74 条、读盘口 21.5 条。命令数量（而不是 Lua 里的撮合计算）是当前的主要成本。
- AOF `everysec` 只带来约 5% 的吞吐损失，持久化不是瓶颈。

## 2. 测试环境

| 项 | 值 |
|---|---|
| CPU | Intel Core i7-7700HQ @ 2.80GHz（8 线程，笔记本） |
| 内存 | 16 GB |
| OS | Omarchy 4.0 / Linux 7.2.8 |
| Redis | **8.10.2**（`redis:8-alpine` 容器，独立端口 6390） |
| Redis 配置 | `save ""`、`appendonly no`（AOF 对比实验除外）、`maxmemory 0`、默认 `maxclients` |
| Ruby | 3.4.10（`redis` gem 6.0.0，未启用 hiredis） |
| 网络 | 同机 loopback（不含真实网络 RTT） |
| 市场 | `TRXUSDT`，price_scale=100，quantity_scale=1e8，mid 25.00 USDT，档距 0.10 USDT |
| 规模 | 盘口 10,000 笔挂单 / 100 个价位；固定计数场景各 2,000 次操作；mixed/concurrent 各 30 秒 |

> 这是**引擎自身**的成本上限。生产环境经过 dokku 网络、跨机 RTT 与持久化会更慢。
> 绝对吞吐不宜直接当作容量指标；改动前后的趋势对比才是这个基准的主要用途。

## 3. 方法论

- **每个场景都验证订单真的进了簿**：脚本统计返回值里的错误码，结束时再回读盘口；有任何非零错误会在 stderr 打印。本次全部场景 `errors = 0`。
- **延迟给全量分布**（min/mean/p50/p90/p99/max），不是平均值。
- **同时记录服务端命令数**（`INFO stats` 的 `total_commands_processed` 差值），用来区分「客户端多跑了几趟」和「Lua 真的更慢」。
- 固定计数场景使用唯一 order_id，避免撞 tombstone 判重。
- `market_sweep` 构造确定性盘口（5 档 × 每档 20 笔），吃单量精确设为「前 N-1 档全吃完 + 第 N 档吃 1 笔」，实测每单消耗 **4.05 档**，确认真的在穿档而不是在薄盘口上打空。

## 4. 现有脚本的问题

原有 `script/benchmark_matching.rb` 只覆盖一个场景（同一价位铺单，每笔 taker 吃一笔），而且**它测不到撮合**。

实测 `--resting=50 --taker=50`：

```
[benchmark] Placement time: 0.0361s (1384.24 orders/sec)
[benchmark] Matching time: 0.0258s (1937.84 orders/sec)
```

跑完检查 Redis：

```
book:BTCUSDT:BUY  zcard = 0
book:BTCUSDT:SELL zcard = 0
order:*           数量  = 0
trades:BTCUSDT    xlen  = 0
asset:BTC          存在 = 0
```

**一笔订单都没有落库。** 原因：脚本只调了 `seed_market` 和 `set_balance`，没有 `seed_asset`，而 `execute_order` 在进入 Lua 之前就用 `ASSET_NOT_CONFIGURED` 把订单拒了。那 1,384 / 1,938 orders/sec 测的是**参数校验拒绝路径**，不是撮合。

其他局限：单客户端串行、单一价位、无撤单/余额/读盘口、只有平均值没有分位数、不统计错误数。`script/benchmark_suite.rb` 补上了这些，并把「订单是否真的落库」固化进结果的错误计数。

## 5. 单场景结果

| scenario | ops/s | p50 ms | p90 ms | p99 ms | max ms | Redis cmds/op |
|---|---:|---:|---:|---:|---:|---:|
| `book_build` | 1004.4 | 1.00 | 1.31 | 1.74 | 4.64 | 40.0 |
| `match_limit` | 805.7 | 1.26 | 1.60 | 1.97 | 3.12 | 74.0 |
| `market_sweep` | 96.3 | 10.28 | 10.95 | 12.04 | 12.12 | 3612.2 |
| `cancel` | 2104.9 | 0.47 | 0.61 | 0.71 | 1.14 | 26.1 |
| `balance_op` | 5727.4 | 0.16 | 0.23 | 0.34 | 1.24 | 10.0 |
| `reads` | 536.5 | 2.74 | 4.35 | 5.33 | 6.38 | 21.5 |

补充：

- `cancel_all`：一次批量撤 2,000 笔耗时 **856 ms**（≈0.428 ms/笔，52325 条命令）。**和逐笔撤单（0.47ms/笔）几乎一样快** —— 批量接口省的是客户端往返次数，不是 Redis 端成本。
- `market_sweep`：3612 条命令/单，约 81 笔成交 → **每笔成交约 44 条命令**。

## 6. 混合负载（更接近真实流量）

权重：挂单 55% / 撤单 20% / 交叉吃单 15% / 市价 5% / 读盘口 5%。

| 场景 | iterations/s | API ops/s | place p50 | place p99 | taker p50 | taker p99 | cancel p50 | read p50 | Redis cmds/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 单客户端 | 921.1 | 966.3 | 1.03 | 1.88 | 1.19 | 2.05 | 0.32 | 1.70 | 40451 |
| 4 客户端 | 1307.8 | 1373.4 | 2.71 | 4.23 | 2.86 | 4.42 | 0.70 | 7.14 | 57183 |

## 7. 并发扩展性

同一条混合负载，逐步增加客户端（每个客户端一条独立连接）：

| 客户端数 | iterations/s | p50 place | p99 place | p50 taker | Redis cmds/s | 相对单客户端 |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 911.7 | 1.02 | 1.91 | 1.20 | 40281 | 1.00× |
| 2 | 1239.6 | 1.47 | 2.71 | 1.63 | 54520 | 1.36× |
| 4 | 1313.5 | 2.70 | 4.22 | 2.85 | 57560 | 1.44× |
| 8 | 1388.8 | 5.11 | 7.13 | 5.12 | 61003 | 1.52× |

吞吐在 2 个客户端之后几乎不再增长，延迟线性上升 —— 单实例 Redis 的命令处理能力已经打满（约 6.1 万命令/秒）。**继续加客户端只会让 p99 变差，不会提升吞吐。**

## 8. 持久化开销

| 场景 | 无 AOF | AOF everysec | 变化 |
|---|---:|---:|---:|
| `book_build` | 1004.4/s | 947.4/s | -5.7% |
| `match_limit` | 805.7/s | 772.3/s | -4.1% |
| `cancel` | 2104.9/s | 2170.3/s | +3.1% |

`cancel` 的 +3.1% 属噪声（撤单不产生新记录）。挂单/吃单约 **4–6%** 损失，与 `everysec` 策略的预期一致。

## 9. 瓶颈分析与改进方向

按「每笔操作发出的 Redis 命令数」排序，问题很清楚：

1. **挂单 40 条命令，只有 1 条是 EVAL。** 其余是 Ruby 层前置校验：`EXISTS` 查重、`HGETALL market:*`、两个资产的 `HGETALL asset:*`、用户费率的 `HGETALL`、精度校验。其中查重 Lua 里已经做过（`EXISTS order:<id>` + tombstone），Ruby 层这一次往返可以直接去掉；市场/资产/费率是不变量，适合进程内缓存（短 TTL 或版本号失效）。
2. **读盘口 21.5 条命令。** `order_book(limit: 20)` 是 `ZRANGE` + 每档一次 `HGETALL`。改成 `ZRANGE WITHSCORES` 加 pipeline，或写一个返回整档快照的 Lua，可压到 1–2 条。
3. **撮合成交 74 条命令。** 大头是 trades/orders/depth 三个 stream 的写入与余额/挂单更新；业务必需，但可以用 pipeline 合并。
4. **单实例上限约 6 万命令/秒。** 目标吞吐超过 ~1.4k 单/秒时，需要在符号维度分片到多个 Redis 实例，而不是加大客户端并发。

## 10. 复现

```bash
# 起一个测完即弃的 Redis（无持久化）
docker run -d --name bench-redis -p 6390:6379 redis:8-alpine \
  redis-server --save '' --appendonly no

# 完整套件（约 2 分钟）
ruby script/benchmark_suite.rb \
  --redis-url=redis://127.0.0.1:6390/0 \
  --depth=10000 --batch=2000 --levels=100 \
  --sweep-levels=5 --sweep-ops=100 \
  --duration=30 --clients=4 --json=tmp/bench.json

# 并发扩展性：分别以 1 / 2 / 4 / 8 客户端各跑 20 秒
ruby script/benchmark_suite.rb --redis-url=redis://127.0.0.1:6390/0 --only=concurrent --clients=1 --duration=20
ruby script/benchmark_suite.rb --redis-url=redis://127.0.0.1:6390/0 --only=concurrent --clients=2 --duration=20
ruby script/benchmark_suite.rb --redis-url=redis://127.0.0.1:6390/0 --only=concurrent --clients=4 --duration=20
ruby script/benchmark_suite.rb --redis-url=redis://127.0.0.1:6390/0 --only=concurrent --clients=8 --duration=20
```

**注意：脚本会 `FLUSHDB` 目标库。** 只指向一次性实例。

## 11. 局限性

- 单机 loopback，不含真实网络 RTT；跨机部署每笔操作会多出一次 RTT × 命令往返数。
- 无持久化（AOF 对比实验除外）、无副本、无 `maxmemory` 压力。
- 客户端是 Ruby 且未启用 hiredis，Lua 的耗时可能被客户端开销掩盖了一部分。
- 只测了单市场；多市场共用一个 Redis 时数字会更低。
- 笔记本 CPU 有降频，绝对值波动约 ±5%；本报告数字来自同一轮连续测量，相互可比。
