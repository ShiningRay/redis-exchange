# 交易对精度维护指南

本文档详细说明如何在 `redis-exchange` 中管理和调整交易对（Market）的价格与数量精度。

## 1. 核心概念

每个交易对（如 `BTCUSDT`）都有两个关键的精度参数：
- **Price Scale**: 价格精度缩放因子。例如 `100` 表示价格精确到 2 位小数（123.45 存储为 12345）。
- **Quantity Scale**: 数量精度缩放因子。例如 `1000` 表示数量精确到 3 位小数（1.234 存储为 1234）。

调整精度是一个高风险操作，涉及存量订单的重新计算和资金退还，因此系统提供了专门的工具来安全地执行此操作。

## 2. 初始化精度配置

在创建新市场时，通过 `seed_market` 方法设置初始精度。

```ruby
client = RedisExchange::Client.new
client.seed_market(
  symbol: 'BTCUSDT',
  base_asset: 'BTC',
  quote_asset: 'USDT',
  price_scale: 100,       # 价格精度: 2位小数
  quantity_scale: 1000,   # 数量精度: 3位小数
  # ... 其他配置
)
```

> **注意**: 一旦市场上线并产生订单，**不可**再次调用 `seed_market` 修改 scale 参数，否则会导致数据损坏。必须使用下文所述的维护工具。

## 3. 在线调整精度 (运维脚本)

对于已运行的市场，请使用 `script/maintenance/adjust_precision.rb` 脚本进行调整。该脚本会自动处理快照、模拟、迁移和验证。

### 3.1 准备工作
- 确保 Redis 连接正常。
- 建议在低峰期进行操作，虽然脚本会锁定市场，但会短暂中断交易。

### 3.2 执行命令
使用 `bundle exec ruby` 运行脚本。

**参数说明**:
- `-s, --symbol`: 交易对名称 (如 `BTCUSDT`)
- `-p, --price-scale`: 新的价格精度
- `-q, --quantity-scale`: 新的数量精度
- `-y, --yes`: 跳过确认直接执行（不推荐）
- `-o, --output`: 快照输出目录（默认 `./tmp/snapshots`）

**示例**: 将 BTCUSDT 的价格精度从 2 位调整为 4 位，数量精度保持不变。

```bash
bundle exec ruby script/maintenance/adjust_precision.rb \
  -s BTCUSDT \
  -p 10000 \
  -q 1000
```

### 3.3 执行流程详解

脚本会按以下步骤执行：

1.  **创建快照 (Snapshot)**:
    - 自动导出当前的订单簿 (`book_old_*.json`) 和用户余额 (`balances_old_*.json`)，以便出问题时恢复。

2.  **模拟运行 (Dry Run)**:
    - 在内存中模拟精度转换。
    - 计算所有受影响的订单。
    - **尘埃退还 (Dust Refund)**: 如果新精度导致订单金额无法整除（例如 1.234 变成 1.23），剩余的“尘埃”金额会自动退还到用户的可用余额中。
    - **不变性检查**: 验证模拟结果是否满足“总资产守恒”原则。

3.  **人工确认**:
    - 脚本会打印模拟结果（影响订单数、退款笔数），等待用户输入 `y` 确认。

4.  **原子执行**:
    - 将市场状态设为 `MAINTENANCE`（暂停交易）。
    - 批量迁移 Redis 中的订单数据。
    - 更新市场元数据。
    - 恢复市场状态为 `OPEN`。

5.  **最终验证**:
    - 再次导出快照。
    - 对比前后余额，确保没有资金凭空消失或产生。

## 4. 编程接口 (API)

如果你需要集成到管理后台，可以直接调用 `Maintenance` 模块的 API。

```ruby
require 'redis_exchange'

client = RedisExchange::Client.new

# 1. 模拟 (Dry Run)
result = client.maintenance.update_market_precision(
  symbol: 'BTCUSDT',
  new_price_scale: 10000,
  new_quantity_scale: 1000,
  dry: true
)

if result[:status] == 'SIMULATED'
  puts "将更新 #{result[:updated_orders]} 个订单"
  puts "将产生 #{result[:simulated_balance_adjustments].size} 笔退款"
end

# 2. 执行 (Execute)
# 注意：此操作会自动将市场置为维护模式，完成后恢复
real_result = client.maintenance.update_market_precision(
  symbol: 'BTCUSDT',
  new_price_scale: 10000,
  new_quantity_scale: 1000,
  dry: false
)

if real_result[:status] == 'OK'
  puts "更新成功！"
else
  puts "更新失败: #{real_result[:error]}"
end
```

## 5. 常见问题与风险

### Q1: 精度调低会发生什么？
如果将精度调低（例如 `1000` -> `100`），原本 `1.234` 的数量会变成 `1.23`。
- **订单**: 订单剩余量会向下取整。
- **资金**: 被截断的 `0.004` 部分会从冻结金额 (`reserved`) 解锁，并作为 `DUST_REFUND` 退回到用户的可用余额 (`available`)。

### Q2: 精度调高会发生什么？
如果将精度调高（例如 `100` -> `1000`），`1.23` 会无损变成 `1.230`。通常不会产生退款，除非涉及费率计算的微小差异。

### Q3: 执行过程中服务会中断吗？
是的。在迁移执行期间，该交易对会短暂进入 `MAINTENANCE` 状态，期间无法下单或撤单。脚本执行通常在毫秒到秒级完成（取决于订单量），影响极小。
