我计划更新 `script/random_bot.rb` 脚本，在机器人运行结束后自动调用余额审计功能。

### 计划内容

1.  **修改 `script/random_bot.rb`**：
    *   在脚本末尾添加 `--audit` 选项的处理逻辑。
    *   在机器人循环执行完毕后，如果启用了 `--audit`，则调用 `RedisExchange::Maintenance#audit_user_balances`。
    *   输出审计结果报告，显示是否发现资金不一致以及自动修复的情况。

### 使用示例
*   `ruby script/random_bot.rb --audit`：运行随机交易并在结束后自动审计。
*   `ruby script/random_bot.rb --audit --no-fix`：运行随机交易，结束后仅报告审计问题但不自动修复（如果需要更细粒度控制）。*注：为了简化，默认 `--audit` 就执行修复，或者可以复用现有的 audit 逻辑。我将添加 `--audit` 开关，默认执行修复。*

### 验证
*   运行带 `--audit` 参数的脚本，观察输出中是否包含 "Starting post-run balance audit..." 及后续报告。
