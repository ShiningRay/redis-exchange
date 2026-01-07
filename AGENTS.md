# Repository Guidelines

## Project Structure & Module Organization
- `lib/redis_exchange.rb` wires the Redis client, Lua loaders, and public API; add new helpers under `lib/redis_exchange/` to keep the entrypoint slim.
- `redis_scripts/` holds matching and cancellation Lua code; when contracts change, align specs and README examples.
- Tests sit in `spec/`, mirroring the Ruby namespaces, with shared helpers under `spec/support/`; extend `docs/architecture.md` before adding Redis keys.

## Build, Test, and Development Commands
- Install dependencies with `bundle install`; the projected Ruby version is pinned in `.ruby-version`.
- Run the suite via `bundle exec rspec`; override the Redis target with `SPEC_REDIS_URL=redis://127.0.0.1:6379/15` when needed.
- Benchmark matching throughput using `ruby script/benchmark_matching.rb --help` to discover options before load-testing changes.
- Build and install the gem locally with `gem build redis_exchange.gemspec && gem install redis_exchange-<version>.gem` for manual integration testing.

## Coding Style & Naming Conventions
- Follow idiomatic Ruby: two-space indentation, `snake_case` methods, `CamelCase` classes, and frozen string literals for new files.
- Keep Lua scripts aligned with existing spacing (two spaces inside control blocks) and record key/argv contracts in comments.
- No linter ships with the gem; run `bundle exec rubocop` locally if available and keep Redis key names aligned with `docs/architecture.md` (`balances:{user_id}:{asset}`, `trades:{symbol}`).

## Testing Guidelines
- Specs rely on a real Redis instance and flush the configured database; point `SPEC_REDIS_URL` at a disposable index before running locally.
- Place new specs beside the code they cover, using descriptive example text (`it "rejects HALTED markets" do ... end`).
- Add regression coverage for Lua changes to confirm matching, cancellations, and balance reconciliation paths.

## Commit & Pull Request Guidelines
- Follow the established history format: `<type>(<optional scope>): <summary>` (e.g., `feat: add market metadata cache` or `feat(ledger): 强化幂等性`).
- Write commits in present tense, scoped to a single concern, and include doc/test updates alongside behavioural changes.
- PRs should summarize functional impact, list Redis schema changes, and call out new environment variables or script flags.
- Link relevant issues, provide reproduction or benchmark commands, and include screenshots only when behaviour affects external consumers.

## Security & Configuration Tips
- Respect `ENV['REDIS_URL']` defaults and avoid hardcoding hosts inside specs or scripts.
- Scrub private credentials before committing `.env` changes and note environment knobs in `docs/`.
- Benchmark scripts (`BENCH_REDIS_URL`) flush the target database; call that out in reviews when sharing results.
