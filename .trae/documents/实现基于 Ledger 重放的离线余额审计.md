我将更新计划，不仅实现 Ledger 重放审计功能，还将该流程集成到 `random_bot` 中进行定时自动化测试。

### 更新后的实现方案

1.  **新增 Ruby 方法**：`RedisExchange::Maintenance#replay_ledger_audit`
    *   **参数**：
        *   `initial_balances`: 初始余额快照（Hash 格式，`{ user_id => { asset => { bucket => amount } } }`）。
        *   `start_id`: 初始快照对应的 Ledger ID（重放起始点）。
    *   **流程**：
        1.  **深拷贝**：基于 `initial_balances` 创建本地计算副本。
        2.  **获取 Ledger 范围**：获取当前 Redis 中 `account_ledger` 的最新 ID (`end_id`)。
        3.  **重放 Ledger**：
            *   使用 `XRANGE` 从 `(start_id` 到 `end_id` 批量拉取日志。
            *   按日志顺序在本地副本上应用 `delta` 变更。
        4.  **比对现状**：
            *   获取 Redis 中受影响用户在 `end_id` 时刻的实际余额。*注意：在高并发下，直接读取 Redis 可能读到 `end_id` 之后的变更。为了准确测试，random_bot 是单线程同步执行的，我们可以在验证阶段暂停交易，或者在 audit 内部只比对那些 **没有新变更** 的用户，或者在 bot 中控制节奏。*
            *   **改进策略**：由于 `random_bot` 是单进程控制所有操作的，我们可以在 bot 内部维护一个“已知正确状态”或者在每次 checkpoint 时暂停交易来进行精确比对。
            *   或者，更简单地：`replay_ledger_audit` 计算出 `expected_balances`，然后读取 Redis 当前余额。如果 Redis 余额 >= 预期余额（考虑到可能有新交易进来），则难以精确判断。
            *   **精准方案**：在 `random_bot` 中，审计步骤如下：
                1.  暂停随机交易。
                2.  获取当前 Redis 最新 Ledger ID (`end_id`)。
                3.  获取当前 Redis 实际余额 (`actual_balances`)。
                4.  调用 `replay_ledger_audit(initial_balances, start_id, end_id)` 计算 `expected_balances`。
                5.  比对 `expected` vs `actual`。
                6.  如果一致，更新 `initial_balances = actual` 和 `start_id = end_id` 作为下一个周期的基准。
                7.  恢复交易。

2.  **集成到 `script/random_bot.rb`**：
    *   **初始化**：在脚本启动时，先做一次全量余额快照 (`snapshot_balances`) 和记录当前 Ledger ID，作为基准。
    *   **定时循环**：增加 `--audit-interval N` 参数（默认例如每 50 次操作）。
    *   **审计动作**：
        *   每 N 次操作后，暂停交易。
        *   执行上述“精准方案”的审计流程。
        *   如果审计失败，立即报错停止并打印差异。
        *   如果审计成功，打印通过日志，并更新基准快照，继续运行。

### 验证计划
*   运行 `ruby script/random_bot.rb --audit-interval 50`。
*   观察日志中是否定期出现 `[AUDIT] Ledger replay check passed...`。
*   手动修改 Redis 数据触发一次失败（可选，在开发测试中验证）。
