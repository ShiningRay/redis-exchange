## 在 random_bot.rb 中添加余额守恒审计

### 实现步骤

1. **在脚本启动时记录初始状态**
   - 添加 `initial_balances` 变量存储所有用户的初始余额（按币种汇总）
   - 在 `options[:seed]` 之后捕获初始快照
   - 格式：`{ 'BTC' => total_amount, 'USDT' => total_amount }`

2. **在 `--audit` 部分添加余额守恒审计**
   - 读取 `trades:{symbol}` 流，累计所有 `taker_fee` 和 `maker_fee`
   - 读取 `account_ledger` 流，统计 `ADD` 和 `SUB` 操作（存入/提现）
   - 计算预期余额：`初始余额 + 手续费 - 提现 + 存入`
   - 与实际最终余额对比
   - 输出详细报告，显示每个币种的审计结果

3. **审计逻辑**
   ```ruby
   # 按币种汇总
   initial_total = { 'BTC' => 0, 'USDT' => 0 }
   final_total = { 'BTC' => 0, 'USDT' => 0 }
   fees_collected = { 'BTC' => 0, 'USDT' => 0 }  # 手续费通常是 quote asset
   deposits = { 'BTC' => 0, 'USDT' => 0 }
   withdrawals = { 'BTC' => 0, 'USDT' => 0 }
   
   # 验证公式
   # expected = initial + fees_collected + deposits - withdrawals
   # diff = final - expected
   # diff 应该接近 0
   ```

4. **审计输出格式**
   ```
   [AUDIT] Balance Conservation Check
   =========================================
   Asset: BTC
     Initial:     12.34567890
     + Fees:      +0.00000000
     + Deposits:  +1.23456789
     - Withdrawals: -0.12345678
     = Expected:   13.45679001
     Actual:      13.45679001
     Diff:        0.00000000 ✅
   ```

### 技术细节

- 使用 `XRANGE` 读取交易流和账本流
- 手续费通常以 quote asset（USDT）计价
- 支持多币种场景（脚本可扩展）
- 在并发模式下禁用此审计（与现有审计逻辑一致）