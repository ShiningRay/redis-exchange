# Redis Configuration for redis-exchange

This document describes the recommended Redis server configuration for running
redis-exchange in production. The engine stores **all exchange state** (order
books, balances, ledger, ticker) in Redis, so durability and eviction policy
choices directly affect fund safety.

A ready-to-adapt template lives at [`config/redis.conf.example`](../config/redis.conf.example).

## TL;DR

| Setting | Recommended | Why |
| --- | --- | --- |
| `maxmemory-policy` | **`noeviction`** | Volatile-* and allkeys-* policies can silently delete idempotency keys or core ledger keys. |
| `appendonly` | `yes` | Lua matching mutates many keys atomically; only AOF preserves the write order needed for point-in-time recovery. |
| `appendfsync` | `everysec` | Balances durability vs. fsync latency; at most ~1s of acknowledged writes lost on kernel crash. |
| `lazyfree-lazy-expire` | `yes` | Amortises the burst when many `order_tombstone:*` / `op_biz:*` keys expire at once. |
| `lua-time-limit` | `5000` | `match_order.lua` is ~1000 lines; give headroom above the 5s default if the book is deep. |
| Cluster / sharding | **disabled** | Matching is single-instance Lua across many keys; Cluster would break atomicity. |

## Why `noeviction` is mandatory

The codebase writes two very different kinds of keys:

1. **Core exchange state — no TTL**:
   `balance:{user_id}`, `market:*`, `asset:*`, `book:*`, `queue:*`,
   `volume:*`, `order:{id}` (open orders), `ticker:*`, `ledger_seq:*`, `seq:*`.
   These are the ledger and order book. Losing any of them to eviction means
   double-spends, stuck orders, or missing funds.

2. **Idempotency keys — TTL 86400s**:
   - `order_tombstone:{order_id}` — prevents a finished order ID from being
     reused within 24h (checked at `redis_scripts/match_order.lua:232`).
   - `op_biz:{user}:{asset}:{action}:{biz_id}` — caches the result of
     `balance_op.lua` so that a retried `LOCK`/`SUB`/… with the same `biz_id`
     returns the original response instead of re-executing
     (`redis_scripts/balance_op.lua:47` and `:145`).

All `volatile-*` policies only consider keys **with TTL set**. In this
codebase that means they can only ever evict the two idempotency families
above — they cannot touch the memory hogs (order book, queues, streams),
which have no TTL. Consequences under memory pressure:

- **Idempotency is silently broken before its promised 24h**:
  - A retry of a just-placed order re-executes because `order_tombstone` was
    evicted → **double charge**.
  - A retry of a recent `LOCK` re-executes because `op_biz` was evicted →
    **double lock**.
- Memory still grows into `maxmemory` (the big keys cannot be evicted), so
  the instance OOMs anyway — you pay the correctness cost *and* the
  availability cost.
- `volatile-ttl` is even worse than `volatile-lru`: it preferentially evicts
  keys with the shortest remaining TTL, which is exactly the "freshest"
  idempotency keys most likely to be retried.
- `allkeys-lru` will directly evict `balance:*` / `order:*` — an
  unambiguous fund-loss incident.

`noeviction` makes the failure mode explicit: writes start failing with
`OOM command not allowed`, which is loud, alertable, and does not corrupt
state. Capacity is managed by monitoring and scaling, not by silent
eviction.

Streams already self-trim (`MAXLEN ~`):

| Stream | Cap | Source |
| --- | --- | --- |
| `account_ledger` | ~10,000,000 | `redis_scripts/match_order.lua:95`, `redis_scripts/balance_op.lua:116` |
| `trades:{symbol}` | ~1,000,000 (`market.trades_maxlen`) | `redis_scripts/match_order.lua:862` |
| `orders:{symbol}` | ~1,000,000 (`market.orders_maxlen`) | `redis_scripts/match_order.lua:807`, `:827` |
| `depth:{symbol}` | ~100,000 | `redis_scripts/match_order.lua:157` |

## Idempotency TTL configuration

TTLs in this codebase are *business logic*, not a memory-management knob.
If you want shorter idempotency windows, change the TTL — do not switch
eviction policies.

| Key family | Default | Configurable? | How |
| --- | --- | --- | --- |
| `order_tombstone:*` (matching paths) | 86400s | ✅ per market | `HSET market:{symbol} order_tombstone_ttl_sec <seconds>`; read by `match_order.lua:250`, `cancel_order.lua:154`, `force_cancel_order.lua:210-216` |
| `order_tombstone:*` (precision maintenance scripts) | 86400s | ❌ hardcoded | `redis_scripts/migrate_orders_batch.lua:196`, `redis_scripts/update_market_precision.lua:234` — change in Lua if needed |
| `op_biz:*` | 86400s | ❌ hardcoded | `redis_scripts/balance_op.lua:145` — change in Lua; consider mirroring the market-field style by reading from `asset:{asset}` |

## `lazyfree-lazy-*` knobs

Redis frees memory on the main thread by default; large `DEL`s, mass
expirations, or eviction bursts can stall matching. The `lazyfree-lazy-*`
family moves *memory reclamation* to a background thread — it does **not**
change *what* gets deleted, only *how blocking* the deletion is. That makes
it orthogonal to `maxmemory-policy`.

| Knob | Recommended | Rationale |
| --- | --- | --- |
| `lazyfree-lazy-eviction` | `yes` | Defensive — if the policy is ever changed, eviction frees don't stall matching. |
| `lazyfree-lazy-expire` | `yes` | Smooths the burst when many same-TTL idempotency keys (order tombstones, op_biz) expire together after a busy day. |
| `lazyfree-lazy-server-del` | `yes` | Internal implicit `DEL`s (e.g. on overwrite) go async. |
| `lazyfree-lazy-user-del` | `no` | Keep `DEL` semantics explicit; clients deleting large keys should call `UNLINK` themselves. |
| `lazyfree-lazy-user-flush` | `no` | Keep `FLUSHDB`/`FLUSHALL` synchronous so misuse is obvious. |

In this codebase most objects are small (balances hash with a handful of
asset fields, book/volume per price level, fixed-size order hashes), so the
win from lazyfree is smaller than in cache-style workloads — but the
expire/sever-side variants are still worth enabling to avoid rare pause
spikes.

## Persistence

- `appendonly yes` + `appendfsync everysec`: the unit of atomicity is a Lua
  script that writes many keys; only AOF preserves write order faithfully
  enough for point-in-time recovery. `everysec` trades at most ~1s of
  acknowledged writes against a kernel crash for dramatically better fsync
  throughput than `always`.
- `aof-use-rdb-preamble yes`: faster restarts; the AOF begins with an RDB
  snapshot.
- `save 900 1 / 300 10 / 60 10000`: RDB as a *fallback* in case the AOF is
  corrupted. Never rely on RDB alone for a matching engine.
- `stop-writes-on-bgsave-error yes`: fail loudly if disk is full / fork
  fails, instead of silently losing persistence.

## Single instance, no Cluster

`match_order.lua` runs atomically across dozens of keys spanning
`book:{symbol}:*`, `queue:*`, `volume:*`, `order:{id}`, `balance:{user_id}`,
`market:*`, `asset:*`, `ticker:*`, `ledger_seq:*`, `seq:*`, and four
streams. Redis Cluster hashes keys to slots and forbids cross-slot Lua —
this script simply cannot run. Run a **single primary**, with **one or more
replicas + Sentinel** for failover. Do not attempt to shard the matching
engine.

If horizontal scale is ever needed, shard at the *market* level by running
separate Redis instances per symbol group (one engine process per
instance), not via Redis Cluster.

Running on AWS? The managed-service mapping of these recommendations
(ElastiCache parameter groups, restricted commands, failover without
Sentinel) is covered in [aws_compatibility.md](aws_compatibility.md) —
the same rule applies: only ElastiCache with cluster mode disabled works.

## Replication & failover

- One primary, ≥1 replica, Sentinel (or equivalent) for automatic failover.
- `repl-backlog-size 256mb` lets replicas resync incrementally over short
  network blips without a full resync.
- On failover, clients must re-run `SCRIPT LOAD` / handle `NOSCRIPT` — the
  Ruby and TypeScript clients already do this.

## Observability

Minimum alerts:

- `used_memory / maxmemory > 0.7` → page; capacity action required.
- `aof_last_write_status != ok` → page; persistence is broken.
- `rdb_last_bgsave_status != ok` → warn.
- `mem_fragmentation_ratio > 1.5` → investigate (likely needs a restart or
  `activedefrag`).
- Stream lag: `XINFO GROUPS trades:{symbol}` / `account_ledger` lag per
  consumer group growing over time → consumer is stuck.
- `XPENDING` on any consumer group > 0 for longer than a few minutes →
  consumer crashed mid-batch.

## Capacity planning

- Size `maxmemory` to ~4× steady-state usage. The order book (`queue:*` +
  `order:*`) grows with open-order count; peaks around volatile market
  events can be 3–5× baseline.
- Streams are self-capped by `MAXLEN ~`; budget roughly:
  - `account_ledger`: 10M entries × ~200B ≈ 2 GB worst case.
  - `trades:{symbol}` + `orders:{symbol}`: 1M × ~300B ≈ 300 MB per symbol each.
  - `depth:{symbol}`: 100k × ~100B ≈ 10 MB per symbol.
- Leave headroom for replication backlog, AOF rewrite buffers, and fork
  copy-on-write (Redis `fork()` during `BGSAVE`/`BGREWRITEAOF` can
  transiently double RSS under write load — see `vm.overcommit_memory=1`).

## Reference template

See [`config/redis.conf.example`](../config/redis.conf.example) for a
drop-in starting point matching the recommendations above.
