import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { Redis } from 'ioredis';
import { Client } from '../src/index.js';

const url = process.env.SPEC_REDIS_URL ?? process.env.REDIS_URL ?? 'redis://127.0.0.1:6379/15';

describe('Client (smoke)', () => {
  let redis: Redis;
  let client: Client;

  beforeAll(async () => {
    redis = new Redis(url);
    await redis.ping();
    client = new Client({ redis });
    // Mirror the Ruby spec setup: clean market/asset/balance fixtures.
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

  it('seeds market and asset metadata', async () => {
    const mc = await client.marketConfig('BTCUSDT');
    expect(mc).not.toBeNull();
    expect(mc && mc.base_asset).toBe('BTC');
    expect(mc && mc.price_scale).toBe(100);

    const ac = await client.assetConfig('BTC');
    expect(ac && ac.balance_scale).toBe(100_000_000);
  });

  it('operates balances atomically via balance_op.lua', async () => {
    await client.addFunds({ userId: 'u1', asset: 'USDT', amount: 1_000_000, bizId: 'dep-1' });
    const bal = await client.balance({ userId: 'u1', asset: 'USDT' });
    expect(bal.available).toBe(1_000_000);

    const locked = await client.lockFunds({ userId: 'u1', asset: 'USDT', amount: 400_000, bizId: 'lock-1' });
    expect(locked).not.toHaveProperty('error');
    const bal2 = await client.balance({ userId: 'u1', asset: 'USDT' });
    expect(bal2.available).toBe(600_000);
    expect(bal2.reserved).toBe(400_000);
  });

  it('is idempotent on repeated biz_id', async () => {
    const first = (await client.addFunds({ userId: 'u2', asset: 'USDT', amount: 100, bizId: 'dup-1' })) as Record<string, unknown>;
    expect(first).not.toHaveProperty('error');
    // balance_op.lua returns the cached original response for a repeated biz_id.
    const second = (await client.addFunds({ userId: 'u2', asset: 'USDT', amount: 100, bizId: 'dup-1' })) as Record<string, unknown>;
    expect(second).not.toHaveProperty('error');
    expect(second['sequence']).toBe(first['sequence']);
    const bal = await client.balance({ userId: 'u2', asset: 'USDT' });
    expect(bal.available).toBe(100);
  });

  it('matches a limit order against a resting order', async () => {
    // Seller posts 0.5 BTC at 30_000.00 USDT.
    await client.addFunds({ userId: 'seller', asset: 'BTC', amount: 50_000_000, bizId: 's-1' });
    const sell = (await client.placeLimitOrder({
      symbol: 'BTCUSDT',
      side: 'SELL',
      orderId: 'sell-1',
      userId: 'seller',
      price: 30_000 * 100, // price_scale 100
      quantity: 50_000_000, // 0.5 BTC in base minor units
    })) as Record<string, unknown>;
    expect(sell).not.toHaveProperty('error');
    expect(sell['status']).toBe('OPEN');

    // Buyer takes it fully.
    await client.addFunds({ userId: 'buyer', asset: 'USDT', amount: 20_000_000_000, bizId: 'b-1' });
    const buy = (await client.placeLimitOrder({
      symbol: 'BTCUSDT',
      side: 'BUY',
      orderId: 'buy-1',
      userId: 'buyer',
      price: 30_000 * 100,
      quantity: 50_000_000,
    })) as Record<string, unknown>;
    expect(buy).not.toHaveProperty('error');
    expect(['FILLED', 'PARTIALLY_FILLED']).toContain(buy['status']);

    const ticker = await client.ticker('BTCUSDT');
    expect(ticker['last_price']).toBe(30_000 * 100);

    const sellerBtc = await client.balance({ userId: 'seller', asset: 'BTC' });
    expect(sellerBtc.reserved + sellerBtc.available).toBe(0);
  });

  it('rejects duplicate order ids', async () => {
    await client.addFunds({ userId: 'u3', asset: 'USDT', amount: 200_000_000_000, bizId: 'u3-1' });
    const args = {
      symbol: 'BTCUSDT',
      side: 'BUY' as const,
      orderId: 'dup-order',
      userId: 'u3',
      price: 100_000,
      quantity: 100_000_000,
    };
    const first = (await client.placeLimitOrder(args)) as Record<string, unknown>;
    expect(first).not.toHaveProperty('error');
    const second = (await client.placeLimitOrder(args)) as Record<string, unknown>;
    expect(second).toHaveProperty('error', 'DUPLICATE_ORDER_ID');
  });

  it('rejects unknown markets and halted markets', async () => {
    const unknown = (await client.placeLimitOrder({
      symbol: 'NOPE',
      side: 'BUY',
      orderId: 'x-1',
      userId: 'u3',
      price: 1,
      quantity: 1,
    })) as Record<string, unknown>;
    expect(unknown).toHaveProperty('error', 'UNKNOWN_MARKET');

    await client.setMarketStatus('BTCUSDT', 'HALTED');
    const halted = (await client.placeLimitOrder({
      symbol: 'BTCUSDT',
      side: 'BUY',
      orderId: 'x-2',
      userId: 'u3',
      price: 1,
      quantity: 1,
    })) as Record<string, unknown>;
    expect(halted).toHaveProperty('error', 'MARKET_HALTED');
    await client.setMarketStatus('BTCUSDT', 'OPEN');
  });

  it('cancels a resting order and releases reserved funds', async () => {
    await client.addFunds({ userId: 'u4', asset: 'USDT', amount: 200_000_000_000, bizId: 'u4-1' });
    const placed = (await client.placeLimitOrder({
      symbol: 'BTCUSDT',
      side: 'BUY',
      orderId: 'cancel-me',
      userId: 'u4',
      price: 100_000,
      quantity: 100_000_000,
    })) as Record<string, unknown>;
    expect(placed).not.toHaveProperty('error');

    const before = await client.balance({ userId: 'u4', asset: 'USDT' });
    expect(before.reserved).toBeGreaterThan(0);

    const res = await client.cancelOrder('cancel-me');
    expect(res['status']).toBe('CANCELLED');

    const after = await client.balance({ userId: 'u4', asset: 'USDT' });
    expect(after.reserved).toBe(0);
  });
});
