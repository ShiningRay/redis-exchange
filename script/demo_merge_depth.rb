#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'redis'
require_relative '../lib/redis_exchange'

# 合并深度功能演示脚本
# 展示如何使用合并深度功能来简化订单簿显示

puts "🎯 RedisExchange 合并深度功能演示"
puts "=" * 50

# 连接 Redis 和交易所
redis = Redis.new(url: ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0')
exchange = RedisExchange::Client.new(redis: redis)

symbol = 'BTCUSDT'
PRICE_SCALE = 100

# 格式化函数
def format_price(v)
  (v.to_f / PRICE_SCALE).to_s
end

def format_quantity(v)
  (v.to_f / 100_000_000).to_s
end

puts "\n📊 检查市场配置..."
market_config = exchange.market_config(symbol)

if market_config.empty?
  puts "❌ 市场 #{symbol} 不存在，正在创建..."

  # 种子市场
  exchange.seed_market(
    symbol: symbol,
    base_asset: 'BTC',
    quote_asset: 'USDT',
    price_scale: PRICE_SCALE,
    quantity_scale: 100_000_000,
    maker_fee_bps: 5,
    taker_fee_bps: 10,
    min_qty: 1,
    min_notional: 1,
    status: 'OPEN'
  )

  puts "✅ 市场 #{symbol} 创建成功"
else
  puts "✅ 找到市场 #{symbol}"
end

# 显示当前订单簿状态
puts "\n📈 当前订单簿状态 (前5档):"
current_book = exchange.order_book(symbol, limit: 5)

if current_book[:bids].empty? && current_book[:asks].empty?
  puts "🔍 订单簿为空，创建一些示例订单..."

  # 创建一些示例订单（使用随机交易机器人快速生成）
  puts "⚙️  运行随机交易机器人生成流动性..."
  system("ruby script/random_bot.rb --iterations 10 --no-color > /dev/null 2>&1")

  # 重新获取订单簿
  current_book = exchange.order_book(symbol, limit: 10)
end

puts "买单 (BIDS):"
current_book[:bids].each_with_index do |bid, i|
  puts "  #{i+1}. 价格: #{format_price(bid[:price])}, 数量: #{format_quantity(bid[:volume])}"
end

puts "卖单 (ASKS):"
current_book[:asks].each_with_index do |ask, i|
  puts "  #{i+1}. 价格: #{format_price(ask[:price])}, 数量: #{format_quantity(ask[:volume])}"
end

# 演示不同bucket_size的合并效果
bucket_sizes = [100, 500, 1000, 2000]  # 对应1, 5, 10, 20 USDT

puts "\n🔀 合并深度演示"
puts "=" * 50

bucket_sizes.each do |bucket_size|
  puts "\n📏 Bucket Size: #{format_price(bucket_size * PRICE_SCALE)} USDT"
  puts("-" * 40)

  merged_book = exchange.merge_depth_both_sides(symbol, bucket_size * PRICE_SCALE, bucket_size * PRICE_SCALE, limit: 5)

  # 买单
  puts "买单 (BIDS):"
  if merged_book[:bids].empty?
    puts "  无买单数据"
  else
    merged_book[:bids].each_with_index do |bid, i|
      puts "  #{i+1}. 价格: #{format_price(bid[:price])}, 数量: #{format_quantity(bid[:volume])}, 合并层级: #{bid[:original_levels]}"
    end
  end

  # 卖单
  puts "卖单 (ASKS):"
  if merged_book[:asks].empty?
    puts "  无卖单数据"
  else
    merged_book[:asks].each_with_index do |ask, i|
      puts "  #{i+1}. 价格: #{format_price(ask[:price])}, 数量: #{format_quantity(ask[:volume])}, 合并层级: #{ask[:original_levels]}"
    end
  end
end

# 演示非对称合并
puts "\n🔄 非对称合并演示 (买单500, 卖单1000)"
puts("-" * 50)

asymmetric_result = exchange.merge_depth_both_sides(symbol, 500 * PRICE_SCALE, 1000 * PRICE_SCALE, limit: 3)

puts "买单合并结果 (bucket_size = 5.00):"
asymmetric_result[:bids].each_with_index do |bid, i|
  puts "  #{i+1}. 价格: #{format_price(bid[:price])}, 数量: #{format_quantity(bid[:volume])}, 合并层级: #{bid[:original_levels]}"
end

puts "卖单合并结果 (bucket_size = 10.00):"
asymmetric_result[:asks].each_with_index do |ask, i|
  puts "  #{i+1}. 价格: #{format_price(ask[:price])}, 数量: #{format_quantity(ask[:volume])}, 合并层级: #{ask[:original_levels]}"
end

# API 使用说明
puts "\n💻 API 使用说明"
puts("=" * 50)

puts <<~DOC
  # 单边合并深度
  merged_bids = exchange.merge_depth(symbol, 'BUY', 500)  # 买单，bucket_size=5.00
  merged_asks = exchange.merge_depth(symbol, 'SELL', 1000)  # 卖单，bucket_size=10.00

  # 双边合并深度（相同bucket_size）
  merged_book = exchange.merge_depth_both_sides(symbol, 500, 500)

  # 双边合并深度（不同bucket_size）
  asymmetric_book = exchange.merge_depth_both_sides(symbol, 500, 1000)

  # 限制返回的bucket数量
  limited_book = exchange.merge_depth_both_sides(symbol, 500, 500, limit: 3)
DOC

puts "\n🎯 合并深度功能的优势:"
puts "  • 简化订单簿显示，提高可读性"
puts "  • 减少网络传输数据量"
puts "  • 支持非对称合并，满足不同业务需求"
puts "  • 保持数量总和的数学一致性"
puts "  • 记录合并层级信息，便于分析"

puts "\n✅ 演示完成！"