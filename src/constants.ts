/**
 * Constants shared with the redis_exchange Ruby gem and the Lua scripts.
 * All amounts are integer minor units; keep values < 9e15 (Lua double precision).
 */

export const SIDE_BUY = 'BUY';
export const SIDE_SELL = 'SELL';
export const SIDES = [SIDE_BUY, SIDE_SELL] as const;
export type Side = (typeof SIDES)[number];

export const ORDER_TYPE_LIMIT = 'LIMIT';
export const ORDER_TYPE_MARKET = 'MARKET';
export const ORDER_TYPES = [ORDER_TYPE_LIMIT, ORDER_TYPE_MARKET] as const;
export type OrderType = (typeof ORDER_TYPES)[number];

export const ORDER_STATUS_OPEN = 'OPEN';
export const ORDER_STATUS_PARTIALLY_FILLED = 'PARTIALLY_FILLED';
export const ORDER_STATUS_FILLED = 'FILLED';
export const ORDER_STATUS_CANCELLED = 'CANCELLED';
export const ORDER_STATUS_REJECTED = 'REJECTED';
export const ORDER_STATUS_UNKNOWN = 'UNKNOWN';
export const ORDER_STATUS_NOT_FOUND = 'NOT_FOUND';

export const MARKET_STATUS_OPEN = 'OPEN';
export const MARKET_STATUS_HALTED = 'HALTED';
export const MARKET_STATUS_CLOSED = 'CLOSED';
export const MARKET_STATUS_MAINTENANCE = 'MAINTENANCE';
export const MARKET_STATUSES = [
  MARKET_STATUS_OPEN,
  MARKET_STATUS_HALTED,
  MARKET_STATUS_CLOSED,
  MARKET_STATUS_MAINTENANCE,
] as const;
export type MarketStatus = (typeof MARKET_STATUSES)[number];

export const ASSET_STATUS_ACTIVE = 'ACTIVE';
export const ASSET_STATUS_HALTED = 'HALTED';
export const ASSET_STATUSES = [ASSET_STATUS_ACTIVE, ASSET_STATUS_HALTED] as const;
export type AssetStatus = (typeof ASSET_STATUSES)[number];

export const ACTION_ADD = 'ADD';
export const ACTION_SUB = 'SUB';
export const ACTION_LOCK = 'LOCK';
export const ACTION_UNLOCK = 'UNLOCK';
export const ACTION_ADD_LOCKED = 'ADD_LOCKED';
export const ACTION_SUB_LOCKED = 'SUB_LOCKED';
export const BALANCE_ACTIONS = [
  ACTION_ADD,
  ACTION_SUB,
  ACTION_LOCK,
  ACTION_UNLOCK,
  ACTION_ADD_LOCKED,
  ACTION_SUB_LOCKED,
] as const;
export type BalanceAction = (typeof BALANCE_ACTIONS)[number];

export const REASON_DEPOSIT = 'DEPOSIT';
export const REASON_WITHDRAWAL = 'WITHDRAWAL';
export const REASON_MANUAL = 'MANUAL';
export const REASON_MANUAL_ADJUST = 'MANUAL_ADJUST';
export const REASON_LOCK = 'LOCK';
export const REASON_UNLOCK = 'UNLOCK';

export const ERR_SYSTEM_MAINTENANCE = 'SYSTEM_MAINTENANCE';
export const ERR_MARKET_MAINTENANCE = 'MARKET_MAINTENANCE';
export const ERR_MARKET_HALTED = 'MARKET_HALTED';
export const ERR_MARKET_CLOSED = 'MARKET_CLOSED';
export const ERR_INVALID_ARGUMENTS = 'INVALID_ARGUMENTS';
export const ERR_INVALID_ORDER_TYPE = 'INVALID_ORDER_TYPE';
export const ERR_INVALID_SIDE = 'INVALID_SIDE';
export const ERR_INVALID_PRICE_OR_QUANTITY = 'INVALID_PRICE_OR_QUANTITY';
export const ERR_INVALID_AMOUNT = 'INVALID_AMOUNT';
export const ERR_INVALID_ACTION = 'INVALID_ACTION';
export const ERR_INVALID_ORDER = 'INVALID_ORDER';
export const ERR_DUPLICATE_ORDER_ID = 'DUPLICATE_ORDER_ID';
export const ERR_UNKNOWN_MARKET = 'UNKNOWN_MARKET';
export const ERR_ASSET_NOT_CONFIGURED = 'ASSET_NOT_CONFIGURED';
export const ERR_ASSET_SCALE_MISMATCH = 'ASSET_SCALE_MISMATCH';
export const ERR_MIN_QTY_NOT_SATISFIED = 'MIN_QTY_NOT_SATISFIED';
export const ERR_MIN_NOTIONAL_NOT_SATISFIED = 'MIN_NOTIONAL_NOT_SATISFIED';
export const ERR_PRECISION_OVERFLOW = 'PRECISION_OVERFLOW';
export const ERR_INSUFFICIENT_FUNDS = 'INSUFFICIENT_FUNDS';
export const ERR_INSUFFICIENT_FUNDS_TO_REST = 'INSUFFICIENT_FUNDS_TO_REST';

/** Max integer safe for Lua double precision (approx 9e15). */
export const MAX_SAFE_INTEGER = 9_000_000_000_000_000;

export const MAINTENANCE_KEY = 'system:maintenance_mode';

export const TICKER_FIELDS = [
  'last_price',
  'last_quantity',
  'last_quote',
  'last_timestamp',
  'best_bid_price',
  'best_bid_volume',
  'best_ask_price',
  'best_ask_volume',
] as const;
export type TickerField = (typeof TICKER_FIELDS)[number];
