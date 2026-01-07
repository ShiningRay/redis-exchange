# 合并深度功能使用指南

## 概述

合并深度功能允许将多个价格水平合并为更大的价格区间，用于简化订单簿显示，提高可读性并减少数据传输量。

## 核心功能

### 1. 单边合并深度

```ruby
# 合并买单，bucket_size=500 (5.00 USDT)
merged_bids = exchange.merge_depth(symbol, 'BUY', 500)

# 合并卖单，bucket_size=1000 (10.00 USDT)
merged_asks = exchange.merge_depth(symbol, 'SELL', 1000)

# 限制返回数量
limited_bids = exchange.merge_depth(symbol, 'BUY', 500, limit: 5)
```

### 2. 双边合并深度

```ruby
# 相同bucket_size
merged_book = exchange.merge_depth_both_sides(symbol, 500, 500)

# 不同bucket_size (非对称合并)
asymmetric_book = exchange.merge_depth_both_sides(symbol, 500, 1000)

# 限制返回数量
limited_book = exchange.merge_depth_both_sides(symbol, 500, 500, limit: 3)
```

## 返回数据格式

每个合并后的价格水平包含：

```ruby
{
  price: 29500,          # 合并后的基准价格
  volume: 125000000,     # 合并后的总数量
  original_levels: 5     # 被合并的原始价格层级数
}
```

## 随机交易机器人集成

随机交易机器人支持 `--merge-depth` 选项：

```bash
# 使用默认bucket_size (1000)
ruby script/random_bot.rb --merge-depth

# 指定bucket_size
ruby script/random_bot.rb --merge-depth 500

# 完整示例
ruby script/random_bot.rb --iterations 50 --merge-depth 1000 --symbol BTCUSDT
```

## 测试和演示

### 运行测试

```bash
# 基础功能测试
ruby script/test_merge_depth.rb

# 真实场景测试
ruby script/test_merge_depth_realistic.rb
```

### 运行演示

```bash
# 功能演示
ruby script/demo_merge_depth.rb
```

## 实现原理

1. **价格区间计算**: 使用 `(price / bucket_size).floor * bucket_size` 计算每个价格点所属的区间
2. **数量聚合**: 将同一区间内的所有价格点的数量相加
3. **排序保持**: 买单按价格降序，卖单按价格升序
4. **层级计数**: 记录每个合并区间包含的原始价格层级数

## 使用场景

1. **前端显示**: 简化图表显示，提高用户体验
2. **API响应**: 减少数据传输量，提高响应速度
3. **数据分析**: 聚合价格区间，便于趋势分析
4. **风险管理**: 按价格区间评估市场深度

## 性能考虑

- 基于现有的订单簿查询，不增加额外的存储负担
- 计算复杂度 O(n)，其中 n 为原始价格层级数
- 支持限制返回数量，进一步优化性能

## 数学一致性

合并后的数量总和等于原始数据的数量总和：

```
∑原始数量 = ∑合并数量
∑原始层级数 = ∑合并层级数
```

## 错误处理

```ruby
# 无效参数会抛出 ArgumentError
begin
  exchange.merge_depth(symbol, 'INVALID_SIDE', 1000)
rescue ArgumentError => e
  # side must be BUY or SELL
end

begin
  exchange.merge_depth(symbol, 'BUY', 0)
rescue ArgumentError => e
  # bucket_size must be positive
end
```

## 注意事项

1. bucket_size 必须是正整数
2. side 参数必须是 'BUY' 或 'SELL'
3. 空订单簿会返回空数组
4. 合并后的价格不一定是实际存在的价格点，而是区间的基准价格