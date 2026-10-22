import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { Redis } from 'ioredis';
import { Client } from '../src/index.js';

const url = process.env.SPEC_REDIS_URL ?? process.env.REDIS_URL ?? 'redis://127.0.0.1:6379/15';

// Covers the order-path optimisations: duplicate-id detection now relies solely
// on the Lua matcher, and market/asset/user-fee config is cached per client with
// invalidation on every mutator.
describe('Client order path cache', () => {
  let redis: Redis;
  let client: Client;

  const symbol = 'CACHEUSDT';

  beforeAll(async () => {
    redis = new Redis(url);
    await redis.ping();
    client = new Client({ redis });
    await redis.flushdb();
    await client.seedAsset({ asset: 'CB', balanceScale: 100_000_000 });
    await client.seedAsset({ asset: 'USDT', balanceScale: 100_000_000 });
    await client.seedMarket({
      symbol,
      baseAsset: 'CB',
      quoteAsset: 'USDT',
      priceScale: 100,
      quantityScale: 100_000_000,
      makerFeeBps: 5,
      takerFeeBps: 10,
      minQty: 1,
      minNotional: 1,
    });
    await client.setBalance({ userId: 'u1', asset: 'CB', available: 10n ** 12n });
    await client.setBalance({ userId: 'u1', asset: 'USDT', available: 5n * 10n ** 15n });
  });

  afterAll(async () => {
    await redis.flushdb();
    redis.disconnect();
  });

  const place = (orderId: string) =>
    client.placeLimitOrder({
      symbol,
      side: 'BUY',
      orderId,
      userId: 'u1',
      price: 2_500,
      quantity: 100_000,
    });

  const commandCount = async (): Promise<number> => {
    const info = await redis.info('stats');
    const m = info.match(/total_commands_processed:(\d+)/);
    return m ? Number(m[1]) : 0;
  };

  it('rejects duplicate order ids without a client-side pre-check', async () => {
    const first = await place('ts-dup-1');
    expect(first['error']).toBeUndefined();
    const second = await place('ts-dup-1');
    expect(second['error']).toBe('DUPLICATE_ORDER_ID');
  });

  const commandsPerOrder = async (ttl: number, prefix: string): Promise<number> => {
    client.configCacheTtlMs = ttl;
    await place(`${prefix}-warmup`);
    const before = await commandCount();
    for (let i = 1; i <= 5; i++) await place(`${prefix}-${i}`);
    return ((await commandCount()) - before) / 5;
  };

  it('serves repeated orders from cache instead of re-reading configuration', async () => {
    const uncached = await commandsPerOrder(0, 'uncached');
    const cached = await commandsPerOrder(5_000, 'cached');

    // Market, both assets and the user fee table cost ~4 commands per order
    // without the cache; the Lua script's own calls are unaffected.
    expect(uncached - cached).toBeGreaterThanOrEqual(3);
  });

  it('invalidates the market cache when the status changes', async () => {
    expect((await place('ts-st-1'))['error']).toBeUndefined();

    await client.setMarketStatus(symbol, 'HALTED');

    expect((await place('ts-st-2'))['error']).toBe('MARKET_HALTED');
    await client.setMarketStatus(symbol, 'OPEN');
  });

  it('invalidates the asset cache when a balance scale changes', async () => {
    expect((await place('ts-scale-1'))['error']).toBeUndefined();

    await client.seedAsset({ asset: 'CB', balanceScale: 3 });

    expect((await place('ts-scale-2'))['error']).toBe('ASSET_SCALE_MISMATCH');
    await client.seedAsset({ asset: 'CB', balanceScale: 100_000_000 });
  });

  it('refills the cache after a fee change', async () => {
    await place('ts-fee-1');
    await client.setUserFees({ userId: 'u1', makerFeeBps: 5, takerFeeBps: 25 });

    const before = await commandCount();
    await place('ts-fee-2');
    expect((await commandCount()) - before).toBeGreaterThan(35);
  });

  it('honours a zero TTL by re-reading configuration every order', async () => {
    const uncached = await commandsPerOrder(0, 'ttl0');
    const cached = await commandsPerOrder(5_000, 'ttl5');

    expect(uncached).toBeGreaterThan(cached);
  });
});
