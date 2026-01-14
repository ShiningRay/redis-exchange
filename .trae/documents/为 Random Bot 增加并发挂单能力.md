我计划更新 `script/random_bot.rb` 脚本，引入多线程并发执行随机交易的功能。

### 实现方案

1.  **修改 `script/random_bot.rb`**：
    *   **新增参数**：`--concurrency N`，指定并发线程数（默认为 1）。
    *   **逻辑调整**：
        *   将单线程的循环逻辑封装到一个 `run_worker` 方法或 Block 中。
        *   主线程根据 `--concurrency` 启动多个线程。
        *   每个线程使用自己的 Redis 连接（`RedisExchange::Client` 需要是线程安全的，或者每个线程实例化一个 Client）。由于 Ruby Redis gem 默认连接不是线程安全的，建议每个线程创建自己的 `RedisExchange::Client` 实例。
        *   **订单 ID 生成**：确保多线程下的 `order_id` 唯一（例如加上线程 ID 或使用 UUID）。
        *   **共享状态处理**：`placed_order_ids` 等共享状态需要加锁保护，或者改为每个线程独立维护自己的订单列表。
        *   **审计兼容性**：
            *   并发模式下，`--audit-interval` 的处理比较复杂（需要全局同步点）。
            *   方案：主线程负责协调。当达到 N 次操作总和时，主线程通过 `ConditionVariable` 或标志位通知所有 Worker 暂停，执行审计，然后恢复。
            *   简化版方案：并发模式下**禁用**运行时 `--audit-interval`，只保留结束后的 `--audit`。或者仅在单线程模式下支持 `--audit-interval`。
            *   *决策*：为了简化复杂度并保证审计准确性，若 `--concurrency > 1` 且开启了 `--audit-interval`，则提示暂不支持或仅在结束后审计。但为了满足用户“测试并发下的运行效果”并结合之前的审计需求，最好是支持“并发运行 -> 结束后审计”。
            *   如果用户强行要求并发下的运行时审计，需要引入 Barrier 同步机制，这会显著降低并发度，可能违背“测试并发”的初衷。因此建议：并发模式主要测试系统稳定性与最终一致性，推荐使用结束后的 `--audit`。

### 详细变更点
1.  解析 `--concurrency` 参数。
2.  重构主循环：
    *   定义 `Worker` 类或方法，接受 `id` 和 `exchange` 实例。
    *   每个 Worker 维护本地的 `placed_order_ids`。
    *   主线程等待所有 Worker 完成。
3.  并发模式下的限制：
    *   如果 `concurrency > 1`，禁用 `options[:audit_interval]` 并打印警告。
    *   保留 `options[:audit]`（结束后的审计），这是并发测试的核心验证手段。

### 验证计划
*   `ruby script/random_bot.rb --concurrency 5 --iterations 100 --audit`
*   观察 5 个线程同时输出日志。
*   运行结束后，执行余额审计，确认无误。
