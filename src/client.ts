import { randomUUID } from 'node:crypto';
import { Redis } from 'ioredis';
import {
  ACTION_ADD,
  ACTION_LOCK,
  ACTION_SUB,
  ACTION_SUB_LOCKED,
  ACTION_UNLOCK,
  ASSET_STATUS_ACTIVE,
  ASSET_STATUSES,
  ERR_INVALID_PRICE_OR_QUANTITY,
  ERR_MARKET_CLOSED,
  ERR_MARKET_HALTED,
  ERR_MARKET_MAINTENANCE,
  ERR_PRECISION_OVERFLOW,
  ERR_SYSTEM_MAINTENANCE,
  ERR_UNKNOWN_MARKET,
  MAINTENANCE_KEY,
  MARKET_STATUS_CLOSED,
  MARKET_STATUS_HALTED,
  MARKET_STATUS_MAINTENANCE,
  MARKET_STATUS_OPEN,
  MARKET_STATUSES,
  MAX_SAFE_INTEGER,
  ORDER_STATUS_CANCELLED,
  ORDER_STATUS_NOT_FOUND,
  ORDER_STATUS_UNKNOWN,
  ORDER_TYPE_LIMIT,
  ORDER_TYPE_MARKET,
  ORDER_TYPES,
  REASON_DEPOSIT,
  REASON_LOCK,
  REASON_MANUAL,
  REASON_UNLOCK,
  REASON_WITHDRAWAL,
  SIDE_BUY,
  SIDE_SELL,
  SIDES,
  TICKER_FIELDS,
  type AssetStatus,
  type BalanceAction,
  type MarketStatus,
  type OrderType,
  type Side,
} from './constants.js';
import { LuaScript, loadScriptSource } from './lua.js';

export type Numeric = number | bigint | string;

export interface LuaError {
  error: string;
  details?: string;
  asset?: string;
  balance_scale?: number;
  market_scale?: number;
}

export interface MarketConfig {
  base_asset: string | null;
  quote_asset: string | null;
  price_scale: number;
  quantity_scale: number;
  maker_fee_bps: number;
  taker_fee_bps: number;
  min_qty: number;
  min_notional: number;
  status: MarketStatus;
  trades_maxlen: number;
  orders_maxlen: number;
  order_tombstone_ttl_sec: number;
}

export interface AssetConfig {
  balance_scale: number;
  status: AssetStatus;
}

export interface OrderSnapshot {
  order_id: string;
  user_id?: string;
  symbol?: string;
  side?: string;
  type?: string;
  status?: string;
  price: number;
  quantity: number;
  remaining: number;
  created_at: number;
  sequence: number;
}

export interface BalanceView {
  available: number;
  reserved: number;
  ledger_seq?: number;
}

export interface ClientOptions {
  /** Existing ioredis connection; if omitted, one is created from redisUrl / REDIS_URL / default. */
  redis?: Redis;
  redisUrl?: string;
}

function toInt(value: Numeric): number {
  if (typeof value === 'bigint') return Number(value);
  if (typeof value === 'string') return Math.floor(Number(value));
  return Math.floor(value);
}

/**
 * TypeScript client for the Redis/Lua matching engine.
 * Mirrors RedisExchange::Client (Ruby): loads the shared redis_scripts/*.lua,
 * enforces the same pre-checks, and speaks the same KEYS/ARGV contract.
 */
export class Client {
  readonly redis: Redis;

  private readonly matchOrderScript: LuaScript;
  private readonly cancelOrderScript: LuaScript;
  private readonly balanceOpScript: LuaScript;

  constructor(options: ClientOptions = {}) {
    this.redis =
      options.redis ??
      new Redis(options.redisUrl ?? process.env.REDIS_URL ?? 'redis://127.0.0.1:6379/0');

    this.matchOrderScript = new LuaScript(loadScriptSource('match_order.lua'));
    this.cancelOrderScript = new LuaScript(loadScriptSource('cancel_order.lua'));
    this.balanceOpScript = new LuaScript(loadScriptSource('balance_op.lua'));
  }

  // ------------------------------------------------------------------
  // Orders
  // ------------------------------------------------------------------

  async placeLimitOrder(params: {
    symbol: string;
    side: Side | string;
    orderId: string;
    userId: string;
    price: Numeric;
    quantity: Numeric;
    timestampMs?: Numeric;
    autoScale?: boolean;
  }): Promise<Record<string, unknown> | LuaError> {
    const price = params.autoScale
      ? await this.scalePrice(params.symbol, params.price)
      : toInt(params.price);
    const quantity = params.autoScale
      ? await this.scaleQuantity(params.symbol, params.quantity)
      : toInt(params.quantity);

    if (price <= 0) throw new TypeError('price must be positive for limit orders');
    if (quantity <= 0) throw new TypeError('quantity must be positive for limit orders');

    return this.executeOrder({
      symbol: params.symbol,
      side: params.side,
      orderType: ORDER_TYPE_LIMIT,
      orderId: params.orderId,
      userId: params.userId,
      priceLimit: price,
      quantity,
      timestampMs: params.timestampMs,
    });
  }

  async placeMarketOrder(params: {
    symbol: string;
    side: Side | string;
    orderId: string;
    userId: string;
    quantity: Numeric;
    priceCap?: Numeric;
    timestampMs?: Numeric;
    autoScale?: boolean;
  }): Promise<Record<string, unknown> | LuaError> {
    const priceCap = params.autoScale
      ? await this.scalePrice(params.symbol, params.priceCap ?? 0)
      : toInt(params.priceCap ?? 0);
    const quantity = params.autoScale
      ? await this.scaleQuantity(params.symbol, params.quantity)
      : toInt(params.quantity);

    if (priceCap < 0) throw new TypeError('price_cap must be non-negative');

    return this.executeOrder({
      symbol: params.symbol,
      side: params.side,
      orderType: ORDER_TYPE_MARKET,
      orderId: params.orderId,
      userId: params.userId,
      priceLimit: priceCap,
      quantity,
      timestampMs: params.timestampMs,
    });
  }

  async cancelOrder(orderId: string): Promise<Record<string, unknown>> {
    if (!orderId) throw new TypeError('order_id must be provided');

    const symbol = await this.redis.hget(`order:${orderId}`, 'symbol');
    if (!symbol) {
      return { status: ORDER_STATUS_NOT_FOUND, order_id: orderId };
    }

    const raw = await this.cancelOrderScript.call(
      this.redis,
      [`order:${orderId}`, `seq:${symbol}`],
      [orderId],
    );
    return JSON.parse(raw) as Record<string, unknown>;
  }

  // ------------------------------------------------------------------
  // Market / asset metadata
  // ------------------------------------------------------------------

  async seedMarket(params: {
    symbol: string;
    baseAsset: string;
    quoteAsset: string;
    priceScale?: Numeric;
    quantityScale?: Numeric;
    makerFeeBps?: Numeric;
    takerFeeBps?: Numeric;
    minQty?: Numeric;
    minNotional?: Numeric;
    status?: MarketStatus | string;
    tradesMaxlen?: Numeric;
    ordersMaxlen?: Numeric;
  }): Promise<number> {
    const status = (params.status ?? MARKET_STATUS_OPEN).toUpperCase();
    if (!(MARKET_STATUSES as readonly string[]).includes(status)) {
      throw new TypeError('invalid market status');
    }
    const mapping: Record<string, string> = {
      base_asset: params.baseAsset,
      quote_asset: params.quoteAsset,
      price_scale: String(toInt(params.priceScale ?? 1)),
      quantity_scale: String(toInt(params.quantityScale ?? 1)),
      maker_fee_bps: String(toInt(params.makerFeeBps ?? 0)),
      taker_fee_bps: String(toInt(params.takerFeeBps ?? 0)),
      min_qty: String(toInt(params.minQty ?? 1)),
      min_notional: String(toInt(params.minNotional ?? 1)),
      status,
    };
    if (params.tradesMaxlen !== undefined) mapping['trades_maxlen'] = String(toInt(params.tradesMaxlen));
    if (params.ordersMaxlen !== undefined) mapping['orders_maxlen'] = String(toInt(params.ordersMaxlen));
    return this.redis.hset(`market:${params.symbol}`, mapping);
  }

  async marketExists(symbol: string): Promise<boolean> {
    return (await this.redis.exists(`market:${symbol}`)) > 0;
  }

  async marketConfig(symbol: string): Promise<MarketConfig | null> {
    const raw = await this.redis.hgetall(`market:${symbol}`);
    if (!raw || Object.keys(raw).length === 0) return null;
    return {
      base_asset: raw['base_asset'] ?? null,
      quote_asset: raw['quote_asset'] ?? null,
      price_scale: Number(raw['price_scale'] ?? '1'),
      quantity_scale: Number(raw['quantity_scale'] ?? '1'),
      maker_fee_bps: Number(raw['maker_fee_bps'] ?? '0'),
      taker_fee_bps: Number(raw['taker_fee_bps'] ?? '0'),
      min_qty: Number(raw['min_qty'] ?? '1'),
      min_notional: Number(raw['min_notional'] ?? '1'),
      status: (raw['status'] ?? MARKET_STATUS_OPEN) as MarketStatus,
      trades_maxlen: Number(raw['trades_maxlen'] ?? '1000000'),
      orders_maxlen: Number(raw['orders_maxlen'] ?? '1000000'),
      order_tombstone_ttl_sec: Number(raw['order_tombstone_ttl_sec'] ?? '86400'),
    };
  }

  async setMarketStatus(symbol: string, status: MarketStatus | string): Promise<MarketConfig | LuaError> {
    const key = `market:${symbol}`;
    if ((await this.redis.exists(key)) === 0) return { error: ERR_UNKNOWN_MARKET };
    const stat = status.toUpperCase();
    if (!(MARKET_STATUSES as readonly string[]).includes(stat)) {
      throw new TypeError('invalid market status');
    }
    await this.redis.hset(key, 'status', stat);
    const cfg = await this.marketConfig(symbol);
    if (!cfg) return { error: ERR_UNKNOWN_MARKET };
    return cfg;
  }

  async setMarketFees(
    symbol: string,
    makerFeeBps: Numeric,
    takerFeeBps: Numeric,
  ): Promise<{ ok: true; symbol: string; maker_fee_bps: number; taker_fee_bps: number } | LuaError> {
    const key = `market:${symbol}`;
    if ((await this.redis.exists(key)) === 0) return { error: ERR_UNKNOWN_MARKET };
    const maker = toInt(makerFeeBps);
    const taker = toInt(takerFeeBps);
    if (maker < 0 || maker > 10000) throw new TypeError('maker_fee_bps must be between 0 and 10000');
    if (taker < 0 || taker > 10000) throw new TypeError('taker_fee_bps must be between 0 and 10000');
    await this.redis.hset(key, 'maker_fee_bps', String(maker), 'taker_fee_bps', String(taker));
    return { ok: true, symbol, maker_fee_bps: maker, taker_fee_bps: taker };
  }

  async seedAsset(params: {
    asset: string;
    balanceScale: Numeric;
    status?: AssetStatus | string;
  }): Promise<number> {
    const scale = toInt(params.balanceScale);
    if (scale <= 0) throw new TypeError('balance_scale must be positive');
    const status = (params.status ?? ASSET_STATUS_ACTIVE).toUpperCase();
    if (!(ASSET_STATUSES as readonly string[]).includes(status)) {
      throw new TypeError('invalid status');
    }
    return this.redis.hset(`asset:${params.asset}`, {
      balance_scale: String(scale),
      status,
    });
  }

  async assetConfig(asset: string): Promise<AssetConfig | null> {
    const raw = await this.redis.hgetall(`asset:${asset}`);
    if (!raw || Object.keys(raw).length === 0) return null;
    return {
      balance_scale: Number(raw['balance_scale'] ?? '0'),
      status: (raw['status'] ?? ASSET_STATUS_ACTIVE) as AssetStatus,
    };
  }

  async validateAssetScalesForMarket(params: {
    baseAsset: string;
    quoteAsset: string;
    priceScale: Numeric;
    quantityScale: Numeric;
  }): Promise<{ ok: true; base_factor: number; quote_factor: number } | LuaError> {
    const baseCfg = await this.assetConfig(params.baseAsset);
    const quoteCfg = await this.assetConfig(params.quoteAsset);
    const baseBs = baseCfg ? baseCfg.balance_scale : 0;
    const quoteBs = quoteCfg ? quoteCfg.balance_scale : 0;
    if (!(baseBs > 0 && quoteBs > 0)) {
      const missing = !(baseBs > 0) ? params.baseAsset : params.quoteAsset;
      return { error: 'ASSET_NOT_CONFIGURED', asset: missing };
    }
    const ps = toInt(params.priceScale);
    const qs = toInt(params.quantityScale);
    const baseFactor = Math.floor(baseBs / qs);
    const quoteFactor = Math.floor(quoteBs / ps);
    if (baseFactor * qs !== baseBs) {
      return {
        error: 'ASSET_SCALE_MISMATCH',
        asset: params.baseAsset,
        balance_scale: baseBs,
        market_scale: qs,
      };
    }
    if (quoteFactor * ps !== quoteBs) {
      return {
        error: 'ASSET_SCALE_MISMATCH',
        asset: params.quoteAsset,
        balance_scale: quoteBs,
        market_scale: ps,
      };
    }
    return { ok: true, base_factor: baseFactor, quote_factor: quoteFactor };
  }

  // ------------------------------------------------------------------
  // Balances
  // ------------------------------------------------------------------

  async setBalance(params: {
    userId: string;
    asset: string;
    available?: Numeric;
    reserved?: Numeric;
  }): Promise<number> {
    return this.redis.hset(`balance:${params.userId}`, {
      [`${params.asset}:available`]: String(toInt(params.available ?? 0)),
      [`${params.asset}:reserved`]: String(toInt(params.reserved ?? 0)),
    });
  }

  async balance(params: {
    userId: string;
    asset: string;
    includeLedgerSeq?: boolean;
  }): Promise<BalanceView> {
    const key = `balance:${params.userId}`;
    const [available, reserved] = await this.redis.hmget(
      key,
      `${params.asset}:available`,
      `${params.asset}:reserved`,
    );
    const result: BalanceView = {
      available: Number(available ?? '0'),
      reserved: Number(reserved ?? '0'),
    };
    if (params.includeLedgerSeq) {
      const seq = await this.redis.get(`ledger_seq:${params.userId}:${params.asset}`);
      result.ledger_seq = seq ? Number(seq) : 0;
    }
    return result;
  }

  async balances(userId: string): Promise<Record<string, number>> {
    const raw = await this.redis.hgetall(`balance:${userId}`);
    const out: Record<string, number> = {};
    for (const [field, value] of Object.entries(raw)) {
      out[field] = Number(value);
    }
    return out;
  }

  async operateBalance(params: {
    userId: string;
    asset: string;
    action: BalanceAction;
    amount: Numeric;
    reason?: string;
    timestampMs?: Numeric;
    bizId?: string;
    autoScale?: boolean;
  }): Promise<Record<string, unknown>> {
    if (!params.userId) throw new TypeError('user_id is required');
    if (!params.asset) throw new TypeError('asset is required');
    if (!(Number(params.amount) > 0)) throw new TypeError('amount must be positive');

    const amount = params.autoScale
      ? await this.scaleAssetAmount(params.asset, params.amount)
      : toInt(params.amount);

    const timestamp = toInt(params.timestampMs ?? Date.now());
    const biz = params.bizId && params.bizId.length > 0 ? params.bizId : randomUUID();

    const raw = await this.balanceOpScript.call(
      this.redis,
      [`balance:${params.userId}`],
      [
        params.userId,
        params.asset,
        String(amount),
        params.action,
        params.reason ?? REASON_MANUAL,
        String(timestamp),
        biz,
      ],
    );
    return JSON.parse(raw) as Record<string, unknown>;
  }

  lockFunds(params: Omit<Parameters<Client['operateBalance']>[0], 'action'>) {
    return this.operateBalance({ ...params, action: ACTION_LOCK, reason: params.reason ?? REASON_LOCK });
  }

  unlockFunds(params: Omit<Parameters<Client['operateBalance']>[0], 'action'>) {
    return this.operateBalance({ ...params, action: ACTION_UNLOCK, reason: params.reason ?? REASON_UNLOCK });
  }

  addFunds(params: Omit<Parameters<Client['operateBalance']>[0], 'action'>) {
    return this.operateBalance({ ...params, action: ACTION_ADD, reason: params.reason ?? REASON_DEPOSIT });
  }

  subFunds(params: Omit<Parameters<Client['operateBalance']>[0], 'action'>) {
    return this.operateBalance({ ...params, action: ACTION_SUB, reason: params.reason ?? REASON_WITHDRAWAL });
  }

  subLockedFunds(params: Omit<Parameters<Client['operateBalance']>[0], 'action'>) {
    return this.operateBalance({
      ...params,
      action: ACTION_SUB_LOCKED,
      reason: params.reason ?? REASON_WITHDRAWAL,
    });
  }

  // ------------------------------------------------------------------
  // User fees
  // ------------------------------------------------------------------

  async setUserFees(params: {
    userId: string;
    makerFeeBps: Numeric;
    takerFeeBps: Numeric;
  }): Promise<number> {
    if (!params.userId) throw new TypeError('user_id is required');
    return this.redis.hset(`user_fees:${params.userId}`, {
      maker_fee_bps: String(toInt(params.makerFeeBps)),
      taker_fee_bps: String(toInt(params.takerFeeBps)),
    });
  }

  async getUserFees(userId: string): Promise<{ maker_fee_bps: number; taker_fee_bps: number } | Record<string, never>> {
    if (!userId) throw new TypeError('user_id is required');
    const raw = await this.redis.hgetall(`user_fees:${userId}`);
    if (!raw || Object.keys(raw).length === 0) return {};
    return {
      maker_fee_bps: Number(raw['maker_fee_bps'] ?? '0'),
      taker_fee_bps: Number(raw['taker_fee_bps'] ?? '0'),
    };
  }

  async deleteUserFees(userId: string): Promise<number> {
    if (!userId) throw new TypeError('user_id is required');
    return this.redis.del(`user_fees:${userId}`);
  }

  // ------------------------------------------------------------------
  // Reads
  // ------------------------------------------------------------------

  async ticker(symbol: string): Promise<Record<string, number>> {
    const raw = await this.redis.hgetall(`ticker:${symbol}`);
    if (!raw || Object.keys(raw).length === 0) return {};
    const out: Record<string, number> = {};
    for (const field of TICKER_FIELDS) {
      out[field] = Number(raw[field] ?? '0');
    }
    return out;
  }

  async order(orderId: string): Promise<OrderSnapshot | Record<string, never>> {
    const raw = await this.redis.hgetall(`order:${orderId}`);
    if (!raw || Object.keys(raw).length === 0) return {};
    return {
      order_id: raw['order_id'] ?? orderId,
      user_id: raw['user_id'],
      symbol: raw['symbol'],
      side: raw['side'],
      type: raw['type'],
      status: raw['status'],
      price: Number(raw['price'] ?? '0'),
      quantity: Number(raw['quantity'] ?? '0'),
      remaining: Number(raw['remaining'] ?? '0'),
      created_at: Number(raw['created_at'] ?? '0'),
      sequence: Number(raw['sequence'] ?? '0'),
    };
  }

  // ------------------------------------------------------------------
  // Internals (mirroring the Ruby client)
  // ------------------------------------------------------------------

  private async maintenanceEnabled(): Promise<boolean> {
    return (await this.redis.get(MAINTENANCE_KEY)) === '1';
  }

  private checkMarketStatus(mc: MarketConfig): LuaError | null {
    const st = String(mc.status).toUpperCase();
    if (st === MARKET_STATUS_OPEN) return null;
    switch (st) {
      case MARKET_STATUS_HALTED:
        return { error: ERR_MARKET_HALTED };
      case MARKET_STATUS_MAINTENANCE:
        return { error: ERR_MARKET_MAINTENANCE };
      case MARKET_STATUS_CLOSED:
        return { error: ERR_MARKET_CLOSED };
      default:
        return { error: ERR_MARKET_CLOSED };
    }
  }

  private async executeOrder(params: {
    symbol: string;
    side: Side | string;
    orderType: OrderType | string;
    orderId: string;
    userId: string;
    priceLimit: Numeric;
    quantity: Numeric;
    timestampMs?: Numeric;
  }): Promise<Record<string, unknown> | LuaError> {
    if (await this.maintenanceEnabled()) {
      return { error: ERR_SYSTEM_MAINTENANCE };
    }

    // Duplicate order check (client layer optimization), same as the Ruby client.
    if ((await this.redis.exists(`order:${params.orderId}`, `order_tombstone:${params.orderId}`)) > 0) {
      return { error: 'DUPLICATE_ORDER_ID' };
    }

    const side = params.side.toUpperCase();
    if (!(SIDES as readonly string[]).includes(side)) {
      throw new TypeError('side must be BUY or SELL');
    }
    const orderType = params.orderType.toUpperCase();
    if (!(ORDER_TYPES as readonly string[]).includes(orderType)) {
      throw new TypeError('order_type must be LIMIT or MARKET');
    }

    const pl = toInt(params.priceLimit);
    const qty = toInt(params.quantity);
    if (pl < 0 || qty <= 0) {
      return { error: ERR_INVALID_PRICE_OR_QUANTITY };
    }
    if (pl > 0) {
      if (pl >= MAX_SAFE_INTEGER || qty >= MAX_SAFE_INTEGER || pl * qty > MAX_SAFE_INTEGER) {
        return { error: ERR_PRECISION_OVERFLOW, details: `price_limit * quantity: ${pl} * ${qty}` };
      }
    }

    const mc = await this.marketConfig(params.symbol);
    if (!mc) return { error: ERR_UNKNOWN_MARKET };

    const statusCheck = this.checkMarketStatus(mc);
    if (statusCheck) return statusCheck;

    const scaleCheck = await this.validateAssetScalesForMarket({
      baseAsset: mc.base_asset as string,
      quoteAsset: mc.quote_asset as string,
      priceScale: mc.price_scale,
      quantityScale: mc.quantity_scale,
    });
    if (!('ok' in scaleCheck)) {
      const err: LuaError = { error: scaleCheck.error };
      if (scaleCheck.asset) err.asset = scaleCheck.asset;
      if (scaleCheck.balance_scale !== undefined) err.balance_scale = scaleCheck.balance_scale;
      if (scaleCheck.market_scale !== undefined) err.market_scale = scaleCheck.market_scale;
      return err;
    }

    const ts = toInt(params.timestampMs ?? Date.now());

    const userFees = await this.getUserFees(params.userId);
    const userTakerFeeBps = userFees ? String(userFees.taker_fee_bps) : '0';

    const keys = [
      `market:${params.symbol}`,
      `seq:${params.symbol}`,
      `book:${params.symbol}:${SIDE_BUY}`,
      `book:${params.symbol}:${SIDE_SELL}`,
      `volume:${params.symbol}:${SIDE_BUY}`,
      `volume:${params.symbol}:${SIDE_SELL}`,
      `balance:${params.userId}`,
      `trades:${params.symbol}`,
      `orders:${params.symbol}`,
    ];
    const argv = [
      params.symbol,
      side,
      orderType,
      params.orderId,
      params.userId,
      String(pl),
      String(qty),
      String(ts),
      userTakerFeeBps,
    ];

    const raw = await this.matchOrderScript.call(this.redis, keys, argv);
    return JSON.parse(raw) as Record<string, unknown>;
  }

  private async scalePrice(symbol: string, price: Numeric): Promise<number> {
    const cfg = await this.marketConfig(symbol);
    const scale = cfg ? cfg.price_scale : 1;
    return Math.floor(Number(price) * scale);
  }

  private async scaleQuantity(symbol: string, quantity: Numeric): Promise<number> {
    const cfg = await this.marketConfig(symbol);
    const scale = cfg ? cfg.quantity_scale : 1;
    return Math.floor(Number(quantity) * scale);
  }

  private async scaleAssetAmount(asset: string, amount: Numeric): Promise<number> {
    const cfg = await this.assetConfig(asset);
    const scale = cfg ? cfg.balance_scale : 1;
    return Math.floor(Number(amount) * scale);
  }
}

// Re-export constants for consumers.
export * from './constants.js';
export { LuaScript, loadScriptSource } from './lua.js';
