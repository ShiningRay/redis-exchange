#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'redis'
require_relative '../lib/redis_exchange'

# 更真实的合并深度测试 - 使用更密集的价格点
# Usage:
#   ruby script/test_merge_depth_realistic.rb [--redis-url redis://127.0.0.1:6379/0] [--symbol BTCUSDT]

options = {
  redis_url: ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0',
  symbol: 'BTCUSDT',
  color: true
}

# 简单的参数解析
ARGV.each_with_index do |arg, i|
  case arg
  when '--redis-url'
    options[:redis_url] = ARGV[i + 1]
  when '--symbol'
    options[:symbol] = ARGV[i + 1]
  when '--no-color'
    options[:color] = false
  end
end

# 彩色输出辅助方法
COLORS = {
  reset: "\e[0m",
  bold: "\e[1m",
  red: "\e[31m",
  green: "\e[32m",
  yellow: "\e[33m",
  blue: "\e[34m",
  magenta: "\e[35m",
  cyan: "\e[36m"
}.freeze

def c(str, *styles)
  return str unless ($color_enabled rescue false)
  codes = styles.flatten.map { |s| COLORS[s] }.compact.join
  "#{codes}#{str}#{COLORS[:reset]}"
end

$color_enabled = options[:color] && $stdout.isatty

# 连接 Redis 和交易所
redis = Redis.new(url: options[:redis_url])
exchange = RedisExchange::Client.new(redis: redis)

symbol = options[:symbol]

# 默认市场配置
PRICE_SCALE = 100
QUANTITY_SCALE = 100_000_000

# 格式化辅助函数
def format_price(v)
  (v.to_f / 100).to_s
end

def format_quantity(v)
  (v.to_f / 100_000_000).to_s
end

puts "#{c('[TEST]', :cyan)} 开始测试合并深度功能 (真实场景)..."
puts "#{c('[INFO]', :blue)} 市场符号: #{symbol}"

# 清理并准备测试环境
puts "#{c('[SETUP]', :yellow)} 清理测试环境..."
exchange.clear_books(symbol)

# 种子市场
puts "#{c('[SETUP]', :yellow)} 配置市场参数..."
exchange.seed_market(
  symbol: symbol,
  base_asset: 'BTC',
  quote_asset: 'USDT',
  price_scale: PRICE_SCALE,
  quantity_scale: QUANTITY_SCALE,
  maker_fee_bps: 5,
  taker_fee_bps: 10,
  min_qty: 1,
  min_notional: 1,
  status: 'OPEN'
)

# 创建更密集的测试订单簿数据
puts "#{c('[SETUP]', :yellow)} 创建密集的测试订单簿数据..."

# 买单：从 29850 到 29950，间隔 10 (20个价格点)
buy_orders = []
(0..19).each do |i|
  price = (29850 + i * 10) * PRICE_SCALE  # 29850, 29860, ..., 29940
  quantity = (0.05 + (i % 5) * 0.02) * QUANTITY_SCALE  # 数量在 0.05-0.13 之间变化
  buy_orders << { price: price, quantity: quantity }
end

# 卖单：从 30050 到 30150，间隔 10 (20个价格点)
sell_orders = []
(0..19).each do |i|
  price = (30050 + i * 10) * PRICE_SCALE  # 30050, 30060, ..., 30140
  quantity = (0.03 + (i % 4) * 0.025) * QUANTITY_SCALE  # 数量在 0.03-0.105 之间变化
  sell_orders << { price: price, quantity: quantity }
end

# 使用直接 Redis 命令创建订单簿数据
buy_orders.each_with_index do |order, i|
  order_id = "test-buy-#{i}"
  user_id = "test-user"

  # 添加到订单簿
  redis.zadd("book:#{symbol}:BUY", order[:price], order[:price].to_s)
  redis.hset("volume:#{symbol}:BUY", order[:price].to_s, order[:quantity].to_s)

  # 创建订单队列
  queue_key = "queue:#{symbol}:BUY:#{order[:price]}"
  redis.lpush(queue_key, order_id)

  # 创建订单记录
  order_key = "order:#{order_id}"
  redis.hset(order_key, {
    'order_id' => order_id,
    'user_id' => user_id,
    'symbol' => symbol,
    'side' => 'BUY',
    'type' => 'LIMIT',
    'status' => 'OPEN',
    'price' => order[:price].to_s,
    'quantity' => order[:quantity].to_s,
    'remaining' => order[:quantity].to_s,
    'created_at' => (Time.now.to_f * 1000).to_i,
    'sequence' => (i + 1).to_s
  })
end

sell_orders.each_with_index do |order, i|
  order_id = "test-sell-#{i}"
  user_id = "test-user"

  # 添加到订单簿
  redis.zadd("book:#{symbol}:SELL", order[:price], order[:price].to_s)
  redis.hset("volume:#{symbol}:SELL", order[:price].to_s, order[:quantity].to_s)

  # 创建订单队列
  queue_key = "queue:#{symbol}:SELL:#{order[:price]}"
  redis.lpush(queue_key, order_id)

  # 创建订单记录
  order_key = "order:#{order_id}"
  redis.hset(order_key, {
    'order_id' => order_id,
    'user_id' => user_id,
    'symbol' => symbol,
    'side' => 'SELL',
    'type' => 'LIMIT',
    'status' => 'OPEN',
    'price' => order[:price].to_s,
    'quantity' => order[:quantity].to_s,
    'remaining' => order[:quantity].to_s,
    'created_at' => (Time.now.to_f * 1000).to_i,
    'sequence' => (i + 100).to_s
  })
end

puts "#{c('[SETUP]', :green)} ✅ 测试环境准备完成 (创建了 #{buy_orders.size} 个买单, #{sell_orders.size} 个卖单)"
puts

# 显示原始订单簿
puts "#{c('[ORIGINAL]', :cyan)} 原始订单簿深度 (前10档):"
original_book = exchange.order_book(symbol)
puts "买单 (BIDS):"
original_book[:bids].first(10).each_with_index do |bid, i|
  puts "  #{i+1}. 价格: #{format_price(bid[:price])}, 数量: #{format_quantity(bid[:volume])}"
end
puts
puts "卖单 (ASKS):"
original_book[:asks].first(10).each_with_index do |ask, i|
  puts "  #{i+1}. 价格: #{format_price(ask[:price])}, 数量: #{format_quantity(ask[:volume])}"
end
puts

# 测试合并深度 - 使用50的bucket_size (会合并5个价格点)
bucket_size = 50 * PRICE_SCALE  # 50 USDT
puts "#{c('[MERGED]', :magenta)} 合并深度测试 (bucket_size = 50.00 USDT):"
puts "这个设置会将每5个价格点合并为1个bucket"
puts

merged_book = exchange.merge_depth_both_sides(symbol, bucket_size, bucket_size)

puts "合并后的买单 (BIDS):"
merged_book[:bids].first(6).each_with_index do |bid, i|
  puts "  #{i+1}. 价格: #{format_price(bid[:price])}, 数量: #{format_quantity(bid[:volume])}, 合并层级: #{bid[:original_levels]}"
end
puts

puts "合并后的卖单 (ASKS):"
merged_book[:asks].first(6).each_with_index do |ask, i|
  puts "  #{i+1}. 价格: #{format_price(ask[:price])}, 数量: #{format_quantity(ask[:volume])}, 合并层级: #{ask[:original_levels]}"
end
puts

# 测试更大的合并 - 100的bucket_size
bucket_size_large = 100 * PRICE_SCALE  # 100 USDT
puts "#{c('[MERGED]', :magenta)} 合并深度测试 (bucket_size = 100.00 USDT):"
puts "这个设置会将每10个价格点合并为1个bucket"
puts

merged_book_large = exchange.merge_depth_both_sides(symbol, bucket_size_large, bucket_size_large)

puts "合并后的买单 (BIDS):"
merged_book_large[:bids].first(4).each_with_index do |bid, i|
  puts "  #{i+1}. 价格: #{format_price(bid[:price])}, 数量: #{format_quantity(bid[:volume])}, 合并层级: #{bid[:original_levels]}"
end
puts

puts "合并后的卖单 (ASKS):"
merged_book_large[:asks].first(4).each_with_index do |ask, i|
  puts "  #{i+1}. 价格: #{format_price(ask[:price])}, 数量: #{format_quantity(ask[:volume])}, 合并层级: #{ask[:original_levels]}"
end
puts

# 验证合并的数学正确性
puts "#{c('[VERIFICATION]', :blue)} 验证合并结果的数学正确性:"

# 验证买单合并
buy_buckets = merged_book[:bids]
buy_original_levels = 0
buy_total_volume = 0

buy_buckets.first(4).each do |bucket|
  buy_original_levels += bucket[:original_levels]
  buy_total_volume += bucket[:volume]
end

original_buy_volume = original_book[:bids].first(20).sum { |b| b[:volume] }
original_buy_levels = original_book[:bids].first(20).size

puts "买单验证:"
puts "  原始数据: #{original_buy_levels} 个价格点, 总数量: #{format_quantity(original_buy_volume)}"
puts "  合并数据: #{buy_original_levels} 个价格点, 总数量: #{format_quantity(buy_total_volume)}"
puts "  数量一致性: #{(original_buy_volume - buy_total_volume).abs < 0.001 ? '✅ 通过' : '❌ 失败'}"
puts

# 验证卖单合并
sell_buckets = merged_book[:asks]
sell_original_levels = 0
sell_total_volume = 0

sell_buckets.first(4).each do |bucket|
  sell_original_levels += bucket[:original_levels]
  sell_total_volume += bucket[:volume]
end

original_sell_volume = original_book[:asks].first(20).sum { |b| b[:volume] }
original_sell_levels = original_book[:asks].first(20).size

puts "卖单验证:"
puts "  原始数据: #{original_sell_levels} 个价格点, 总数量: #{format_quantity(original_sell_volume)}"
puts "  合并数据: #{sell_original_levels} 个价格点, 总数量: #{format_quantity(sell_total_volume)}"
puts "  数量一致性: #{(original_sell_volume - sell_total_volume).abs < 0.001 ? '✅ 通过' : '❌ 失败'}"
puts

# 测试单边不同bucket_size
puts "#{c('[ASYMMETRIC]', :yellow)} 非对称合并测试 (买单50, 卖单100):"

asymmetric_result = exchange.merge_depth_both_sides(symbol, 50 * PRICE_SCALE, 100 * PRICE_SCALE)

puts "买单合并结果 (bucket_size = 50):"
asymmetric_result[:bids].first(4).each_with_index do |bid, i|
  puts "  #{i+1}. 价格: #{format_price(bid[:price])}, 数量: #{format_quantity(bid[:volume])}, 合并层级: #{bid[:original_levels]}"
end
puts

puts "卖单合并结果 (bucket_size = 100):"
asymmetric_result[:asks].first(3).each_with_index do |ask, i|
  puts "  #{i+1}. 价格: #{format_price(ask[:price])}, 数量: #{format_quantity(ask[:volume])}, 合并层级: #{ask[:original_levels]}"
end
puts

puts "#{c('[COMPLETE]', :green)} 🎉 合并深度功能测试完成！"

# 清理测试数据
puts "#{c('[CLEANUP]', :yellow)} 清理测试数据..."
exchange.clear_books(symbol)
puts "#{c('[CLEANUP]', :green)} ✅ 清理完成"