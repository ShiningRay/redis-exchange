import type { Redis } from 'ioredis';
import { StreamConsumer, type StreamEntry } from './stream_consumer.js';

/** Consumer-group operations for `orders:{symbol}`. */
export class OrderStreamConsumer extends StreamConsumer {
  readonly symbol: string;

  constructor(params: { redis: Redis; symbol: string; group: string; consumer: string }) {
    super({ redis: params.redis, group: params.group, consumer: params.consumer, streamKey: `orders:${params.symbol}` });
    this.symbol = params.symbol;
  }
}

/** Consumer-group operations for `trades:{symbol}`. */
export class TradeStreamConsumer extends StreamConsumer {
  readonly symbol: string;

  constructor(params: { redis: Redis; symbol: string; group: string; consumer: string }) {
    super({ redis: params.redis, group: params.group, consumer: params.consumer, streamKey: `trades:${params.symbol}` });
    this.symbol = params.symbol;
  }
}

/** Consumer-group operations for the account ledger stream (default `account_ledger`). */
export class LedgerStreamConsumer extends StreamConsumer {
  constructor(params: { redis: Redis; group: string; consumer: string; streamKey?: string }) {
    super({
      redis: params.redis,
      group: params.group,
      consumer: params.consumer,
      streamKey: params.streamKey ?? 'account_ledger',
    });
  }
}

export interface DepthEvent {
  id: string;
  symbol: string;
  eventType?: string;
  side?: string;
  price: number;
  delta: number;
  finalVolume: number;
  timestamp: number;
}

/** Consumer-group operations for `depth:{symbol}` with typed depth events. */
export class DepthStreamConsumer extends StreamConsumer {
  readonly symbol: string;

  constructor(params: { redis: Redis; symbol: string; group: string; consumer: string }) {
    super({ redis: params.redis, group: params.group, consumer: params.consumer, streamKey: `depth:${params.symbol}` });
    this.symbol = params.symbol;
  }

  async readEvents(params: { count?: number; blockMs?: number } = {}): Promise<DepthEvent[]> {
    const entries = await this.read(params);
    return entries.map((e) => this.normalizeEvent(e));
  }

  private normalizeEvent(entry: StreamEntry): DepthEvent {
    const f = entry.fields;
    return {
      id: entry.id,
      symbol: this.symbol,
      eventType: f['e'],
      side: f['s'],
      price: Number(f['p'] ?? '0'),
      delta: Number(f['d'] ?? '0'),
      finalVolume: Number(f['v'] ?? '0'),
      timestamp: Number(f['ts'] ?? '0'),
    };
  }
}
