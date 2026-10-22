import type { Redis } from 'ioredis';

export interface StreamEntry {
  stream: string;
  id: string;
  fields: Record<string, string>;
}

type XReadGroupRaw = Array<[stream: string, entries: Array<[id: string, fields: string[]]>]> | null;

function fieldsToHash(fields: unknown): Record<string, string> {
  if (fields == null) return {};
  if (Array.isArray(fields)) {
    const out: Record<string, string> = {};
    for (let i = 0; i < fields.length; i += 2) {
      out[String(fields[i])] = String(fields[i + 1]);
    }
    return out;
  }
  if (typeof fields === 'object') return fields as Record<string, string>;
  return {};
}

/**
 * Base class for Redis Streams consumer-group operations.
 * Port of RedisExchange::StreamConsumer (Ruby): ensure_group, read, ack,
 * pending inspection, idle claiming, offset reset and trimming.
 */
export class StreamConsumer {
  readonly redis: Redis;
  readonly streamKey: string;
  readonly group: string;
  readonly consumer: string;

  constructor(params: { redis: Redis; group: string; consumer: string; streamKey: string }) {
    this.redis = params.redis;
    this.group = params.group;
    this.consumer = params.consumer;
    this.streamKey = params.streamKey;
  }

  /** Ensure the consumer group exists; create starting at `startId` ('0' = backlog, '$' = end). */
  async ensureGroup(startId = '0'): Promise<boolean> {
    try {
      await this.redis.xgroup('CREATE', this.streamKey, this.group, startId, 'MKSTREAM');
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message.toLowerCase() : String(err).toLowerCase();
      if (msg.includes('busygroup') || msg.includes('exists')) return false;
      throw err;
    }
  }

  /**
   * Read a batch of entries. Returns [] on timeout.
   * @param id '>' for new entries, '0' for this consumer's pending entries
   */
  async read(params: { count?: number; blockMs?: number; id?: string } = {}): Promise<StreamEntry[]> {
    const { count = 100, blockMs = 2000, id = '>' } = params;
    const raw = (await this.redis.xreadgroup(
      'GROUP',
      this.group,
      this.consumer,
      'COUNT',
      count,
      'BLOCK',
      blockMs,
      'STREAMS',
      this.streamKey,
      id,
    )) as XReadGroupRaw;
    return this.normalizeReadResult(raw);
  }

  /**
   * Continuously read and invoke `handler` per entry.
   * Stops when the handler returns 'halt' or `shouldStop()` returns true.
   * If autoAck is true, ack after the handler resolves without throwing.
   */
  async each(
    handler: (entry: StreamEntry) => Promise<'halt' | void> | 'halt' | void,
    params: { count?: number; blockMs?: number; autoAck?: boolean; shouldStop?: () => boolean } = {},
  ): Promise<void> {
    const { count = 100, blockMs = 2000, autoAck = false, shouldStop } = params;
    for (;;) {
      if (shouldStop?.()) return;
      const entries = await this.read({ count, blockMs });
      if (entries.length === 0) continue;
      for (const e of entries) {
        try {
          const result = await handler(e);
          if (autoAck) await this.ack(e.id);
          if (result === 'halt') return;
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          // Do not ack on error; pending entries can be retried/claimed later.
          console.error(`[${this.constructor.name}] error processing ${this.streamKey} ${e.id}: ${msg}`);
        }
      }
    }
  }

  /** Acknowledge entry ids back to the consumer group. */
  async ack(...entryIds: string[]): Promise<number> {
    return this.redis.xack(this.streamKey, this.group, ...entryIds);
  }

  /** XPENDING summary (total, smallest, greatest, consumers) for monitoring. */
  async pendingSummary(): Promise<unknown> {
    return this.redis.xpending(this.streamKey, this.group);
  }

  /** Number of messages not yet delivered to the group, or null when unavailable. */
  async lag(): Promise<number | null> {
    let groups: unknown[];
    try {
      groups = (await this.redis.xinfo('GROUPS', this.streamKey)) as unknown[];
    } catch (err) {
      // Stream does not exist (yet or trimmed away) -> no lag information.
      if (err instanceof Error && /no such key/i.test(err.message)) return null;
      throw err;
    }
    for (const g of groups) {
      const h = fieldsToHash(g);
      if (h['name'] === this.group) {
        const lag = h['lag'];
        if (lag === undefined) return null;
        const n = Number(lag);
        return Number.isNaN(n) ? null : n;
      }
    }
    return null;
  }

  /** Force the consumer group to re-process messages starting after `id`. */
  async resetOffset(id = '0'): Promise<string> {
    const res = await this.redis.xgroup('SETID', this.streamKey, this.group, id);
    return String(res);
  }

  /**
   * Claim idle pending entries older than minIdleMs for this consumer.
   * Returns the claimed entries (moved into this consumer's PEL).
   */
  async claimIdle(params: { minIdleMs?: number; count?: number } = {}): Promise<StreamEntry[]> {
    const { minIdleMs = 60_000, count = 10 } = params;
    const summary = (await this.redis.xpending(this.streamKey, this.group, '-', '+', count)) as Array<
      [id: string, consumer: string, idle: number, deliveries: number]
    >;
    const ids = (summary ?? []).map((row) => row[0]).filter(Boolean);
    if (ids.length === 0) return [];

    const raw = (await this.redis.xclaim(
      this.streamKey,
      this.group,
      this.consumer,
      minIdleMs,
      ...ids,
    )) as Array<[id: string, fields: string[]]>;
    return (raw ?? []).map(([id, fields]) => ({
      stream: this.streamKey,
      id,
      fields: fieldsToHash(fields),
    }));
  }

  /** Trim the stream to a maximum length (approximate by default). */
  async trim(maxlen: number, approximate = true): Promise<number> {
    if (approximate) {
      return this.redis.xtrim(this.streamKey, 'MAXLEN', '~', maxlen);
    }
    return this.redis.xtrim(this.streamKey, 'MAXLEN', maxlen);
  }

  private normalizeReadResult(raw: XReadGroupRaw): StreamEntry[] {
    if (!raw) return [];
    const entries: StreamEntry[] = [];
    for (const [stream, pairs] of raw) {
      for (const [id, fields] of pairs ?? []) {
        entries.push({ stream, id, fields: fieldsToHash(fields) });
      }
    }
    return entries;
  }
}
