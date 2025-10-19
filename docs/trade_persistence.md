# 交易记录持久化方案（Redis Streams → 数据库）

## 背景与目标
- 交易撮合在 Lua 脚本中原子完成，并通过 Redis Streams `trades:{symbol}` 实时广播成交记录。
- 应用需要可靠地将这些成交记录入库，用于对账、风控、报表与查询。
- 本文档提供一套在 GEM 内封装的消费方案，以及 Rails/Ruby 侧的持久化与一致性建议。

## 数据来源
- Lua 匹配脚本在每次成交时执行 `XADD trades:{symbol}`，写入一条成交流水。
- 记录字段为：
  - `symbol`
  - `taker_order_id`
  - `maker_order_id`
  - `buy_order_id`（买方订单 id，便于查询）
  - `sell_order_id`（卖方订单 id，便于查询）
- `taker_side`（`BUY` | `SELL`）
  - `price`（成交价，整数，已缩放）
  - `quantity`（成交基础数量，整数，已缩放）
  - `quote`（成交报价金额，整数，已缩放）
  - `taker_fee`（成交扣除的吃单方手续费，整数）
  - `maker_fee`（成交扣除的挂单方手续费，整数）
  - `ts`（毫秒时间戳）
- 数值字段均为整型（已按 `price_scale` 与 `quantity_scale` 缩放）。

## 单位与刻度（重要）
- Stream 字段的数值（`price`/`quantity`/`quote`/`taker_fee`/`maker_fee`）采用市场撮合刻度（market units）：
  - `price` 使用市场的 `price_scale`。
  - `quantity` 使用市场的 `quantity_scale`。
  - `quote`、`taker_fee`、`maker_fee` 也基于市场刻度计算并广播，便于统一行情/成交分析。
- 账本与余额采用资产余额刻度（asset balance units）：
  - 撮合脚本内部在更新 `balance:{user}` 的 `available`/`reserved` 以及写入 `append_ledger(...)` 时，所有金额以资产的 `asset:{asset}.balance_scale` 为单位（参见 `docs/architecture.md`）。
  - 费用聚合键 `fees:{asset}` 也以资产余额刻度累计。
- 这意味着：事件（Stream/响应）与账本（HSET/HINCRBY/fees）使用不同刻度。需要在消费或展示层明确单位来源，避免混淆。

## 消费者封装（GEM 内）
- 类：`RedisExchange::TradeStreamConsumer`
  - `ensure_group(start_id: '0')`：确保消费者组存在，`mkstream: true`，默认从历史开始消费。
  - `read(count: 100, block_ms: 2000)`：阻塞读取批量消息，返回统一结构 `Entry(stream, id, fields)`。
  - `ack(entry_id)`：处理成功后确认。
  - `pending_summary`：获取 pending 概览。
  - `claim_idle(min_idle_ms:, count:)`：抢占过期挂起消息，做补偿处理。

- 客户端集成：`RedisExchange::Client#trade_consumer(symbol:, group:, consumer:)`
  - 构建并初始化消费者（自动 `ensure_group('0')`）。
  - 建议每个进程使用唯一 `consumer` 名称，便于水平扩展与监控。

## Rails 持久化模型建议
- 表：`trades`
  - 必备字段：
    - `stream_entry_id`（唯一索引，来自 Redis Stream 的 `e.id`）
    - `symbol`（string）
- `taker_side`（string，`BUY`/`SELL`）
    - `price`（bigint）
    - `quantity`（bigint）
    - `quote`（bigint）
    - `maker_fee`（bigint）
    - `taker_fee`（bigint）
    - `maker_order_id`（string）
    - `taker_order_id`（string）
    - `buy_order_id`（string，可选）
    - `sell_order_id`（string，可选）
    - `executed_ts_ms`（bigint）
  - 索引：
    - 唯一索引：`stream_entry_id`
    - 组合索引：`symbol, executed_ts_ms`（时间范围查询）

## 处理流程（建议实现）
- 读取：通过 `consumer.read` 批量拉取 `entries`。
- 转换：将 `entry.fields` 的字符串数值转换为整数；保留必要元数据。
- 持久化：
  - 使用 `stream_entry_id` 做幂等约束（唯一键）。
  - 成功入库后调用 `consumer.ack(entry.id)`。
- 失败与重试：
  - 数据库写入失败不进行 `ACK`，保留在 pending 中。
  - 定期使用 `claim_idle` 抢占超时的 pending 进行补偿处理。

## 幂等与一致性
- 幂等关键在于 `stream_entry_id` 唯一约束；重复消费不会造成重复写入。
- 只有在数据库事务提交成功后再 `ACK`，避免丢单。
- 若出现唯一冲突，视为已处理，仍执行 `ACK`。

## 故障处理与补偿
- Redis 与数据库短暂不可用：
  - 读取失败可退避重试（指数退避）。
  - 写库失败时不 `ACK`，待后续补偿。
- 长时间挂起的 pending：
  - 通过 `pending_summary` 监控。
  - 通过 `claim_idle` 将超过 `min_idle_ms` 的消息重新分配到当前消费者。

## 性能与扩展
- 批量读取与批量写入提升吞吐（`count` 根据负载调整）。
- 使用连接池（Redis、数据库）避免资源瓶颈。
- 水平扩展：
  - 使用同组不同 `consumer` 名称即可并行处理。
  - 通过队列分片（按 `symbol` 或哈希取模）进一步分摊负载。

## 监控与运维
- 监控指标：
  - 消费滞后（`XPENDING` 数量、最早挂起时间）。
  - ACK 成功率、一次处理耗时。
  - 数据库写入错误率。
- 报警：pending 超过阈值、长时间无 ACK、入库失败率升高。

## 示例代码
```ruby
exchange = RedisExchange::Client.new(redis: Redis.new)
consumer = exchange.trade_consumer(symbol: 'BTCUSDT', group: 'trades-consumers', consumer: 'worker-1')

loop do
  entries = consumer.read(count: 100, block_ms: 2000)
  entries.each do |e|
    fields = e.fields
    attrs = {
      stream_entry_id: e.id,
      symbol: fields['symbol'],
      taker_side: fields['taker_side'],
      price: fields['price'].to_i,
      quantity: fields['quantity'].to_i,
      quote: fields['quote'].to_i,
      maker_fee: fields['maker_fee'].to_i,
      taker_fee: fields['taker_fee'].to_i,
      maker_order_id: fields['maker_order_id'],
      taker_order_id: fields['taker_order_id'],
      buy_order_id: fields['buy_order_id'],
      sell_order_id: fields['sell_order_id'],
      executed_ts_ms: fields['ts'].to_i
    }

    # 数据库入库（示例 ActiveRecord）
    Trade.create!(attrs)

    # 入库成功后 ACK
    consumer.ack(e.id)
  rescue ActiveRecord::RecordNotUnique
    # 已入库（幂等），仍 ACK
    consumer.ack(e.id)
  rescue => err
    # 不 ACK，留待重试或补偿
    Rails.logger.error("trade persist failed: #{err.message}")
  end
end
```

## 测试与验证
- RSpec 中包含基础消费测试：`spec/trade_stream_consumer_spec.rb`。
- 建议增加集成测试：
  - 撮合产生成交 → 消费并入库 → 数据一致性校验。
  - 模拟唯一冲突与数据库失败场景，验证幂等与补偿策略。

## 与精度边界的关系
- 所有数值字段均为缩放后的整数，避免浮点误差。
- 溢出保护已在 Ruby 与 Lua 两层实现，详见 `Numeric Precision` 与相关规范测试。

## 错误码与兼容性
- 撮合脚本新增错误码：
  - `ASSET_NOT_CONFIGURED`：资产未配置或 `asset:{asset}.balance_scale` 非正数。
  - `ASSET_SCALE_MISMATCH`：资产余额刻度与市场刻度不满足整数倍兼容（详见 `docs/architecture.md`）。
  - `PRECISION_OVERFLOW`：中间乘积超过安全边界（约 `9e15`）。
- 兼容建议：
  - 消费与持久化不依赖资产刻度（仅依赖市场刻度事件），账本与余额由 Lua 保持资产刻度一致性。

## 常见问题（FAQ）
- 从历史还是从尾部开始？
  - `ensure_group('0')` 从历史开始（对账或补偿场景）；`ensure_group('$')` 从尾部开始仅处理新增。
- 是否需要多组消费者？
  - 单组即可，内部按 `consumer` 名称实现并发；必要时按 `symbol` 分片。
- 如果消息格式扩展？
  - `fields` 是哈希，建议使用向后兼容策略（新字段可选入库）。

## 参考
- Redis Streams 与 Consumer Group：`XGROUP`, `XREADGROUP`, `XACK`, `XPENDING`, `XCLAIM`
- 代码：
  - `lib/redis_exchange/trade_stream_consumer.rb`
  - `lib/redis_exchange.rb#trade_consumer`
  - `redis_scripts/match_order.lua`（XADD 广播）
  - `spec/trade_stream_consumer_spec.rb`