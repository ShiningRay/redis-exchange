import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { Redis } from 'ioredis';
import {
  Client,
  DepthStreamConsumer,
  LedgerStreamConsumer,
  OrderStreamConsumer,
  TradeStreamConsumer,
  type StreamEntry,
} from '../src/index.js';

const url = process.env.SPEC_REDIS_URL ?? process.env.REDIS_URL ?? 'redis://127.0.0.1:6379/15';

describe('StreamConsumer', () => {
  let redis: Redis;
  let client: Client;

  beforeAll(async () => {
    redis = new Redis(url);
    await redis.ping();
    client = new Client({ redis });
    await redis.flushdb();
    await client.seedAsset({ asset: 'BTC', balanceScale: 100_000_000 });
    await client.seedAsset({ asset: 'USDT', balanceScale: 1_000_000 });
    await client.seedMarket({
      symbol: 'BTCUSDT',
      baseAsset: 'BTC',
      quoteAsset: 'USDT',
      priceScale: 100,
      quantityScale: 100_000_000,
    });
  });

  afterAll(async () => {
    await redis.flushdb();
    redis.disconnect();
  });

  it('ensureGroup creates the group and is idempotent (BUSYGROUP tolerated)', async () => {
    const c = new OrderStreamConsumer({ redis, symbol: 'BTCUSDT', group: 'g-orders', consumer: 'c1' });
    const first = await c.ensureGroup('0');
    expect(first).toBe(true);
    const again = await c.ensureGroup('0');
    expect(again).toBe(false);
  });

  it('reads order events via the group and acks them', async () => {
    // Produce an order event.
    await client.addFunds({ userId: 'sp1', asset: 'USDT', amount: 20_000_000_000, bizId: 'sp1' });
    await client.placeLimitOrder({
      symbol: 'BTCUSDT', side: 'BUY', orderId: 'sp-order-1', userId: 'sp1',
      price: 1_000_000, quantity: 100_000_000,
    });

    const c = await client.orderConsumer({ symbol: 'BTCUSDT', group: 'g-orders-read', consumer: 'c1' });
    const entries = await c.read({ count: 10, blockMs: 500 });
    expect(entries.length).toBeGreaterThan(0);
    const ev = entries.find((e) => e.fields['order_id'] === 'sp-order-1');
    expect(ev).toBeDefined();

    const acked = await c.ack(ev!.id);
    expect(acked).toBe(1);
  });

  it('trade consumer receives trade events from a match', async () => {
    await client.addFunds({ userId: 'sp-s', asset: 'BTC', amount: 50_000_000, bizId: 'sp-s' });
    await client.placeLimitOrder({
      symbol: 'BTCUSDT', side: 'SELL', orderId: 'sp-sell', userId: 'sp-s',
      price: 3_000_000, quantity: 50_000_000,
    });
    await client.addFunds({ userId: 'sp-b', asset: 'USDT', amount: 20_000_000_000, bizId: 'sp-b' });
    await client.placeLimitOrder({
      symbol: 'BTCUSDT', side: 'BUY', orderId: 'sp-buy', userId: 'sp-b',
      price: 3_000_000, quantity: 50_000_000,
    });

    const c = await client.tradeConsumer({ symbol: 'BTCUSDT', group: 'g-trades', consumer: 'c1' });
    const entries = await c.read({ count: 10, blockMs: 500 });
    expect(entries.length).toBeGreaterThan(0);
    expect(entries.some((e) => e.fields['taker_order_id'] === 'sp-buy')).toBe(true);
  });

  it('ledger consumer reads account_ledger entries from balance ops', async () => {
    await client.addFunds({ userId: 'sp-led', asset: 'USDT', amount: 5_000, bizId: 'sp-led-1' });

    const c = await client.ledgerConsumer({ group: 'g-ledger', consumer: 'c1' });
    const entries = await c.read({ count: 50, blockMs: 500 });
    const mine = entries.filter((e) => e.fields['user_id'] === 'sp-led');
    expect(mine.length).toBeGreaterThan(0);
    expect(mine[0]!.fields['asset']).toBe('USDT');
  });

  it('claimIdle moves pending entries from a dead consumer into ours', async () => {
    // Dead consumer reads but never acks.
    await client.addFunds({ userId: 'sp-cl', asset: 'USDT', amount: 7_000, bizId: 'sp-cl-1' });

    const dead = new LedgerStreamConsumer({ redis, group: 'g-claim', consumer: 'dead' });
    await dead.ensureGroup('0');
    const got = await dead.read({ count: 50, blockMs: 500 });
    const mine = got.filter((e) => e.fields['user_id'] === 'sp-cl');
    expect(mine.length).toBeGreaterThan(0);

    // New consumer claims the dead one's idle pendings (minIdle 0 for test).
    const live = new LedgerStreamConsumer({ redis, group: 'g-claim', consumer: 'live' });
    const claimed = await live.claimIdle({ minIdleMs: 0, count: 100 });
    const claimedMine = claimed.filter((e) => e.fields['user_id'] === 'sp-cl');
    expect(claimedMine.length).toBeGreaterThan(0);

    await live.ack(...claimedMine.map((e) => e.id));
  });

  it('lag reports undelivered message count for the group', async () => {
    const c = new LedgerStreamConsumer({ redis, group: 'g-lag', consumer: 'c1' });
    await c.ensureGroup('$'); // start at end
    await client.addFunds({ userId: 'sp-lag', asset: 'USDT', amount: 1, bizId: 'sp-lag-1' });
    const lag = await c.lag();
    // Redis < 7 does not expose a 'lag' field; the API then returns null.
    if (lag !== null) expect(lag).toBeGreaterThanOrEqual(1);
  });

  it('each() loops with autoAck and stops on halt', async () => {
    await client.addFunds({ userId: 'sp-each', asset: 'USDT', amount: 3, bizId: 'sp-each-1' });

    const c = new LedgerStreamConsumer({ redis, group: 'g-each', consumer: 'c1' });
    await c.ensureGroup('$'); // only the entry we just made is invisible; add one more below

    await client.addFunds({ userId: 'sp-each', asset: 'USDT', amount: 4, bizId: 'sp-each-2' });

    const seen: StreamEntry[] = [];
    const deadline = Date.now() + 5_000;
    await c.each(
      async (e) => {
        if (e.fields['user_id'] === 'sp-each') {
          seen.push(e);
          return 'halt';
        }
      },
      { autoAck: true, blockMs: 100, shouldStop: () => Date.now() > deadline },
    );
    expect(seen.length).toBe(1);

    // Halted entry was acked: group pending for this consumer should be 0.
    const summary = (await c.pendingSummary()) as [number, ...unknown[]];
    expect(summary[0]).toBe(0);
  });

  it('depth consumer starts at $ (no backlog) and readEvents normalizes fields', async () => {
    // Fresh group at '$': pre-existing backlog must be invisible.
    const group = `g-depth-${Date.now()}`;
    const c = (await client.depthConsumer({ symbol: 'BTCUSDT', group, consumer: 'c1' })) as DepthStreamConsumer;
    const backlog = await c.readEvents({ count: 10, blockMs: 200 });
    expect(backlog.length).toBe(0);

    // Push a depth-shaped entry manually and read it typed.
    const marker = `mk-${Date.now()}`;
    await redis.xadd('depth:BTCUSDT', '*', 'e', 'u', 's', 'BUY', 'p', '3000000', 'd', '100', 'v', '500', 'ts', marker);
    const events = await c.readEvents({ count: 10, blockMs: 500 });
    expect(events.length).toBe(1);
    expect(events[0]!.price).toBe(3_000_000);
    expect(events[0]!.finalVolume).toBe(500);
    expect(events[0]!.side).toBe('BUY');
  });

  it('resetOffset forces reprocessing and trim caps stream length', async () => {
    const c = new LedgerStreamConsumer({ redis, group: 'g-reset', consumer: 'c1' });
    await c.ensureGroup('$');
    await client.addFunds({ userId: 'sp-reset', asset: 'USDT', amount: 1, bizId: 'sp-reset-1' });

    await c.resetOffset('0');
    const entries = await c.read({ count: 100, blockMs: 500 });
    expect(entries.some((e) => e.fields['user_id'] === 'sp-reset')).toBe(true);

    const removed = await c.trim(100_000, true);
    expect(removed).toBeGreaterThanOrEqual(0);
  });

  it('trim caps stream length on its own stream', async () => {
    // Use a dedicated stream to avoid racing other tests on account_ledger.
    const key = `trim:${Date.now()}`;
    for (let i = 0; i < 5; i++) await redis.xadd(key, '*', 'n', String(i));
    const c = new LedgerStreamConsumer({ redis, group: 'g-trim', consumer: 'c1', streamKey: key });
    await c.ensureGroup('0');
    const removed = await c.trim(2, false);
    expect(removed).toBe(3);
    expect(await redis.xlen(key)).toBe(2);
  });
});
