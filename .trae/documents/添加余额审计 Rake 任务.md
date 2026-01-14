为了方便进行余额审计，我计划添加一个 Rake 任务 `audit:balances`，利用刚刚实现的 `audit_user_balances` 功能来扫描和修复用户账户。

### 计划内容

1.  **创建 `lib/tasks/audit.rake`**：
    *   定义任务 `audit:balances`。
    *   支持环境变量参数：
        *   `USER_ID`: 指定审计单个用户（可选）。
        *   `FIX`: 是否自动修复（默认 `true`，设为 `false` 则仅报告）。
        *   `REDIS_URL`: 指定 Redis 连接地址。
    *   逻辑：初始化 `RedisExchange::Client`，调用 `maintenance.audit_user_balances`，并格式化输出审计报告（包括发现的 Deficits 和执行的 Fixes）。

2.  **更新 `Rakefile`**：
    *   加载 `lib/tasks` 目录下的任务文件。

3.  **更新文档**：
    *   在 `README.md` 中添加“余额审计”章节，说明如何使用该 Rake 任务以及它的工作原理。

### 使用示例
*   全量审计并修复：`bundle exec rake audit:balances`
*   仅报告不修复：`bundle exec rake audit:balances FIX=false`
*   审计特定用户：`bundle exec rake audit:balances USER_ID=user-123`
