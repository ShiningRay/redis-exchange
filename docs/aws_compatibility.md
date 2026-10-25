# Running redis-exchange on AWS (ElastiCache / MemoryDB)

This document answers one question: **can redis-exchange run on AWS's managed
Redis services?** Short answer: yes, on exactly one deployment shape — ElastiCache
with **cluster mode disabled**. Every sharded shape (cluster mode enabled,
Serverless, MemoryDB) is incompatible with the current architecture.

Verified against AWS documentation on 2026-10. Key-space evidence refers to this
repository's code, so line numbers may drift over time — the sections, not the
line numbers, are the contract.

## TL;DR

| AWS offering | Deployment shape | Verdict | Reason |
| --- | --- | --- | --- |
| ElastiCache (Valkey or Redis OSS) | Cluster mode **disabled** | ✅ **Works, zero code changes** | Behaves as a single standalone Redis |
| ElastiCache (Valkey or Redis OSS) | Cluster mode enabled | ❌ Fails | `CROSSSLOT` on multi-key Lua + undeclared key access |
| ElastiCache Serverless | Always cluster mode | ❌ Fails | Same as above |
| MemoryDB | Cluster mode only | ❌ Fails | Same as above; no cluster-mode-disabled option exists |

See [docs/redis_configuration.md](redis_configuration.md) for the reasoning
behind single-instance operation in general; this page covers the AWS mapping.

## Why sharded deployments fail

The matching engine is one Lua script that must run atomically across keys that
Redis Cluster would place on different shards. Two independent blockers, either
of which is fatal:

**Blocker 1 — the declared `KEYS` already span hash slots.**
`market_keys` (`lib/redis_exchange.rb:1363`) passes `market:{symbol}`,
`seq:{symbol}`, `book:{symbol}:*`, `volume:{symbol}:*`, `trades:{symbol}`,
`orders:{symbol}` **and** `balance:{user_id}` to `EVALSHA`. The symbol-derived
keys and the user-derived key hash to different slots, so Redis Cluster rejects
the call with `CROSSSLOT Keys in request don't hash to the same slot`.

**Blocker 2 — the scripts touch keys that are not declared in `KEYS` at all.**
Cluster mode forbids Lua from accessing undeclared keys ("attempted to access a
non local key"). The scripts construct key names dynamically:

- `order_tombstone:{order_id}` — `redis_scripts/match_order.lua:231`
- `asset:{asset}` — `redis_scripts/match_order.lua:280`
- `ticker:{symbol}` — `redis_scripts/match_order.lua:471`
- `queue:{symbol}:{side}:{price}` — `redis_scripts/match_order.lua:545`
- `user_orders:{user_id}:{symbol}` — `redis_scripts/match_order.lua:804`
- `ledger_seq:{user_id}:{asset}` — `redis_scripts/match_order.lua:90`

**Why hash tags cannot fix it.** Wrapping keys in `{symbol}` tags would
co-locate a market's book, but matching walks the opposite side of the book and
settles **arbitrary makers' balances**: `redis_scripts/match_order.lua:581` and
`:635` build `'balance:' .. maker_user_id` at runtime for every maker matched.
There is no hash tag that puts the taker's balance, every potential maker's
balance, and the order book into one slot. The [AWS knowledge-center fix for
CROSSSLOT](https://repost.aws/knowledge-center/elasticache-crossslot-keys-error-redis)
is literally "turn off cluster mode, or use hash tags" — only the first option
applies here.

If you need horizontal scale, shard at the **market level**: run one
cluster-mode-disabled cluster per symbol group, exactly as
[redis_configuration.md](redis_configuration.md) recommends for self-hosted
deployments. Do not attempt to shard a single market.

## The supported shape: ElastiCache, cluster mode disabled

Everything the engine uses — `SCRIPT LOAD` + `EVALSHA` with `NOSCRIPT` retry
(`lib/redis_exchange.rb:1389`), Streams with consumer groups
(`XREADGROUP`/`XACK`/`XCLAIM`/`XINFO`/`XTRIM`), Pub/Sub, `SCAN` — is supported
on a non-cluster ElastiCache replication group, on every engine version
currently offered (Redis OSS up to 7.1, Valkey 7.2 and later; protocol
compatible, pick either).

### Configuration mapping

| Self-hosted setting (see [redis_configuration.md](redis_configuration.md)) | Where it lives on ElastiCache | Value |
| --- | --- | --- |
| `maxmemory-policy noeviction` | Parameter group | `noeviction` |
| `appendonly yes` / `appendfsync everysec` | Replication group **Data durability** setting | AOF enabled (everysec) |
| `save 900 1 …` (RDB fallback) | Automatic daily backups + retention | Enable backups |
| `notify-keyspace-events` | Parameter group | `Kz` |
| `lazyfree-lazy-eviction/expire/server-del` | Parameter group | `yes` |
| `lazyfree-lazy-user-del/user-flush` | Parameter group | `no` |
| `lua-time-limit` | Parameter group | `5000` |
| `repl-backlog-size` | Parameter group | e.g. `256mb` |
| `maxmemory` (4× steady-state) | Node type | Size up; ElastiCache reserves extra memory overhead |
| `databases` | Parameter group (default 16) | Default is fine; `SELECT n` works without cluster mode |

### The keyspace-notifications gotcha

`Client#monitor_order_book` tries to enable notifications at runtime via
`CONFIG SET notify-keyspace-events` (`lib/redis_exchange.rb:954`–`965`). On
ElastiCache the entire `CONFIG` command is restricted, so this call fails — the
code is prepared for that: it prints a warning and continues. **The warning is
easy to miss, and the subscription then succeeds silently while receiving no
events.** You must set `notify-keyspace-events = Kz` in the parameter group
yourself; there is no other way to enable it.

### Connection & failover

- Connect to the **primary endpoint** of the replication group. With in-transit
  encryption use `rediss://…:6379`; both clients (`redis` gem ≥ 5.0, `redis`
  npm package) accept that URL scheme. A non-zero DB index in the URL (e.g.
  `/15`) works — logical databases are supported outside cluster mode.
- **Sentinel does not exist on ElastiCache** (and `replicaof`/`slaveof` are
  restricted commands anyway). Use a replication group with **Multi-AZ +
  automatic failover** instead: AWS promotes a replica and moves the primary
  endpoint. Clients just reconnect.
- After a failover, `EVALSHA` may return `NOSCRIPT` because `SCRIPT LOAD` is
  not replicated; both clients already reload the script and retry
  (`lib/redis_exchange.rb:1393`–`1396`).

### Operational differences vs self-hosted

- **Restricted commands** (per [AWS restricted-commands
  documentation](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/ClientConfig.RestrictedCommands.html)):
  `bgrewriteaof`, `bgsave`, `config`, `debug`, `migrate`, `replicaof`, `save`,
  `slaveof`, `shutdown`, `sync`. Consequences: no self-scheduled
  `BGREWRITEAOF` (AWS manages AOF rewrite internally), no manual `SAVE` — use
  backups/snapshots instead. `CLIENT` is **not** restricted, so the
  `CLIENT INFO` db lookup in `monitor_order_book` works.
- Scaling is **vertical** (bigger node type) — cluster mode disabled is a
  single shard. Plan headroom per the capacity notes in
  [redis_configuration.md](redis_configuration.md), and add margin for the
  memory ElastiCache reserves on each node.
- Specs and the benchmark script **flush the target database**. Point
  `SPEC_REDIS_URL` / `BENCH_REDIS_URL` at a disposable DB index (or a
  throwaway cluster) — never at a DB holding live exchange state.

### Smoke-test checklist

1. Create a replication group: cluster mode **off**, 1 primary + 1 replica,
   Multi-AZ, AOF durability enabled, engine Valkey 7.2+ (or Redis OSS 7.1).
2. Attach a parameter group with `maxmemory-policy=noeviction` and
   `notify-keyspace-events=Kz` (plus the lazyfree values above).
3. Run the suite from a host with network access to the cluster:
   `SPEC_REDIS_URL='rediss://primary.<id>.<region>.cache.amazonaws.com:6379/15' bundle exec rspec`
   — against a **disposable** DB index.
4. If you use `monitor_order_book`, confirm events actually arrive (no
   "Failed to set notify-keyspace-events" warning and real events flowing).

## What full cluster-mode support would require

For completeness: co-locating every key a market's matching touches under one
`{symbol}` hash tag would require splitting user balances into **per-market
subaccounts** (`balance:{symbol}:{user_id}`), because maker balances are
touched by the taker's script. That redesign moves cross-market fund
consistency (deposits, withdrawals, transfers) out of Redis and into the
application layer, sacrificing the atomicity guarantees the engine is built
on. It is not supported, and given that a single primary already handles the
matching load (see [docs/benchmarks](benchmarks/)), per-market clusters are
the better scaling path.

## References

- [ElastiCache restricted commands](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/ClientConfig.RestrictedCommands.html)
- [Resolve the CROSSSLOT error in ElastiCache for Redis (AWS Knowledge Center)](https://repost.aws/knowledge-center/elasticache-crossslot-keys-error-redis)
- [ElastiCache engine-specific parameters (parameter groups)](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/ParameterGroups.Engine.html)
- [ElastiCache cluster mode disabled vs. enabled](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Replication.Redis-RedisCluster.html)
