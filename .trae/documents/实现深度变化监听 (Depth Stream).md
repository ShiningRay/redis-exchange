为了实现监听深度（OrderBook）变化，最佳实践是引入一个新的 Redis Stream `depth:{symbol}`，在每次订单簿发生变动时（下单、成交、撤单）发布增量更新事件。这比轮询（Polling）更实时、高效，比 Pub/Sub 更可靠。

以下是实施计划：

### 1. 引入深度流 (Depth Stream)
- **Key**: `depth:{symbol}` (例如 `depth:BTCUSDT`)
- **消息结构**:
  - `e`: 事件类型 (`u` 代表 update)
  - `s`: 方向 (`BUY` 或 `SELL`)
  - `p`: 价格 (整数，minor units)
  - `d`: 变动量 (signed integer, 负数表示减少)
  - `v`: 变动后的总量 (快照值，用于校对)
  - `ts`: 时间戳

### 2. 修改 Lua 脚本
我们需要修改所有会变更订单簿的脚本，在变更 `volume:{symbol}:{side}` 的同时，向 Stream 写入事件。

- **`redis_scripts/match_order.lua`**:
  - 当 Maker 订单被吃掉时（减少流动性），发布事件。
  - 当 Taker 订单无法完全成交而挂单时（增加流动性），发布事件。
- **`redis_scripts/cancel_order.lua`**:
  - 当订单被取消时（减少流动性），发布事件。
- **`redis_scripts/force_cancel_order.lua`**:
  - 当订单被强制取消时（减少流动性），发布事件。

### 3. 新增 Ruby 消费者
- 创建 `lib/redis_exchange/depth_stream_consumer.rb`，继承自 `StreamConsumer`，用于解析和处理深度数据。
- 在 `RedisExchange::Client` 中添加 `depth_consumer` 辅助方法。

### 4. 验证
- 编写测试用例，验证下单、成交、撤单操作是否正确触发了 `depth:{symbol}` 的消息。

确认执行该计划后，我将为您修改 Lua 脚本并添加相应的 Ruby 代码。