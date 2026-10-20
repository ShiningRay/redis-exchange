import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Redis } from 'ioredis';

const here = dirname(fileURLToPath(import.meta.url));

/** Repo root: src/lua.ts -> <root>; dist/lua.js -> <root> after build (dist is one level down). */
function scriptsDir(): string {
  // When compiled, this file lives in <root>/dist/lua.js; in ts sources, <root>/src/lua.ts.
  // Both are exactly one directory below the repo root.
  return join(here, '..', 'redis_scripts');
}

/** Load a Lua script source from the shared redis_scripts directory. */
export function loadScriptSource(filename: string): string {
  const path = join(scriptsDir(), filename);
  return readFileSync(path, 'utf8');
}

/**
 * Simple Lua script wrapper using SCRIPT LOAD + EVALSHA with NOSCRIPT recovery,
 * mirroring the Ruby gem's LuaScript class.
 */
export class LuaScript {
  private readonly source: string;
  private sha: string | null = null;

  constructor(source: string) {
    if (!source) throw new Error('missing Lua source');
    this.source = source;
  }

  async call(redis: Redis, keys: string[], argv: string[]): Promise<string> {
    if (!this.sha) {
      this.sha = (await redis.script('LOAD', this.source)) as string;
    }
    try {
      return (await redis.evalsha(this.sha, keys.length, ...keys, ...argv)) as string;
    } catch (err) {
      if (err instanceof Error && /NOSCRIPT/.test(err.message)) {
        this.sha = (await redis.script('LOAD', this.source)) as string;
        return (await redis.evalsha(this.sha, keys.length, ...keys, ...argv)) as string;
      }
      throw err;
    }
  }
}
